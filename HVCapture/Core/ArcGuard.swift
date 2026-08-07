//
//  ArcGuard.swift — Stromwächter und Kalibrierung.
//
//  Die einzige sicherheitsrelevante Logik der App, deshalb bewusst als reine
//  Struktur ohne Netzwerk, Timer und UI: `evaluate` bekommt einen Messwert und
//  die aktuelle Uhrzeit herein und gibt ein Urteil zurück. Alles daran ist ohne
//  MOT, ohne Steckdose und ohne Kamera testbar.
//
//  Zur Einordnung: das hier ist Komfort, kein Schutz. Ein klebendes Relais,
//  ein WLAN-Aussetzer oder ein App-Absturz hebeln jeden Wert hier aus. Der
//  eigentliche Schutz sind Vorschaltlast, Sicherung und ein erreichbarer
//  Not-Aus — und der Dead-Man, der in der Steckdose selbst läuft.
//

import Foundation

/// Urteil zu einem Messpunkt.
struct GuardDecision: Equatable {
    /// Gesetzt = sofort abschalten.
    var trip: TripReason?
    /// Erläuterung für Protokoll und Trip-Banner.
    var detail: String?
    /// Brennt gerade ein Bogen (Statistik, nicht Sicherheit)?
    var arcBurning: Bool = false
    /// Wechsel der Bogen-Erkennung in diesem Schritt.
    var arcStarted: Bool = false
    var arcEnded: Bool = false
}

/// Bewertet den Stromverlauf und entscheidet, ob abgeschaltet werden muss.
///
/// Zustandsbehaftet: Halte- und Flachheitsprüfung brauchen Historie. Eine
/// Instanz gehört zu genau einer scharfgeschalteten Phase — `arm()` setzt alles
/// zurück, `disarm()` beendet die Bewertung.
struct ArcGuard {
    var config: GuardConfig

    /// Beobachtungsfenster (Zeitpunkt, Ampere) für die Flachheitsprüfung.
    private var window: [(t: Date, a: Double)] = []
    /// Seit wann liegt der Strom ununterbrochen über dem Grenzwert.
    private var overSince: Date?
    /// Letzter plausibler Messwert — Grundlage der Datenverlust-Erkennung.
    private var lastPlausible: Date?
    /// Seit wann ist scharf geschaltet (nil = nicht scharf).
    private var armedAt: Date?
    private(set) var arcBurning = false

    init(config: GuardConfig = .load()) {
        self.config = config
    }

    var isArmed: Bool { armedAt != nil }

    /// Scharf schalten. Setzt die komplette Historie zurück, damit Werte aus
    /// einer früheren Phase nicht in die neue hineinwirken.
    mutating func arm(now: Date = Date()) {
        window.removeAll()
        overSince = nil
        lastPlausible = nil
        armedAt = now
        arcBurning = false
    }

    mutating func disarm() {
        armedAt = nil
        overSince = nil
        arcBurning = false
        window.removeAll()
    }

    /// Einen Messpunkt bewerten. `reading == nil` oder ein unplausibler Wert
    /// zählt als Datenverlust — im Zweifel abschalten, nicht weiterlaufen.
    mutating func evaluate(_ reading: Reading?, now: Date = Date()) -> GuardDecision {
        guard let armedAt else { return GuardDecision() }

        // --- Datenverlust ---------------------------------------------------
        guard let r = reading, r.isPlausible, let amps = r.amps else {
            // Referenz ist der letzte gute Wert, vor dem ersten Wert der
            // Scharfschaltzeitpunkt — sonst würde ein Aufbau, der nie Werte
            // liefert, unbegrenzt als „noch keine Daten" durchgehen.
            let since = lastPlausible ?? armedAt
            if now.timeIntervalSince(since) >= config.dataLossSeconds {
                return GuardDecision(
                    trip: .dataLoss,
                    detail: String(format: "Seit %.1f s keine plausiblen Messwerte.",
                                   now.timeIntervalSince(since)),
                    arcBurning: arcBurning)
            }
            return GuardDecision(arcBurning: arcBurning)
        }

        lastPlausible = now
        window.append((now, amps))
        let cutoff = now.addingTimeInterval(-Swift.max(config.flatnessWindow, 0.1))
        window.removeAll { $0.t < cutoff }

        // --- Bogen-Erkennung (nur Statistik) --------------------------------
        var started = false, ended = false
        if arcBurning, amps < config.arcOffAmps {
            arcBurning = false
            ended = true
        } else if !arcBurning, amps >= config.arcOnAmps {
            arcBurning = true
            started = true
        }

        // --- Harte Schwelle -------------------------------------------------
        if config.thresholdEnabled, config.tripAmps > 0 {
            if amps >= config.tripAmps {
                let since = overSince ?? now
                overSince = since
                if now.timeIntervalSince(since) >= config.holdSeconds {
                    return GuardDecision(
                        trip: .threshold,
                        detail: String(format: "%.2f A ≥ %.2f A für %.1f s.",
                                       amps, config.tripAmps, now.timeIntervalSince(since)),
                        arcBurning: arcBurning, arcStarted: started, arcEnded: ended)
                }
            } else {
                overSince = nil
            }
        }

        // --- Flachheit ------------------------------------------------------
        if config.flatnessEnabled, let detail = flatnessBreach(now: now) {
            return GuardDecision(trip: .flatness, detail: detail,
                                 arcBurning: arcBurning, arcStarted: started, arcEnded: ended)
        }

        return GuardDecision(arcBurning: arcBurning, arcStarted: started, arcEnded: ended)
    }

