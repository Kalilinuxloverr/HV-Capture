//
//  PlugLink.swift — Anbindung der WLAN-Steckdose (OpenBeken-Firmware).
//
//  Die Firmware hat eine Tasmota-kompatible HTTP-API: `http://<ip>/cm?cmnd=…`.
//  Darüber wird geschaltet, gemessen und der Selbstabschalt-Auftrag gesetzt.
//
//  Zwei getrennte Poll-Schleifen: die schnelle liest die Energiewerte (daran
//  hängt die Überwachung), die langsame den Schaltzustand. Getrennt, damit die
//  Überwachung nie auf eine Zustandsabfrage warten muss.
//

import Foundation

// MARK: - Befehle

/// Reine Befehlsbauer — ohne Netzwerk, damit die Zeichenketten testbar sind.
/// Alle Rückgaben sind bereits %-kodiert und gehören direkt hinter `?cmnd=`.
enum PlugCommand {
    /// Auftrags-IDs in der Dose. Getrennt, damit der Haltebetrieb den
    /// Session-Timer nicht überschreibt und umgekehrt.
    static let watchdogEventID = 91
    static let sessionTimerEventID = 92

    static let secondsRange = 1...3600

    static func clamp(_ seconds: Int) -> Int {
        Swift.min(Swift.max(seconds, secondsRange.lowerBound), secondsRange.upperBound)
    }

    static func power(on: Bool) -> String { on ? "Power%20On" : "Power%20Off" }
    static let status8 = "Status%208"
    static let powerState = "Power"

    /// Selbstabschaltung mit fester Auftrags-ID. Erneutes Setzen derselben ID
    /// ersetzt den Auftrag, statt einen zweiten danebenzulegen — genau das
    /// braucht der Haltebetrieb, der alle paar Sekunden neu setzt.
    static func autoOffArm(seconds: Int, id: Int) -> String {
        "addRepeatingEventID%20\(clamp(seconds))%201%20\(id)%20POWER%20OFF"
    }

    static func autoOffCancel(id: Int) -> String { "cancelRepeatingEvent%20\(id)" }

    static let clearAllEvents = "clearRepeatingEvents"

    /// Rückfallweg für Firmware-Stände ohne die ID-Variante. Muss mit
    /// `clearAllEvents` kombiniert werden und hat dadurch zwischen Löschen und
    /// Setzen ein kurzes Fenster ohne aktiven Auftrag.
    static func legacyAutoOff(seconds: Int) -> String {
        "addRepeatingEvent%20\(clamp(seconds))%201%20POWER%20OFF"
    }

    /// Antwort, die auf einen nicht unterstützten Befehl hindeutet.
    static func indicatesUnknownCommand(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("unknown") || t.contains("invalid") || t.contains("error")
    }
}

// MARK: - Simulation

/// Synthetische Messreihen für die Entwickler-Ansicht — damit Auswertung,
/// Grenzwerte und UI ohne angeschlossene Hardware geprüft werden können.
enum PlugScenario: String, CaseIterable, Identifiable {
    case steady, flickering, constantLoad, connectionLoss, idle
    var id: String { rawValue }

    var label: String {
        switch self {
        case .steady: return "Gleichmäßige Last"
        case .flickering: return "Stark schwankend"
        case .constantLoad: return "Wird konstant"
        case .connectionLoss: return "Verbindungsabriss"
        case .idle: return "Leerlauf"
        }
    }

    var detail: String {
        switch self {
        case .steady: return "~4 A, leicht schwankend."
        case .flickering: return "2–6 A, so sieht normaler Betrieb aus."
        case .constantLoad: return "Erst schwankend, ab ~3 s praktisch konstant ~9 A — der Fall, den die Flachheitsprüfung fangen soll."
        case .connectionLoss: return "Nach 4 s kommen keine Messwerte mehr."
        case .idle: return "~0,3 A, ruhig."
        }
    }
}

/// Kleiner deterministischer Generator — reproduzierbare Simulationsläufe ohne
/// Abhängigkeit vom globalen Zufall.
private struct LCG {
    private var state: UInt64
    init(seed: UInt64) { state = seed &* 6364136223846793005 &+ 1442695040888963407 }

    mutating func next01() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }

    mutating func next(in range: ClosedRange<Double>) -> Double {
        range.lowerBound + next01() * (range.upperBound - range.lowerBound)
    }
}

// MARK: - Verbindung

@MainActor
@Observable
final class PlugLink {
    static let shared = PlugLink()

    private(set) var isOn: Bool?
    private(set) var reading: Reading?
    private(set) var reachable = false
    private(set) var lastSuccess: Date?
    private(set) var lastError: String?

    /// Rate echter Messwert*wechsel*. Der Messchip der Dose (BL0937-Klasse)
    /// aktualisiert nur etwa im Sekundentakt — schneller pollen senkt nur die
    /// Latenz, bis ein neuer Wert sichtbar wird, und erzeugt keine zusätzliche
    /// Auflösung. Getrennt von `pollHz` ausgewiesen, damit die Anzeige keine
    /// Präzision vortäuscht, die die Hardware nicht liefert.
    private(set) var effectiveHz: Double = 0
    private(set) var pollHz: Double = 0

