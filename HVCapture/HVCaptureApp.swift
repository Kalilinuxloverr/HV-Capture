//
//  HVCaptureApp.swift — Einstiegspunkt und zentraler Koordinator.
//
//  `ArcController` ist die einzige Stelle, die einschaltet und abschaltet.
//  Alles andere — Wächter, Mitschrieb, Live-Theme, Kamera-Auslöser — hängt am
//  selben Messwertstrom, ohne voneinander zu wissen.
//

import SwiftUI

// MARK: - Betriebsarten

enum RunMode: String, CaseIterable, Identifiable {
    case free, timer, pulse, deadManSwitch
    var id: String { rawValue }

    var label: String {
        switch self {
        case .free: return "Frei"
        case .timer: return "Session-Timer"
        case .pulse: return "Puls"
        case .deadManSwitch: return "Totmann-Taste"
        }
    }

    var symbol: String {
        switch self {
        case .free: return "infinity"
        case .timer: return "hourglass"
        case .pulse: return "waveform.path"
        case .deadManSwitch: return "hand.raised.fill"
        }
    }

    var explanation: String {
        switch self {
        case .free:
            return "Läuft, bis du ausschaltest. Der Selbstabschalt-Auftrag in der Dose sichert weiterhin ab."
        case .timer:
            return "Schaltet nach Ablauf der eingestellten Zeit selbstständig ab."
        case .pulse:
            return "Wechselt automatisch zwischen An- und Aus-Phasen, für die eingestellte Anzahl Durchgänge."
        case .deadManSwitch:
            return "Strom fliesst nur, solange du den Knopf hältst. Loslassen schaltet ab — mit einigen hundert Millisekunden Verzögerung, das ist kein mechanischer Schalter."
        }
    }
}

// MARK: - Koordinator

@MainActor
@Observable
final class ArcController {
    static let shared = ArcController()

    struct TripRecord: Equatable {
        var reason: TripReason
        var detail: String?
        var date: Date
    }

    private(set) var isArmed = false
    private(set) var guardConfig = GuardConfig.load()
    /// Letzte Abschaltung, die quittiert werden muss, bevor es weitergeht.
    private(set) var pendingTrip: TripRecord?
    private(set) var arcBurning = false
    private(set) var statusMessage: String?

    /// Sekunden bis zur automatischen Abschaltung. Negativ = Puls-Pause.
    private(set) var secondsRemaining: Int?
    private(set) var pulseCycle: Int = 0

    var mode: RunMode = .free

    /// Kalibrierung läuft — dann greift der Wächter absichtlich nicht ein,
    /// weil gerade erst die Grenzwerte ermittelt werden.
    var calibrating = false
    private(set) var calibration = Calibration()
    var calibrationStep: Calibration.Step = .idle

    private var arcGuard = ArcGuard()
    private var modeTask: Task<Void, Never>?

    private let plug = PlugLink.shared
    private let recorder = SessionRecorder.shared

    private init() {
        plug.onReading = { [weak self] reading in
            self?.handle(reading)
        }
    }

    // MARK: Einstellungen

    var watchdogWindow: Int {
        let v = UserDefaults.standard.object(forKey: "watchdogWindow") as? Int ?? 30
        return Swift.min(Swift.max(v, 10), 300)
    }

    /// Fenster für die aktuelle Betriebsart.
    ///
    /// Bei der Totmann-Taste bewusst kurz: das Loslassen wird über das
    /// Gesten-Ende erkannt, und das feuert nicht garantiert — eine abgebrochene
    /// Geste, ein Systemdialog oder ein eingehender Anruf können es
    /// verschlucken. Dann bleibt die kurze Selbstabschaltung in der Dose die
    /// einzige Instanz, die noch abschaltet, und drei Sekunden sind näher an
    /// dem, was ein Totmannschalter verspricht, als dreissig.
    var effectiveWatchdogWindow: Int {
        mode == .deadManSwitch ? 3 : watchdogWindow
    }

    var timerSeconds: Int {
        let v = UserDefaults.standard.object(forKey: "timerSeconds") as? Int ?? 30
        return Swift.min(Swift.max(v, 1), 3600)
    }

    var pulseOn: Int { Swift.max(1, UserDefaults.standard.object(forKey: "pulseOn") as? Int ?? 5) }
    var pulseOff: Int { Swift.max(1, UserDefaults.standard.object(forKey: "pulseOff") as? Int ?? 10) }
    var pulseRepeats: Int { Swift.max(1, UserDefaults.standard.object(forKey: "pulseRepeats") as? Int ?? 3) }

    func reloadConfig() {
        guardConfig = GuardConfig.load()
        arcGuard.config = guardConfig
    }

    func saveConfig(_ cfg: GuardConfig) {
        cfg.save()
        guardConfig = cfg
        arcGuard.config = cfg
    }

    // MARK: Ein und Aus

    /// Einschalten. Blockiert, solange eine Abschaltung nicht quittiert ist.
    @discardableResult
    func arm() async -> Bool {
        guard pendingTrip == nil else {
            statusMessage = "Erst die letzte Abschaltung quittieren."
            return false
        }
        guard plug.isConfigured else {
            statusMessage = "Keine IP-Adresse für die Steckdose hinterlegt."
            return false
        }

        arcGuard.config = guardConfig
        arcGuard.arm()
        recorder.start()

        // Selbstabschaltung ZUERST setzen, dann einschalten — nie andersherum,
        // sonst läuft der Aufbau kurz ohne jede Absicherung.
        plug.startWatchdog(window: effectiveWatchdogWindow)
        try? await Task.sleep(for: .milliseconds(120))

        guard await plug.setPower(true) else {
            await plug.stopWatchdog()
            arcGuard.disarm()
            _ = recorder.stop()
            statusMessage = "Die Steckdose hat nicht geantwortet."
            return false
        }

        isArmed = true
        plug.setFast(true)
        statusMessage = nil
        LiveActivityController.start(modeLabel: mode.label)
        startModeTask()
        return true
    }

