//
//  SessionStore.swift — Mitschrieb der laufenden Messfahrt und Ablage aller
//  abgeschlossenen Sessions.
//
//  `SessionRecorder` baut aus dem Messwertstrom und den Urteilen des Wächters
//  die laufende Session auf. `SessionStore` legt sie als JSON in
//  `Documents/Sessions/` ab und rechnet Rekorde und Elektrodenverschleiss aus.
//

import Foundation

// MARK: - Mitschrieb

@MainActor
@Observable
final class SessionRecorder {
    static let shared = SessionRecorder()

    private(set) var current: Session?
    var isRecording: Bool { current != nil }

    /// Obergrenze der Messreihe. Bei 200 ms Poll sind das rund elf Stunden
    /// Dauerbetrieb — darüber wird ausgedünnt statt unbegrenzt zu wachsen,
    /// sonst frisst eine vergessene Session den Speicher auf.
    static let maxSamples = 200_000

    /// Verhindert, dass jeder Poll während eines anhaltenden Fehlers einen
    /// neuen Trip schreibt: derselbe Grund wird erst nach einer Pause erneut
    /// protokolliert.
    private var lastTrip: (reason: TripReason, at: Date)?
    private static let tripRepeatGrace: TimeInterval = 5

    private init() {}

    func start(electrode: String? = nil) {
        let name = electrode
            ?? UserDefaults.standard.string(forKey: "electrodeName")
            ?? "Standard"
        current = Session(started: Date(), electrode: name)
        lastTrip = nil
    }

    /// Beendet die Session, schliesst einen noch offenen Bogen und legt sie ab.
    @discardableResult
    func stop(now: Date = Date()) -> Session? {
        guard var s = current else { return nil }
        let t = now.timeIntervalSince(s.started)
        if let last = s.arcs.indices.last, s.arcs[last].end == nil {
            s.arcs[last].end = t
        }
        s.ended = now
        current = nil
        lastTrip = nil
        SessionStore.shared.save(s)
        return s
    }

    /// Einen Messpunkt samt Urteil aufnehmen.
    func ingest(_ reading: Reading?, decision: GuardDecision, now: Date = Date()) {
        guard var s = current else { return }
        let t = now.timeIntervalSince(s.started)

        if let r = reading, r.isPlausible,
           let v = r.volts, let a = r.amps, let w = r.watts {
            s.samples.append(Sample(t: t, v: v, a: a, w: w))
            if s.samples.count > Self.maxSamples {
                s.samples = Self.thinned(s.samples)
            }
            if decision.arcStarted {
                s.arcs.append(ArcEvent(start: t, peakWatts: w, peakAmps: a))
            } else if let i = s.arcs.indices.last, s.arcs[i].end == nil {
                s.arcs[i].peakWatts = Swift.max(s.arcs[i].peakWatts, w)
                s.arcs[i].peakAmps = Swift.max(s.arcs[i].peakAmps, a)
            }
        }

        if decision.arcEnded, let i = s.arcs.indices.last, s.arcs[i].end == nil {
            s.arcs[i].end = t
        }

        if let reason = decision.trip, shouldRecordTrip(reason, at: now) {
            let lo = t - 10, hi = t + 10
            s.trips.append(Trip(t: t, date: now, reason: reason,
                                amps: reading?.amps, watts: reading?.watts,
                                context: s.samples.filter { $0.t >= lo && $0.t <= hi }))
            lastTrip = (reason, now)
        }

        current = s
    }

    /// Trip von aussen protokollieren (Timer, Not-Aus, Totmann-Taste).
    func record(trip reason: TripReason, now: Date = Date()) {
        guard var s = current, shouldRecordTrip(reason, at: now) else { return }
        let t = now.timeIntervalSince(s.started)
        let lo = t - 10
        s.trips.append(Trip(t: t, date: now, reason: reason,
                            amps: nil, watts: nil,
                            context: s.samples.filter { $0.t >= lo }))
        lastTrip = (reason, now)
        current = s
    }

    func addMedia(_ name: String) { current?.mediaNames.append(name) }
    func setNote(_ text: String) { current?.note = text }

    private func shouldRecordTrip(_ reason: TripReason, at now: Date) -> Bool {
        guard let last = lastTrip, last.reason == reason else { return true }
        return now.timeIntervalSince(last.at) >= Self.tripRepeatGrace
    }

    /// Jeden zweiten Messpunkt behalten — halbiert die Reihe und lässt den
    /// Verlauf erkennbar, statt vorne abzuschneiden.
    static func thinned(_ samples: [Sample]) -> [Sample] {
        stride(from: 0, to: samples.count, by: 2).map { samples[$0] }
    }
}

// MARK: - Ablage

@MainActor
@Observable
final class SessionStore {
    static let shared = SessionStore()

    private(set) var sessions: [Session] = []
    /// Dateien, die nicht gelesen werden konnten — sichtbar statt verschluckt.
    private(set) var loadErrors: [String] = []

    private init() {}

