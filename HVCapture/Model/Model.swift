//
//  Model.swift — reine Werte: Messpunkt, Session, Bogen, Abschaltung,
//  Wächter-Konfiguration. Keine Abhängigkeit ausser Foundation, damit die
//  komplette Auswerte-Logik ohne Hardware, Kamera und UI testbar bleibt.
//
//  Ablage: eine JSON-Datei je Session in `Documents/Sessions/<uuid>.json`.
//  Zeiten innerhalb einer Session sind Sekunden seit `started` (Double) — das
//  hält die Dateien kompakt und Kurven zeichnen sich ohne Datums-Mathematik.
//

import Foundation

// MARK: - Messpunkt

/// Ein Messwert der Steckdose (Tasmota-kompatible HTTP-API der
/// OpenBeken-Firmware, `/cm?cmnd=Status%208`).
///
/// Der Messchip der LSC-Dosen (BL0937-Klasse) aktualisiert nur etwa im
/// Sekundentakt. Schneller pollen verkürzt die Latenz, bis ein neuer Wert
/// sichtbar wird, erzeugt aber keine zusätzlichen Werte — deshalb trägt jeder
/// Messpunkt sein Ankunftsdatum und lässt sich per `sameMeasurement(as:)` als
/// Wiederholung erkennen.
struct Reading: Equatable, Sendable {
    var date: Date
    var volts: Double?
    var amps: Double?
    var watts: Double?
    var kwh: Double?

    init(date: Date = Date(), volts: Double? = nil, amps: Double? = nil,
         watts: Double? = nil, kwh: Double? = nil) {
        self.date = date
        self.volts = volts
        self.amps = amps
        self.watts = watts
        self.kwh = kwh
    }

    /// `{"StatusSNS":{"ENERGY":{"Power":…,"Voltage":…,"Current":…,"Total":…}}}`
    /// OpenBeken liefert je nach Version `Total` (kWh) oder `ConsumptionTotal`
    /// (Wh) — beide werden akzeptiert und auf kWh normiert.
    init?(status8 data: Data, date: Date = Date()) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let energy = (obj["StatusSNS"] as? [String: Any])?["ENERGY"] as? [String: Any]
        else { return nil }
        self.date = date
        volts = Reading.num(energy["Voltage"])
        amps = Reading.num(energy["Current"])
        watts = Reading.num(energy["Power"])
        kwh = Reading.num(energy["Total"])
            ?? Reading.num(energy["ConsumptionTotal"]).map { $0 / 1000 }
    }

    /// Gleiche Messung wie `other`? Vergleicht nur die Messwerte, nicht die
    /// Uhrzeit — so zählt die App wiederholt gepollte identische Werte nicht als
    /// neue Messpunkte und täuscht keine Auflösung vor, die es nicht gibt.
    func sameMeasurement(as other: Reading) -> Bool {
        volts == other.volts && amps == other.amps
            && watts == other.watts && kwh == other.kwh
    }

    /// Negative oder absurde Werte behandelt der Wächter wie fehlende Daten,
    /// nicht wie „alles in Ordnung".
    var isPlausible: Bool {
        if let a = amps, !(0...40).contains(a) { return false }
        if let v = volts, v != 0, !(90...280).contains(v) { return false }
        if let w = watts, !(-10...6000).contains(w) { return false }
        return true
    }

    private static func num(_ any: Any?) -> Double? {
        if let n = any as? NSNumber { return n.doubleValue }
        if let s = any as? String { return Double(s) }
        return nil
    }
}

// MARK: - Session-Bestandteile

/// Ein gespeicherter Messpunkt — kurze Schlüssel, weil davon Zehntausende in
/// einer Datei landen.
struct Sample: Codable, Equatable, Identifiable {
    var t: Double        // s seit Session-Start
    var v: Double        // Volt
    var a: Double        // Ampere
    var w: Double        // Watt

    var id: Double { t }
}

/// Ein zusammenhängender Lichtbogen (Strom über der Zündschwelle).
struct ArcEvent: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var start: Double         // s seit Session-Start
    var end: Double?          // nil = brennt noch
    var peakWatts: Double = 0
    var peakAmps: Double = 0

    var duration: Double? { end.map { $0 - start } }
}

/// Warum wurde abgeschaltet.
enum TripReason: String, Codable, CaseIterable, Sendable {
    case threshold      // Strom über Grenzwert, länger als Haltezeit
    case flatness       // verdächtig ruhiger Strom = klebt
    case dataLoss       // keine plausiblen Messwerte mehr
    case deadMan        // Selbstabschaltung der Dose (App/WLAN weg)
    case timer          // Session-Timer abgelaufen
    case pulse          // Puls-Modus, planmässige Aus-Phase
    case deadManSwitch  // Totmann-Taste losgelassen
    case manual         // Not-Aus von Hand

