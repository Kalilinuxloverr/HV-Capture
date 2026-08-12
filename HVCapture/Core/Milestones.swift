//
//  Milestones.swift — Meilenstein-Abzeichen aus den Allzeit-Rekorden.
//
//  Reine Auswertung über `Records`: jeder Meilenstein ist ein Prädikat. Was
//  einmal freigeschaltet ist, bleibt freigeschaltet (UserDefaults), auch wenn
//  Sessions später gelöscht werden. Beim allerersten Lauf wird der Bestand
//  still übernommen — sonst regnet es beim Update zwanzig Toasts auf einmal.
//

import Foundation

struct Milestone: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String
    let test: (Records) -> Bool

    static func == (lhs: Milestone, rhs: Milestone) -> Bool { lhs.id == rhs.id }
}

enum Milestones {
    static let all: [Milestone] = [
        Milestone(id: "first-session", title: "Erste Session",
                  detail: "Eine Session aufgezeichnet.", symbol: "flag.fill",
                  test: { $0.sessionCount >= 1 }),
        Milestone(id: "first-arc", title: "Erster Bogen",
                  detail: "Der erste Lichtbogen im Protokoll.", symbol: "bolt.fill",
                  test: { $0.totalArcSeconds > 0 }),
        Milestone(id: "sessions-10", title: "Stammgast",
                  detail: "10 Sessions.", symbol: "flag.2.crossed.fill",
                  test: { $0.sessionCount >= 10 }),
        Milestone(id: "sessions-50", title: "Dauerbetrieb",
                  detail: "50 Sessions.", symbol: "crown.fill",
                  test: { $0.sessionCount >= 50 }),
        Milestone(id: "arc-minute", title: "Eine Minute Feuer",
                  detail: "60 Sekunden Bogenzeit insgesamt.", symbol: "timer",
                  test: { $0.totalArcSeconds >= 60 }),
        Milestone(id: "arc-10min", title: "Zehn Minuten Feuer",
                  detail: "10 Minuten Bogenzeit insgesamt.", symbol: "flame.fill",
                  test: { $0.totalArcSeconds >= 600 }),
        Milestone(id: "long-arc-3", title: "Steher",
                  detail: "Ein Bogen brannte 3 Sekunden am Stück.", symbol: "bolt.badge.clock.fill",
                  test: { $0.longestArc >= 3 }),
        Milestone(id: "long-arc-10", title: "Marathon-Bogen",
                  detail: "Ein Bogen brannte 10 Sekunden am Stück.", symbol: "bolt.ring.closed",
                  test: { $0.longestArc >= 10 }),
        Milestone(id: "peak-1k", title: "Kilowatt-Klasse",
                  detail: "Über 1000 W Spitzenleistung.", symbol: "gauge.high",
                  test: { $0.peakWatts >= 1000 }),
        Milestone(id: "peak-2k", title: "Zwei Kilowatt",
                  detail: "Über 2000 W Spitzenleistung.", symbol: "bolt.trianglebadge.exclamationmark.fill",
                  test: { $0.peakWatts >= 2000 }),
        Milestone(id: "arcs-25", title: "Serienzünder",
                  detail: "25 Bögen in einer einzigen Session.", symbol: "sparkles",
                  test: { $0.mostArcsInSession >= 25 }),
        Milestone(id: "energy-100", title: "Stromrechnung",
                  detail: "100 Wh Gesamtenergie verfeuert.", symbol: "battery.100percent.bolt",
                  test: { $0.totalWattHours >= 100 }),
    ]
}

@MainActor
@Observable
final class MilestoneTracker {
    static let shared = MilestoneTracker()

    /// Frisch freigeschaltet — die Oberfläche zeigt dazu einen Toast.
    private(set) var justUnlocked: Milestone?

    private var unlocked: Set<String>

    private static let storageKey = "milestonesUnlocked"
    private static let seededKey = "milestonesSeeded"

    private init() {
        unlocked = Set(UserDefaults.standard.stringArray(forKey: Self.storageKey) ?? [])
    }

    func isUnlocked(_ m: Milestone) -> Bool { unlocked.contains(m.id) }

    func clearToast() { justUnlocked = nil }

    /// Prüft alle Meilensteine gegen den aktuellen Stand. Pro Aufruf höchstens
    /// ein Toast — mehrere neue erscheinen über die folgenden Sessions.
    func evaluate(_ records: Records) {
        let d = UserDefaults.standard
        let silent = !d.bool(forKey: Self.seededKey)
        for m in Milestones.all where !unlocked.contains(m.id) && m.test(records) {
            unlocked.insert(m.id)
            if !silent, justUnlocked == nil {
                justUnlocked = m
                Haptics.success()
            }
        }
        d.set(Array(unlocked).sorted(), forKey: Self.storageKey)
        d.set(true, forKey: Self.seededKey)
    }
}