    private(set) var watchdogActive = false
    private(set) var watchdogWindow = 30
    /// Die Dose kennt die ID-Variante nicht — es läuft der Rückfallweg mit
    /// seinem kurzen ungeschützten Fenster. Gehört sichtbar in die UI.
    private(set) var watchdogFallbackInUse = false

    /// Wird bei JEDEM Poll gerufen, auch mit `nil`, wenn die Dose nicht
    /// erreichbar ist — die Abnehmer müssen eine Messwert-Unterbrechung
    /// erkennen können und nicht nur ausbleibende Aufrufe sehen.
    var onReading: ((Reading?) -> Void)?

    /// Simulationsfall statt echter HTTP-Abfragen (Entwickler-Ansicht).
    var simulation: PlugScenario? {
        didSet { simulationStarted = simulation == nil ? nil : Date() }
    }

    private(set) var isFast = false

    private var fastTask: Task<Void, Never>?
    private var slowTask: Task<Void, Never>?
    private var watchdogTask: Task<Void, Never>?
    private var simulationStarted: Date?
    private var rng = LCG(seed: 0x5EED)

    private var pollCount = 0
    private var changeCount = 0
    private var rateWindowStart = Date()

    private let session: URLSession

    private init() {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.timeoutIntervalForRequest = 1.5
        cfg.waitsForConnectivity = false
        session = URLSession(configuration: cfg)
    }

    var ip: String {
        (UserDefaults.standard.string(forKey: "plugIP") ?? "")
            .trimmingCharacters(in: .whitespaces)
    }

    var isConfigured: Bool { !ip.isEmpty || simulation != nil }

    // MARK: - Schalten

    @discardableResult
    func setPower(_ on: Bool) async -> Bool {
        guard let data = await send(PlugCommand.power(on: on)) else { return false }
        isOn = Self.parsePowerState(data) ?? on
        return true
    }

    /// Ausschalten mit mehreren Versuchen. Ein einzelnes verlorenes Paket darf
    /// nicht dazu führen, dass die Dose an bleibt — deshalb wird gefeuert, statt
    /// auf den Erfolg des ersten Versuchs zu vertrauen.
    func forceOff() async {
        for attempt in 0..<3 {
            _ = await send(PlugCommand.power(on: false))
            if attempt < 2 { try? await Task.sleep(for: .milliseconds(150)) }
        }
        isOn = false
    }

    // MARK: - Selbstabschaltung in der Dose

    /// Setzt den Auftrag „schalte dich in `seconds` Sekunden ab". Er läuft in
    /// der Dose und überlebt damit App-Absturz, gesperrtes iPhone und
    /// WLAN-Abriss — die einzige Absicherung, die einen Totalausfall der App
    /// übersteht.
    @discardableResult
    func armWatchdog(seconds: Int) async -> Bool {
        watchdogWindow = PlugCommand.clamp(seconds)

        if !watchdogFallbackInUse {
            let cmd = PlugCommand.autoOffArm(seconds: watchdogWindow,
                                             id: PlugCommand.watchdogEventID)
            guard let data = await send(cmd) else {
                watchdogActive = false
                return false
            }
            let text = String(data: data, encoding: .utf8) ?? ""
            if !PlugCommand.indicatesUnknownCommand(text) {
                watchdogActive = true
                return true
            }
            watchdogFallbackInUse = true   // Firmware kennt die ID-Variante nicht
        }

        _ = await send(PlugCommand.clearAllEvents)
        guard await send(PlugCommand.legacyAutoOff(seconds: watchdogWindow)) != nil else {
            watchdogActive = false
            return false
        }
        watchdogActive = true
        return true
    }

    func cancelWatchdog() async {
        if watchdogFallbackInUse {
            _ = await send(PlugCommand.clearAllEvents)
        } else {
            _ = await send(PlugCommand.autoOffCancel(id: PlugCommand.watchdogEventID))
        }
        watchdogActive = false
    }