    /// Klebt der Kurzschluss? Der Strom muss das ganze Fenster über dem
    /// Verdachtswert liegen und dabei kaum schwanken.
    ///
    /// Das Fenster muss echt gefüllt sein — sonst löst schon der zweite
    /// identische Messwert nach dem Einschalten aus.
    private func flatnessBreach(now: Date) -> String? {
        guard config.suspectAmps > 0,
              window.count >= 4,
              let first = window.first?.t,
              now.timeIntervalSince(first) >= config.flatnessWindow * 0.9
        else { return nil }

        let values = window.map(\.a)
        guard let lo = values.min(), let hi = values.max(),
              lo >= config.suspectAmps,
              hi - lo <= config.flatnessMaxRange
        else { return nil }

        return String(format: "%.2f A durchgehend, Schwankung nur %.2f A über %.1f s — der Bogen flackert nicht mehr.",
                      lo, hi - lo, now.timeIntervalSince(first))
    }
}

// MARK: - Kalibrierung

/// Geführte Kalibrierfahrt: Leerlauf, normales Bogenziehen, optional ein
/// absichtlicher kurzer Kontakt. Daraus entsteht ein *Vorschlag* — die Werte
/// bleiben in den Einstellungen editierbar, weil jeder MOT, jede Elektrode und
/// jede Netzimpedanz anders sind.
struct Calibration: Equatable {
    enum Step: String, CaseIterable, Identifiable {
        case idle, arc, stuck
        var id: String { rawValue }

        var title: String {
            switch self {
            case .idle: return "Leerlauf"
            case .arc: return "Normales Bogenziehen"
            case .stuck: return "Kurzer Kontakt (optional)"
            }
        }

        var instruction: String {
            switch self {
            case .idle:
                return "MOT einschalten, Elektrode weit weg halten, nichts berühren. Gemessen wird nur der Leerlaufstrom des Trafos."
            case .arc:
                return "Ein paar normale Bögen ziehen, wie sonst auch. Die App merkt sich den Bereich, in dem du dich normalerweise bewegst."
            case .stuck:
                return "Nur wenn du es sicher beherrschst: Elektrode ganz kurz stehen lassen, bis der Strom flach wird — dann sofort weg. Überspringbar; ohne diesen Schritt schätzt die App konservativer."
            }
        }
    }

    var idle: [Double] = []
    var arc: [Double] = []
    var stuck: [Double] = []

    mutating func record(_ amps: Double, in step: Step) {
        switch step {
        case .idle: idle.append(amps)
        case .arc: arc.append(amps)
        case .stuck: stuck.append(amps)
        }
    }

    mutating func clear(_ step: Step) {
        switch step {
        case .idle: idle.removeAll()
        case .arc: arc.removeAll()
        case .stuck: stuck.removeAll()
        }
    }

    func samples(for step: Step) -> [Double] {
        switch step {
        case .idle: return idle
        case .arc: return arc
        case .stuck: return stuck
        }
    }

    /// Genug Material für einen Vorschlag? Leerlauf und Bogen sind Pflicht.
    var isUsable: Bool { idle.count >= 3 && arc.count >= 5 }

    /// Vorschlag aus den Messreihen. `nil`, solange zu wenig gemessen wurde —
    /// lieber keine Zahl als eine erfundene.
    func suggestion(basedOn current: GuardConfig = GuardConfig()) -> GuardConfig? {
        guard isUsable,
              let idleMax = idle.max(),
              let arcMax = arc.max(),
              let arcMin = arc.min()
        else { return nil }

        var c = current

        if stuck.count >= 3, let stuckMin = stuck.min(), stuckMin > arcMax {
            // Gemessene Lücke zwischen Bogen und Kleben — Schwelle mittig hinein.
            c.tripAmps = (arcMax + stuckMin) / 2
            let stuckRange = (stuck.max() ?? stuckMin) - stuckMin
            c.flatnessMaxRange = Swift.max(0.1, stuckRange * 1.5)
        } else {
            // Ohne brauchbare Kurzschlussmessung konservativ über den Bögen.
            c.tripAmps = arcMax * 1.6
            c.flatnessMaxRange = Swift.max(0.15, (arcMax - arcMin) * 0.15)
        }

        // Verdachtswert knapp über dem stärksten normalen Bogen, aber immer
        // spürbar unter der harten Schwelle — sonst greift die Flachheits-
        // prüfung nie vor ihr und wäre wirkungslos.
        c.suspectAmps = Swift.min(arcMax * 1.15, c.tripAmps * 0.75)

        // Bogen gilt als gezündet deutlich über dem Leerlauf.
        c.arcOnAmps = Swift.max(idleMax * 1.5, idleMax + (arcMin - idleMax) * 0.3)
        c.arcOffAmps = Swift.max(idleMax * 1.1, c.arcOnAmps * 0.6)

        return c
    }
}
