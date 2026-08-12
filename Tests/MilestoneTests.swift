//
//  MilestoneTests.swift — die Freischalt-Prädikate der Abzeichen und der neue
//  Hintergrund-Abschaltgrund.
//

import Testing
import Foundation
@testable import HVCapture

@Suite("Milestones")
struct MilestoneTests {
    @Test("Leerer Stand schaltet nichts frei")
    func nothingUnlockedOnEmpty() {
        let records = Records()
        #expect(Milestones.all.allSatisfy { !$0.test(records) })
    }

    @Test("Prädikate greifen an ihren Schwellen")
    func predicatesFire() {
        var r = Records()
        r.sessionCount = 10
        r.totalArcSeconds = 61
        r.longestArc = 3.2
        r.peakWatts = 1200
        r.mostArcsInSession = 25
        r.totalWattHours = 120

        let unlocked = Set(Milestones.all.filter { $0.test(r) }.map(\.id))
        #expect(unlocked.contains("first-session"))
        #expect(unlocked.contains("sessions-10"))
        #expect(unlocked.contains("first-arc"))
        #expect(unlocked.contains("arc-minute"))
        #expect(unlocked.contains("long-arc-3"))
        #expect(unlocked.contains("peak-1k"))
        #expect(unlocked.contains("arcs-25"))
        #expect(unlocked.contains("energy-100"))
        // Die höheren Stufen bleiben zu.
        #expect(!unlocked.contains("sessions-50"))
        #expect(!unlocked.contains("long-arc-10"))
        #expect(!unlocked.contains("peak-2k"))
        #expect(!unlocked.contains("arc-10min"))
    }

    @Test("IDs sind eindeutig")
    func idsAreUnique() {
        let ids = Milestones.all.map(\.id)
        #expect(Set(ids).count == ids.count)
    }
}

@Suite("TripReason Hintergrund")
struct BackgroundTripTests {
    @Test("Hintergrund-Abschaltung ist quittierungspflichtig und dekodierbar")
    func backgroundReason() throws {
        #expect(TripReason.background.requiresAcknowledgement)
        let data = try JSONEncoder().encode(TripReason.background)
        let decoded = try JSONDecoder().decode(TripReason.self, from: data)
        #expect(decoded == .background)
    }
}