    /// Haltebetrieb: erneuert den Auftrag in einem Drittel des Fensters. Bleibt
    /// die Erneuerung aus, läuft der Auftrag in der Dose ab und sie schaltet ab.
    func startWatchdog(window: Int) {
        stopWatchdogTask()
        watchdogWindow = PlugCommand.clamp(window)
        watchdogTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                _ = await self.armWatchdog(seconds: self.watchdogWindow)
                let refresh = Swift.max(3, self.watchdogWindow / 3)
                try? await Task.sleep(for: .seconds(refresh))
            }
        }
    }

    func stopWatchdog() async {
        stopWatchdogTask()
        await cancelWatchdog()
    }

    private func stopWatchdogTask() {
        watchdogTask?.cancel()
        watchdogTask = nil
    }

    // MARK: - Session-Timer (läuft ebenfalls in der Dose)

    @discardableResult
    func armSessionTimer(seconds: Int) async -> Bool {
        let cmd = watchdogFallbackInUse
            ? PlugCommand.legacyAutoOff(seconds: seconds)
            : PlugCommand.autoOffArm(seconds: seconds, id: PlugCommand.sessionTimerEventID)
        return await send(cmd) != nil
    }

    func cancelSessionTimer() async {
        guard !watchdogFallbackInUse else { return }   // Rückfallweg kennt keine IDs
        _ = await send(PlugCommand.autoOffCancel(id: PlugCommand.sessionTimerEventID))
    }

    // MARK: - Poll-Schleifen

    func startPolling() {
        guard fastTask == nil, slowTask == nil else { return }
        rateWindowStart = Date()

        fastTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollEnergy()
                let ms = self.isFast ? self.fastIntervalMs : 3000
                try? await Task.sleep(for: .milliseconds(ms))
            }
        }

        slowTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.pollPowerState()
                try? await Task.sleep(for: .seconds(self.isFast ? 1 : 3))
            }
        }
    }

    func stopPolling() {
        fastTask?.cancel(); fastTask = nil
        slowTask?.cancel(); slowTask = nil
    }

    /// Schnelle Schleife nur, solange die Dose tatsächlich an ist.
    func setFast(_ on: Bool) { isFast = on }

    private var fastIntervalMs: Int {
        let stored = UserDefaults.standard.object(forKey: "pollIntervalMs") as? Int ?? 200
        return Swift.min(Swift.max(stored, 100), 2000)
    }

    private func pollEnergy() async {
        let now = Date()
        let new: Reading?

        if let scenario = simulation {
            new = simulatedReading(scenario, now: now)
        } else if let data = await send(PlugCommand.status8) {
            new = Reading(status8: data, date: now)
        } else {
            new = nil
        }

        pollCount += 1
        if let new {
            // Wiederholung desselben Chip-Werts zählt nicht als neuer Messpunkt.
            if reading.map({ !new.sameMeasurement(as: $0) }) ?? true { changeCount += 1 }
            reading = new
            reachable = true
            lastSuccess = now
        } else {
            reading = nil
            reachable = false
        }

        updateRates(now: now)
        onReading?(new)
    }

    private func pollPowerState() async {
        if simulation != nil {
            isOn = simulationStarted != nil
            return
        }
        guard let data = await send(PlugCommand.powerState) else { return }
        isOn = Self.parsePowerState(data)
    }

    private func updateRates(now: Date) {
        let span = now.timeIntervalSince(rateWindowStart)
        guard span >= 2 else { return }
        pollHz = Double(pollCount) / span
        effectiveHz = Double(changeCount) / span
        pollCount = 0
        changeCount = 0
        rateWindowStart = now
    }

    // MARK: - HTTP

    private func send(_ cmnd: String) async -> Data? {
        guard simulation == nil else { return Data("{}".utf8) }
        let host = ip
        guard !host.isEmpty, let url = URL(string: "http://\(host)/cm?cmnd=\(cmnd)") else {
            lastError = "Keine IP-Adresse für die Steckdose hinterlegt."
            return nil
        }
        var req = URLRequest(url: url)
        req.timeoutInterval = 1.5
        req.cachePolicy = .reloadIgnoringLocalCacheData
        do {
            let (data, _) = try await session.data(for: req)
            lastError = nil
            return data
        } catch {
            lastError = error.localizedDescription
            return nil
        }
    }

    /// `{"POWER":"ON"}` — `nil`, wenn die Antwort den Zustand nicht enthält.
    /// Reiner Parser ohne Zustand, deshalb ausserhalb der MainActor-Isolation.
    nonisolated static func parsePowerState(_ data: Data) -> Bool? {
        guard let s = String(data: data, encoding: .utf8) else { return nil }
        if s.contains("\"POWER\":\"ON\"") { return true }
        if s.contains("\"POWER\":\"OFF\"") { return false }
        return nil
    }

    // MARK: - Simulation

    private func simulatedReading(_ scenario: PlugScenario, now: Date) -> Reading? {
        let t = now.timeIntervalSince(simulationStarted ?? now)
        let volts = 231.0 + rng.next(in: -1.5...1.5)

        let amps: Double
        switch scenario {
        case .idle:
            amps = 0.30 + rng.next(in: -0.03...0.03)
        case .steady:
            amps = 4.0 + rng.next(in: -0.35...0.35)
        case .flickering:
            amps = rng.next(in: 2.0...6.0)
        case .constantLoad:
            // Erst normaler Betrieb, dann fällt die Schwankung praktisch weg.
            amps = t < 3 ? rng.next(in: 2.0...6.0) : 9.0 + rng.next(in: -0.02...0.02)
        case .connectionLoss:
            if t >= 4 { return nil }
            amps = rng.next(in: 2.0...6.0)
        }

        return Reading(date: now, volts: volts, amps: amps,
                       watts: volts * amps, kwh: 0.5 + t / 3600 * volts * amps / 1000)
    }
}