    static var directory: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("Sessions", isDirectory: true)
    }

    private static var encoder: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }

    private static var decoder: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    func load() {
        loadErrors = []
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let urls = (try? fm.contentsOfDirectory(at: Self.directory,
                                                includingPropertiesForKeys: nil)) ?? []
        var found: [Session] = []
        for url in urls where url.pathExtension == "json" {
            do {
                found.append(try Self.decoder.decode(Session.self, from: Data(contentsOf: url)))
            } catch {
                loadErrors.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        sessions = found.sorted { $0.started > $1.started }
    }

    func save(_ session: Session) {
        let fm = FileManager.default
        try? fm.createDirectory(at: Self.directory, withIntermediateDirectories: true)
        let url = Self.directory.appendingPathComponent("\(session.id.uuidString).json")
        do {
            try Self.encoder.encode(session).write(to: url, options: .atomic)
            sessions.removeAll { $0.id == session.id }
            sessions.append(session)
            sessions.sort { $0.started > $1.started }
        } catch {
            loadErrors.append("Speichern fehlgeschlagen: \(error.localizedDescription)")
        }
    }

    func update(_ session: Session) { save(session) }

    func delete(_ session: Session) {
        let url = Self.directory.appendingPathComponent("\(session.id.uuidString).json")
        try? FileManager.default.removeItem(at: url)
        sessions.removeAll { $0.id == session.id }
    }

    var records: Records { Records.from(sessions) }
    var electrodeWear: [ElectrodeWear] { ElectrodeWear.from(sessions) }

    // MARK: - Export

    /// Zeitstempel unabhängig von der Regionseinstellung — ein japanischer oder
    /// buddhistischer Regionskalender würde sonst andere Jahreszahlen liefern.
    static func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    static func baseName(for session: Session) -> String {
        "HV-\(session.id.uuidString.prefix(8))-\(stamp(session.started))"
    }

    func csvURL(for session: Session) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(Self.baseName(for: session)).csv")
        try session.csv.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Messwerte, Metadaten und Aufnahmen in einem Ordner für das Share-Sheet.
    func exportBundle(for session: Session, mediaURLs: [URL] = []) throws -> URL {
        let fm = FileManager.default
        let dir = fm.temporaryDirectory
            .appendingPathComponent(Self.baseName(for: session), isDirectory: true)
        try? fm.removeItem(at: dir)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        try session.csv.write(to: dir.appendingPathComponent("messwerte.csv"),
                              atomically: true, encoding: .utf8)
        try Self.encoder.encode(session)
            .write(to: dir.appendingPathComponent("session.json"), options: .atomic)
        for src in mediaURLs {
            try? fm.copyItem(at: src, to: dir.appendingPathComponent(src.lastPathComponent))
        }
        return dir
    }

    /// Zwei Messreihen auf ein gemeinsames Zeitraster legen. Fehlende Werte
    /// bleiben `nil` — es wird bewusst nicht extrapoliert, sonst zeigt der
    /// Vergleich Kurven, die so nie gemessen wurden.
    static func compare(_ a: Session, _ b: Session, step: Double = 0.25)
        -> [(t: Double, a: Double?, b: Double?)] {
        let end = Swift.max(a.samples.last?.t ?? 0, b.samples.last?.t ?? 0)
        guard end > 0, step > 0 else { return [] }

        func value(_ samples: [Sample], at t: Double) -> Double? {
            samples.min { abs($0.t - t) < abs($1.t - t) }
                .flatMap { abs($0.t - t) <= step / 2 ? $0.w : nil }
        }

        return stride(from: 0, through: end, by: step).map {
            (t: $0, a: value(a.samples, at: $0), b: value(b.samples, at: $0))
        }
    }
}

#if DEBUG
/// Selbstprüfung für die Logik, die stillschweigend falsch sein könnte.
/// Aufruf aus der Entwickler-Ansicht.
enum RecorderSelfCheck {
    @MainActor
    static func run() -> String {
        let rec = SessionRecorder.shared
        let t0 = Date()
        rec.start(electrode: "Selbsttest")

        func r(_ a: Double) -> Reading { Reading(volts: 230, amps: a, watts: 230 * a) }

        rec.ingest(r(0.3), decision: GuardDecision(), now: t0)
        rec.ingest(r(3.0), decision: GuardDecision(arcBurning: true, arcStarted: true),
                   now: t0.addingTimeInterval(1))
        rec.ingest(r(3.4), decision: GuardDecision(arcBurning: true),
                   now: t0.addingTimeInterval(2))
        rec.ingest(r(0.3), decision: GuardDecision(arcEnded: true),
                   now: t0.addingTimeInterval(3))
        assert(rec.current?.arcs.count == 1, "genau ein Bogen erwartet")
        assert(rec.current?.arcs.first?.end != nil, "Bogen muss geschlossen sein")

        // Derselbe Grund in Folge darf nur einmal protokolliert werden.
        let trip = GuardDecision(trip: .threshold, detail: "Test")
        rec.ingest(r(9), decision: trip, now: t0.addingTimeInterval(4))
        rec.ingest(r(9), decision: trip, now: t0.addingTimeInterval(4.2))
        rec.ingest(r(9), decision: trip, now: t0.addingTimeInterval(4.4))
        assert(rec.current?.trips.count == 1, "Doppel-Trips müssen unterdrückt werden")

        let arcs = rec.current?.arcs.count ?? 0
        let trips = rec.current?.trips.count ?? 0
        let samples = rec.current?.samples.count ?? 0
        _ = rec.stop(now: t0.addingTimeInterval(5))

        return "Selbsttest bestanden — \(samples) Messpunkte, \(arcs) Bogen, \(trips) Trip."
    }
}
#endif