    var label: String {
        switch self {
        case .threshold: return "Grenzwert überschritten"
        case .flatness: return "Kurzschluss klebt (flacher Strom)"
        case .dataLoss: return "Messwerte weggebrochen"
        case .deadMan: return "Dead-Man der Steckdose"
        case .timer: return "Timer abgelaufen"
        case .pulse: return "Puls-Pause"
        case .deadManSwitch: return "Totmann-Taste losgelassen"
        case .manual: return "Not-Aus von Hand"
        }
    }

    var symbol: String {
        switch self {
        case .threshold: return "bolt.trianglebadge.exclamationmark"
        case .flatness: return "waveform.path.ecg.rectangle.fill"
        case .dataLoss: return "wifi.exclamationmark"
        case .deadMan: return "timer"
        case .timer: return "hourglass"
        case .pulse: return "waveform.path"
        case .deadManSwitch: return "hand.raised.fill"
        case .manual: return "hand.raised.slash.fill"
        }
    }

    /// Deutet auf einen Defekt hin — muss quittiert werden, bevor wieder
    /// eingeschaltet werden kann.
    var requiresAcknowledgement: Bool {
        switch self {
        case .threshold, .flatness, .dataLoss, .deadMan: return true
        case .timer, .pulse, .deadManSwitch, .manual: return false
        }
    }
}

/// Eine protokollierte Abschaltung samt Kurvenausschnitt.
struct Trip: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var t: Double                 // s seit Session-Start
    var date: Date
    var reason: TripReason
    var amps: Double?
    var watts: Double?
    /// ±10 s um den Trip — damit die Historie die Kurve zeigen kann, ohne die
    /// komplette Session nachzuladen.
    var context: [Sample] = []
}

// MARK: - Session

struct Session: Codable, Equatable, Identifiable {
    var id: UUID = UUID()
    var started: Date
    var ended: Date?
    /// Freier Name der verwendeten Elektrode — Grundlage des Verschleisszählers.
    var electrode: String = "Standard"
    var note: String = ""
    var samples: [Sample] = []
    var arcs: [ArcEvent] = []
    var trips: [Trip] = []
    /// Bezeichner der Aufnahmen, die während dieser Session entstanden sind.
    var mediaNames: [String] = []

    var duration: TimeInterval { (ended ?? Date()).timeIntervalSince(started) }

    var arcCount: Int { arcs.count }
    var longestArc: Double? { arcs.compactMap(\.duration).max() }

    /// Summe aller Bogen-Brenndauern — Grundlage des Elektrodenverschleisses.
    var totalArcSeconds: Double { arcs.compactMap(\.duration).reduce(0, +) }

    var peakWatts: Double? { samples.map(\.w).max() }
    var peakAmps: Double? { samples.map(\.a).max() }

    /// Energie aus der Messreihe integriert (Trapez). Die kWh-Anzeige der Dose
    /// ist für Sessions von Sekunden bis Minuten zu grob aufgelöst.
    /// Lücken über 10 s werden übersprungen statt überbrückt — sonst erfindet
    /// die Integration Energie über eine Verbindungsunterbrechung hinweg.
    var wattHours: Double {
        guard samples.count > 1 else { return 0 }
        var joules = 0.0
        for (a, b) in zip(samples, samples.dropFirst()) {
            let dt = b.t - a.t
            guard dt > 0, dt < 10 else { continue }
            joules += (a.w + b.w) / 2 * dt
        }
        return joules / 3600
    }

    static let csvHeader = "t_s,volts,amps,watts"

    /// Messreihe als CSV — Punkt als Dezimaltrenner, damit Tabellenprogramme
    /// und Auswerteskripte das unabhängig von der Region lesen.
    var csv: String {
        var out = Session.csvHeader + "\n"
        for s in samples {
            out += String(format: "%.3f,%.1f,%.3f,%.1f\n", s.t, s.v, s.a, s.w)
        }
        return out
    }
}

// MARK: - Auswertung über mehrere Sessions

/// Allzeit-Bestwerte.
struct Records: Equatable {
    var longestArc: Double = 0
    var peakWatts: Double = 0
    var peakAmps: Double = 0
    var mostArcsInSession: Int = 0
    var totalArcSeconds: Double = 0
    var totalWattHours: Double = 0
    var sessionCount: Int = 0

