//
//  LiveState.swift — Datenschema der Live Activity.
//
//  Wird von App UND Widget-Extension kompiliert — deshalb nur Foundation und
//  ActivityKit, keine anderen Projekttypen.
//

import ActivityKit
import Foundation

struct HVActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var watts: Double?
        var amps: Double?
        var volts: Double?
        /// Sekunden bis zur Abschaltung; negativ = Puls-Pause.
        var secondsRemaining: Int?
        var armed: Bool
        var arcBurning: Bool
        /// Gesetzt = abgeschaltet, Grund als Text.
        var tripLabel: String?
    }

    var modeLabel: String
    var startedAt: Date
}

// MARK: - Anzeige

extension HVActivityAttributes.ContentState {
    var wattsText: String { watts.map { String(format: "%.0f W", $0) } ?? "— W" }
    var ampsText: String { amps.map { String(format: "%.1f A", $0) } ?? "— A" }
    var voltsText: String { volts.map { String(format: "%.0f V", $0) } ?? "— V" }

    var countdownText: String {
        guard let s = secondsRemaining else { return "—" }
        return s >= 0 ? "\(s) s" : "Pause \(-s) s"
    }

    var statusText: String {
        if let tripLabel { return "Abgeschaltet — \(tripLabel)" }
        if !armed { return "Aus" }
        return arcBurning ? "Lichtbogen aktiv" : "Aktiv"
    }

    /// SF-Symbol-Name passend zu `statusText`.
    var statusSymbol: String {
        if tripLabel != nil { return "bolt.slash.fill" }
        if !armed { return "power" }
        return arcBurning ? "bolt.fill" : "checkmark.circle.fill"
    }
}
