//
//  RigPlan.swift — Modell für den Aufbau-Planer.
//
//  Reine Rechnung ohne UI: aus Anzahl MOTs, Topologie, EMI-Board und Vorlast
//  werden Kennwerte (Spannung, Strom, Leistung) und daraus die passende
//  Anleitung samt Warnhinweisen abgeleitet. Die Zahlen sind Grössenordnungen
//  für die Planung, keine Messwerte — ein echter MOT streut stark.
//

import Foundation

/// Wie die Sekundärseiten der MOTs zusammenwirken.
enum RigTopology: String, CaseIterable, Identifiable {
    case single      // ein einzelner MOT
    case series      // Kerne verbunden, Spannung addiert sich
    case parallel    // Ausgänge parallel, Strom addiert sich

    var id: String { rawValue }

    var label: String {
        switch self {
        case .single: return "Einzeln"
        case .series: return "Reihe"
        case .parallel: return "Parallel"
        }
    }

    var effect: String {
        switch self {
        case .single: return "Ein MOT."
        case .series: return "Spannung addiert sich"
        case .parallel: return "Strom addiert sich"
        }
    }
}

struct RigPlan: Equatable {
    var motCount: Int = 2
    var topology: RigTopology = .series
    var emiBoard: Bool = true
    var ballast: Bool = true

    /// Ein MOT liefert grob ~2 kV im Leerlauf und zieht primär grob ~1 kW.
    private static let voltsPerMOT = 2_000.0
    private static let wattsPerMOT = 1_000.0

    var effectiveCount: Int {
        topology == .single ? 1 : max(1, motCount)
    }

    /// Leerlauf-Sekundärspannung in Volt (Grössenordnung).
    var openCircuitVolts: Double {
        switch topology {
        case .single: return Self.voltsPerMOT
        case .series: return Self.voltsPerMOT * Double(effectiveCount)
        case .parallel: return Self.voltsPerMOT
        }
    }

    /// Aufgenommene Wirkleistung in Watt (alle MOTs zusammen, grob).
    var powerWatts: Double {
        Self.wattsPerMOT * Double(effectiveCount)
    }

    /// Primärstrom aus dem 230-V-Netz in Ampere.
    var primaryAmps: Double {
        powerWatts / 230.0
    }

    /// Sekundärstrom-Grössenordnung: in Reihe bleibt er wie bei einem MOT,
    /// parallel addiert er sich.
    var secondaryAmpsFactor: Int {
        topology == .parallel ? effectiveCount : 1
    }

    // MARK: - Anleitung

    /// Aufbauschritte in der richtigen Reihenfolge, abhängig von der Auswahl.
    var steps: [String] {
        var s: [String] = []
        s.append("Netzstecker mit eigener Zugentlastung an einer separat schaltbaren Steckdosenleiste — der physische Not-Aus, den die App nicht ersetzt.")
        if emiBoard {
            s.append("EMI-Filterplatine direkt hinter dem Netzstecker: L und N durch den Filter, die enthaltene Sicherung ist die erste Schmelzsicherung des Aufbaus.")
        } else {
            s.append("Ohne EMI-Board zwingend eine eigene träge Schmelzsicherung im Halter direkt hinter dem Netzstecker — die Haussicherung ist zu träge und zu hoch.")
        }
        s.append("Die Messsteckdose kommt HINTER Sicherung und Filter, damit die App den echten Aufbaustrom sieht.")
        if ballast {
            s.append("Vorschaltlast (ohmsch, z. B. Halogenstrahler oder Heizwendel) in Reihe zur Primärseite — begrenzt den Strom im Kurzschluss und schützt als Einziges auch das Relais der Dose.")
        } else {
            s.append("OHNE Vorlast liegt beim ersten Zünden und bei jedem Kurzschluss der volle Strom an — nur mit sauber ausgelegter Sicherung und beim ersten Test kurz antippen.")
        }
        switch topology {
        case .single:
            s.append("Primärwicklung an L und N. Der eine Sekundär-Heissleiter ist der Hochspannungsausgang, das kalte Ende ist im Kern.")
        case .series:
            s.append("Die Kerne der MOTs leitend miteinander verbinden (das kalte Sekundärende ist ab Werk am Kern) — dadurch sind die Sekundärwicklungen in Reihe und die Spannung addiert sich.")
            s.append("Primärwicklungen parallel an L und N. Stimmt die Phase eines MOT nicht, ist der Bogen schwach oder bleibt aus — dann bei EINEM MOT L und N tauschen. Nur im offenen Reihenbetrieb gefahrlos durch Probieren zu finden.")
        case .parallel:
            s.append("ACHTUNG: Ausgänge parallel heisst gleiche Phase auf beiden Seiten — ein Phasenfehler legt die volle Spannung beider MOTs gegeneinander. Die Phase muss VOR dem Verbinden feststehen, nicht durch Probieren im geschlossenen Kreis.")
            s.append("Erst beide MOTs einzeln als Reihe/gegen Kern prüfen, Phase markieren, dann die gleichphasigen Heissenden verbinden.")
        }
        s.append("Beide Kerne und die Masse des EMI-Boards auf den Schutzleiter — sternförmig auf einen Punkt, nicht in Reihe.")
        return s
    }