    static func from(_ sessions: [Session]) -> Records {
        var r = Records()
        r.sessionCount = sessions.count
        for s in sessions {
            r.longestArc = max(r.longestArc, s.longestArc ?? 0)
            r.peakWatts = max(r.peakWatts, s.peakWatts ?? 0)
            r.peakAmps = max(r.peakAmps, s.peakAmps ?? 0)
            r.mostArcsInSession = max(r.mostArcsInSession, s.arcCount)
            r.totalArcSeconds += s.totalArcSeconds
            r.totalWattHours += s.wattHours
        }
        return r
    }
}

/// Verschleiss je Elektrode: kumulierte Bogensekunden über alle Sessions.
struct ElectrodeWear: Equatable, Identifiable {
    var name: String
    var arcSeconds: Double
    var sessions: Int
    var lastUsed: Date?

    var id: String { name }

    static func from(_ sessions: [Session]) -> [ElectrodeWear] {
        var byName: [String: ElectrodeWear] = [:]
        for s in sessions {
            var w = byName[s.electrode]
                ?? ElectrodeWear(name: s.electrode, arcSeconds: 0, sessions: 0, lastUsed: nil)
            w.arcSeconds += s.totalArcSeconds
            w.sessions += 1
            w.lastUsed = w.lastUsed.map { Swift.max($0, s.started) } ?? s.started
            byName[s.electrode] = w
        }
        return byName.values.sorted { $0.arcSeconds > $1.arcSeconds }
    }
}

// MARK: - Wächter-Konfiguration

/// Grenzwerte des Stromwächters. Kommen aus der Kalibrierfahrt und bleiben von
/// Hand justierbar — jeder MOT, jede Elektrode und jede Netzimpedanz ist anders,
/// und genau diese Abweichung sieht ein Modell mit festen Zahlen nie.
struct GuardConfig: Codable, Equatable {
    /// Harte Schwelle: Strom über `tripAmps` länger als `holdSeconds` → aus.
    var thresholdEnabled = true
    var tripAmps: Double = 8.0
    var holdSeconds: Double = 2.0

    /// Flachheits-Heuristik: Strom durchgehend über `suspectAmps` und dabei
    /// auffällig ruhig (Spannweite im Fenster unter `flatnessMaxRange`) → klebt.
    /// Ein brennender Bogen flackert, ein klebender Kurzschluss ist still.
    ///
    /// Bewusst Spannweite statt Standardabweichung: die App pollt schneller als
    /// der Messchip neue Werte liefert, also stehen im Fenster viele identische
    /// Wiederholungen. Die drücken eine Standardabweichung künstlich gegen null
    /// und würden mitten im echten Bogen auslösen. Auf max − min haben
    /// Wiederholungen dagegen keinen Einfluss.
    var flatnessEnabled = true
    var suspectAmps: Double = 4.0
    var flatnessWindow: Double = 2.0     // s
    var flatnessMaxRange: Double = 0.30  // A

    /// Keine plausiblen Messwerte mehr, obwohl die Dose an ist → aus.
    var dataLossSeconds: Double = 5.0

    /// Ab diesem Strom gilt ein Bogen als gezündet (Statistik, nicht Sicherheit).
    var arcOnAmps: Double = 1.2
    /// Hysterese: darunter gilt er als erloschen.
    var arcOffAmps: Double = 0.7

    static let storageKey = "guardConfig"

    static func load(from defaults: UserDefaults = .standard) -> GuardConfig {
        guard let data = defaults.data(forKey: storageKey),
              let cfg = try? JSONDecoder().decode(GuardConfig.self, from: data)
        else { return GuardConfig() }
        return cfg
    }

    func save(to defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: Self.storageKey)
    }

    /// Widersprüchliche Werte machen den Wächter unbrauchbar, ohne dass man es
    /// merkt — deshalb hier benannt statt stillschweigend zurechtgebogen.
    var problems: [String] {
        var out: [String] = []
        if thresholdEnabled, tripAmps <= 0 { out.append("Grenzwert muss über 0 A liegen.") }
        if flatnessEnabled, suspectAmps <= 0 { out.append("Verdachtswert muss über 0 A liegen.") }
        if thresholdEnabled, flatnessEnabled, suspectAmps >= tripAmps {
            out.append("Verdachtswert liegt über dem Grenzwert — die Flachheitsprüfung greift dann nie vor der Schwelle.")
        }
        if holdSeconds < 0.2 { out.append("Haltezeit unter 0,2 s löst bei jedem Zünden aus.") }
        if arcOffAmps >= arcOnAmps { out.append("Bogen-Aus muss unter Bogen-Ein liegen (Hysterese).") }
        return out
    }
}