    /// Regulär abschalten.
    func disarm(reason: TripReason = .manual) async {
        modeTask?.cancel(); modeTask = nil
        secondsRemaining = nil
        pulseCycle = 0
        isArmed = false
        arcBurning = false
        plug.setFast(false)
        arcGuard.disarm()
        recorder.record(trip: reason)
        await plug.forceOff()
        await plug.stopWatchdog()
        _ = recorder.stop()
        LiveTheme.shared.reset()
        LiveActivityController.end(tripLabel: reason.requiresAcknowledgement ? reason.label : nil)
    }

    /// Not-Aus — schaltet sofort und fragt nicht nach.
    func emergencyOff() async {
        Haptics.error()
        await disarm(reason: .manual)
        statusMessage = "Not-Aus ausgelöst."
    }

    func acknowledgeTrip() {
        pendingTrip = nil
        statusMessage = nil
    }

    // MARK: Messwertstrom

    private func handle(_ reading: Reading?) {
        LiveTheme.shared.feed(watts: reading?.watts)
        CaptureEngine.shared.externalPowerSignal(watts: reading?.watts)

        // Während der Kalibrierung wird nur gesammelt, nicht bewertet.
        if calibrating {
            if let a = reading?.amps { calibration.record(a, in: calibrationStep) }
            return
        }

        guard isArmed else { return }

        let decision = arcGuard.evaluate(reading)
        arcBurning = decision.arcBurning
        recorder.ingest(reading, decision: decision)
        WatchBridge.shared.push(watts: reading?.watts, amps: reading?.amps,
                                armed: isArmed, remaining: secondsRemaining)
        LiveActivityController.update(watts: reading?.watts, amps: reading?.amps,
                                      volts: reading?.volts,
                                      secondsRemaining: secondsRemaining,
                                      armed: isArmed, arcBurning: decision.arcBurning,
                                      tripLabel: decision.trip?.label)

        if let trip = decision.trip {
            pendingTrip = TripRecord(reason: trip, detail: decision.detail, date: Date())
            Haptics.error()
            // Sofort synchron entschärfen: das eigentliche Abschalten ist
            // asynchron, und bis es durch ist, kämen sonst weitere Messwerte
            // hier an und würden denselben Vorgang mehrfach anstossen.
            isArmed = false
            arcGuard.disarm()
            Task { await disarm(reason: trip) }
        }
    }

    func resetCalibration() { calibration = Calibration() }

    // MARK: Betriebsarten

    private func startModeTask() {
        modeTask?.cancel()
        switch mode {
        case .free, .deadManSwitch:
            modeTask = nil
        case .timer:
            let total = timerSeconds
            Task { _ = await plug.armSessionTimer(seconds: total) }
            modeTask = Task { [weak self] in
                for remaining in stride(from: total, through: 0, by: -1) {
                    guard let self, !Task.isCancelled else { return }
                    self.secondsRemaining = remaining
                    if remaining == 5 { Haptics.warning() }
                    try? await Task.sleep(for: .seconds(1))
                }
                guard let self, !Task.isCancelled else { return }
                await self.disarm(reason: .timer)
            }
        case .pulse:
            modeTask = Task { [weak self] in
                guard let self else { return }
                for cycle in 1...self.pulseRepeats {
                    guard !Task.isCancelled else { return }
                    self.pulseCycle = cycle
                    _ = await self.plug.setPower(true)
                    for r in stride(from: self.pulseOn, through: 1, by: -1) {
                        guard !Task.isCancelled else { return }
                        self.secondsRemaining = r
                        try? await Task.sleep(for: .seconds(1))
                    }
                    guard !Task.isCancelled else { return }
                    await self.plug.forceOff()
                    self.recorder.record(trip: .pulse)
                    for r in stride(from: self.pulseOff, through: 1, by: -1) {
                        guard !Task.isCancelled else { return }
                        self.secondsRemaining = -r     // negativ = Pause
                        try? await Task.sleep(for: .seconds(1))
                    }
                }
                guard !Task.isCancelled else { return }
                await self.disarm(reason: .timer)
            }
        }
    }

    /// Totmann-Taste losgelassen.
    func deadManReleased() async {
        guard mode == .deadManSwitch, isArmed else { return }
        await disarm(reason: .deadManSwitch)
    }
}

// MARK: - App

@main
struct HVCaptureApp: App {
    @Environment(\.scenePhase) private var scenePhase

    init() {
        PlugLink.shared.startPolling()
        SessionStore.shared.load()
        WatchBridge.shared.activate()     // ohne Uhr schlicht wirkungslos
        _ = ArcController.shared          // verbindet den Messwertstrom
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .tint(Palette.accent)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, phase in
            // Im Hintergrund kann die App den Selbstabschalt-Auftrag nicht
            // zuverlässig erneuern. Statt darauf zu hoffen, wird abgeschaltet.
            if phase == .background, ArcController.shared.isArmed {
                Task { await ArcController.shared.disarm(reason: .deadMan) }
            }
        }
    }
}