    /// Warnhinweise, nach Schwere absteigend. Skaliert mit der Auswahl.
    var cautions: [Caution] {
        var c: [Caution] = []

        if topology == .parallel {
            c.append(Caution(level: .high,
                             text: "Parallelbetrieb ist deutlich gefährlicher als Reihe: Ein Phasenfehler ist hier kein schwacher Bogen, sondern ein harter Kurzschluss der Sekundärseiten. Für mehr Strom ist die Reihe mit Vorlast der sicherere Weg."))
        }
        if !ballast {
            c.append(Caution(level: .high,
                             text: "Ohne Vorlast fehlt die einzige Strombegrenzung, die auch das Dosen-Relais schützt. Ein klebender Kurzschluss verschweisst das Relais — die Dose bleibt dann AN. Nur mit Sicherung und sehr kurzen ersten Tests fahren."))
        }
        if effectiveCount >= 4 {
            c.append(Caution(level: .high,
                             text: "Ab \(effectiveCount) MOTs summiert sich die Primärleistung auf grob \(Int(powerWatts)) W (~\(String(format: "%.1f", primaryAmps)) A). Das ist an einer normalen Haushaltssteckdose (16 A) nah an der Grenze — Leitung, Stecker und Dose werden heiss."))
        }
        if openCircuitVolts >= 6_000 {
            c.append(Caution(level: .high,
                             text: "Rechnerisch rund \(Int(openCircuitVolts / 1000)) kV Leerlaufspannung. Ab hier springt der Bogen über deutliche Luftstrecken und kriecht über Oberflächen — Abstände grosszügig, keine spitzen Ecken, alles gegen Kriechwege isolieren."))
        }
        c.append(Caution(level: .medium,
                         text: "Die Sekundärseite ist mit dem Kern verbunden, der Kern liegt am Schutzleiter — trotzdem nie im Betrieb anfassen. Eine Hand in der Tasche, der Weg von Hand zu Hand führt über das Herz."))
        if !emiBoard {
            c.append(Caution(level: .medium,
                             text: "Ohne EMI-Board streut der Bogen kräftig ins Netz zurück (die App sieht das als Strom-Geisterspitzen). Eine Entstördrossel um die 230-V-Zuleitung dämpft das."))
        }
        c.append(Caution(level: .low,
                         text: "Der Bogen strahlt hart im UV wie ein Schweisslichtbogen. Augenschutz auf, nicht direkt hineinsehen, Haut abdecken."))
        return c
    }

    struct Caution: Equatable, Identifiable {
        enum Level: Int { case low, medium, high }
        let level: Level
        let text: String
        var id: String { text }
    }
}

// MARK: - Selbstprüfung

#if DEBUG
enum RigPlanSelfCheck {
    /// Prüft die tragenden Rechenwege — läuft im Selbsttest der Entwickleransicht.
    static func run() -> String {
        var plan = RigPlan(motCount: 3, topology: .series, emiBoard: true, ballast: true)
        assert(plan.openCircuitVolts == 6_000, "Reihe: 3×2 kV erwartet")
        assert(plan.powerWatts == 3_000)
        assert(plan.secondaryAmpsFactor == 1, "Reihe: Strom addiert sich nicht")

        plan.topology = .parallel
        assert(plan.openCircuitVolts == 2_000, "Parallel: Spannung bleibt")
        assert(plan.secondaryAmpsFactor == 3, "Parallel: Strom ×3")
        assert(plan.cautions.contains { $0.level == .high }, "Parallel muss hart warnen")

        plan = RigPlan(motCount: 1, topology: .single, emiBoard: false, ballast: false)
        assert(plan.effectiveCount == 1)
        assert(plan.cautions.contains { $0.text.contains("Vorlast") }, "Ohne Vorlast warnen")
        return "RigPlan: alle Prüfungen bestanden."
    }
}
#endif
