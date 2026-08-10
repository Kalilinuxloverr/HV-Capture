//
//  HVCaptureTests.swift — Tests für die Logik, die stillschweigend falsch sein
//  kann: Wächter-Entscheidungen, Kalibrierungs-Vorschläge, Befehlsbau und
//  Auswertung. Kamera, Netzwerk und UI sind bewusst nicht getestet — dafür gibt
//  es den Simulationsmodus in der Entwickler-Ansicht.
//

import Testing
import Foundation
@testable import HVCapture

// MARK: - Messwert

@Suite("Reading")
struct ReadingTests {
    @Test("Status-8-Antwort wird geparst")
    func parsesStatus8() throws {
        let json = """
        {"StatusSNS":{"ENERGY":{"Power":712.4,"Voltage":231.2,"Current":3.081,"Total":1.234}}}
        """
        let r = try #require(Reading(status8: Data(json.utf8)))
        #expect(r.watts == 712.4)
        #expect(r.volts == 231.2)
        #expect(r.amps == 3.081)
        #expect(r.kwh == 1.234)
    }

    @Test("ConsumptionTotal in Wh wird auf kWh normiert")
    func normalisesWattHours() throws {
        let json = """
        {"StatusSNS":{"ENERGY":{"Power":10,"Voltage":230,"Current":0.04,"ConsumptionTotal":2500}}}
        """
        let r = try #require(Reading(status8: Data(json.utf8)))
        #expect(r.kwh == 2.5)
    }

    @Test("Antwort ohne Energieblock ergibt keinen Messwert")
    func rejectsGarbage() {
        #expect(Reading(status8: Data(#"{"POWER":"ON"}"#.utf8)) == nil)
    }

    @Test("Unplausible Werte werden erkannt", arguments: [
        (-1.0, false), (0.0, true), (12.0, true), (99.0, false),
    ])
    func plausibility(amps: Double, expected: Bool) {
        #expect(Reading(volts: 230, amps: amps, watts: 230 * abs(amps)).isPlausible == expected)
    }

    @Test("Gleiche Messwerte gelten als Wiederholung")
    func detectsRepeats() {
        let a = Reading(date: Date(), volts: 230, amps: 3, watts: 690)
        let b = Reading(date: Date().addingTimeInterval(0.2), volts: 230, amps: 3, watts: 690)
        #expect(a.sameMeasurement(as: b))
        #expect(!a.sameMeasurement(as: Reading(volts: 230, amps: 3.1, watts: 713)))
    }
}

// MARK: - Wächter

@Suite("ArcGuard")
struct ArcGuardTests {
    private let t0 = Date(timeIntervalSince1970: 1_770_000_000)

    private func reading(_ amps: Double, _ offset: TimeInterval, base: Date) -> Reading {
        Reading(date: base.addingTimeInterval(offset), volts: 230, amps: amps, watts: 230 * amps)
    }

    @Test("Ohne Scharfschaltung wird nie ausgelöst")
    func silentWhenDisarmed() {
        var g = ArcGuard(config: GuardConfig())
        #expect(g.evaluate(reading(50, 0, base: t0), now: t0).trip == nil)
    }

    @Test("Grenzwert löst erst nach der Haltezeit aus")
    func thresholdNeedsHold() {
        var cfg = GuardConfig()
        cfg.flatnessEnabled = false
        cfg.tripAmps = 8
        cfg.holdSeconds = 2
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        #expect(g.evaluate(reading(9, 0.5, base: t0), now: t0.addingTimeInterval(0.5)).trip == nil)
        #expect(g.evaluate(reading(9, 1.5, base: t0), now: t0.addingTimeInterval(1.5)).trip == nil)
        #expect(g.evaluate(reading(9, 2.6, base: t0), now: t0.addingTimeInterval(2.6)).trip == .threshold)
    }

    @Test("Ein Rückgang unter den Grenzwert setzt die Haltezeit zurück")
    func thresholdResets() {
        var cfg = GuardConfig()
        cfg.flatnessEnabled = false
        cfg.tripAmps = 8
        cfg.holdSeconds = 2
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        _ = g.evaluate(reading(9, 0.5, base: t0), now: t0.addingTimeInterval(0.5))
        _ = g.evaluate(reading(3, 1.0, base: t0), now: t0.addingTimeInterval(1.0))
        _ = g.evaluate(reading(9, 1.5, base: t0), now: t0.addingTimeInterval(1.5))
        // Ohne Rücksetzer wären hier 2,3 s vergangen — mit Rücksetzer erst 0,8 s.
        #expect(g.evaluate(reading(9, 2.3, base: t0), now: t0.addingTimeInterval(2.3)).trip == nil)
    }

    @Test("Ein flackernder Verlauf löst die Flachheitsprüfung nicht aus")
    func flickeringIsSafe() {
        var cfg = GuardConfig()
        cfg.thresholdEnabled = false
        cfg.suspectAmps = 4
        cfg.flatnessWindow = 2
        cfg.flatnessMaxRange = 0.3
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        let values: [Double] = [4.5, 6.2, 4.8, 5.9, 4.4, 6.5, 5.1, 4.9, 6.0, 5.5, 4.6, 6.3]
        var trips = 0
        for (i, a) in values.enumerated() {
            let at = t0.addingTimeInterval(Double(i) * 0.25)
            if g.evaluate(reading(a, Double(i) * 0.25, base: t0), now: at).trip != nil { trips += 1 }
        }
        #expect(trips == 0)
    }

    @Test("Ein praktisch konstanter Verlauf über dem Verdachtswert löst aus")
    func constantCurrentTrips() {
        var cfg = GuardConfig()
        cfg.thresholdEnabled = false
        cfg.suspectAmps = 4
        cfg.flatnessWindow = 2
        cfg.flatnessMaxRange = 0.3
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        var tripped: TripReason?
        for i in 0..<14 {
            let at = t0.addingTimeInterval(Double(i) * 0.25)
            let a = 9.0 + Double(i % 2) * 0.01     // fast unbewegt
            if let trip = g.evaluate(reading(a, Double(i) * 0.25, base: t0), now: at).trip {
                tripped = trip
                break
            }
        }
        #expect(tripped == .flatness)
    }

    @Test("Wiederholte identische Messwerte füllen das Fenster nicht vorschnell")
    func flatnessNeedsFullWindow() {
        var cfg = GuardConfig()
        cfg.thresholdEnabled = false
        cfg.suspectAmps = 4
        cfg.flatnessWindow = 2
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        // Vier identische Werte innerhalb von 0,3 s — Fenster noch nicht voll.
        for i in 0..<4 {
            let at = t0.addingTimeInterval(Double(i) * 0.1)
            #expect(g.evaluate(reading(9, Double(i) * 0.1, base: t0), now: at).trip == nil)
        }
    }

    @Test("Ausbleibende Messwerte lösen nach der Wartezeit aus")
    func dataLossTrips() {
        var cfg = GuardConfig()
        cfg.dataLossSeconds = 5
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        _ = g.evaluate(reading(3, 0, base: t0), now: t0)
        #expect(g.evaluate(nil, now: t0.addingTimeInterval(3)).trip == nil)
        #expect(g.evaluate(nil, now: t0.addingTimeInterval(5.1)).trip == .dataLoss)
    }

    @Test("Kommen nie Messwerte, zählt die Wartezeit ab dem Scharfschalten")
    func dataLossFromArmWhenNeverAnyReading() {
        var cfg = GuardConfig()
        cfg.dataLossSeconds = 5
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)
        #expect(g.evaluate(nil, now: t0.addingTimeInterval(5.5)).trip == .dataLoss)
    }

    @Test("Unplausible Werte gelten als Datenverlust, nicht als Entwarnung")
    func implausibleCountsAsLoss() {
        var cfg = GuardConfig()
        cfg.dataLossSeconds = 2
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)
        _ = g.evaluate(reading(3, 0, base: t0), now: t0)
        let bad = Reading(volts: 230, amps: -5, watts: -1000)
        #expect(g.evaluate(bad, now: t0.addingTimeInterval(2.5)).trip == .dataLoss)
    }

    @Test("Bogen-Erkennung nutzt Hysterese")
    func arcHysteresis() {
        var cfg = GuardConfig()
        cfg.thresholdEnabled = false
        cfg.flatnessEnabled = false
        cfg.arcOnAmps = 1.2
        cfg.arcOffAmps = 0.7
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)

        #expect(g.evaluate(reading(0.3, 0, base: t0), now: t0).arcBurning == false)
        #expect(g.evaluate(reading(1.5, 1, base: t0), now: t0.addingTimeInterval(1)).arcStarted)
        // Zwischen Aus- und Einschwelle bleibt der Bogen an.
        #expect(g.evaluate(reading(0.9, 2, base: t0), now: t0.addingTimeInterval(2)).arcBurning)
        #expect(g.evaluate(reading(0.4, 3, base: t0), now: t0.addingTimeInterval(3)).arcEnded)
    }

    @Test("Scharfschalten löscht die Historie der vorherigen Phase")
    func armClearsHistory() {
        var cfg = GuardConfig()
        cfg.flatnessEnabled = false
        cfg.tripAmps = 8
        cfg.holdSeconds = 2
        var g = ArcGuard(config: cfg)
        g.arm(now: t0)
        _ = g.evaluate(reading(9, 0, base: t0), now: t0)

        g.arm(now: t0.addingTimeInterval(10))
        #expect(g.evaluate(reading(9, 10.5, base: t0), now: t0.addingTimeInterval(10.5)).trip == nil)
    }
}

// MARK: - Kalibrierung

@Suite("Calibration")
struct CalibrationTests {
    @Test("Ohne genug Messwerte gibt es keinen Vorschlag")
    func needsData() {
        var c = Calibration()
        c.idle = [0.3, 0.3]
        c.arc = [3, 4]
        #expect(c.isUsable == false)
        #expect(c.suggestion() == nil)
    }

    @Test("Vorschlag hält den Verdachtswert unter dem Grenzwert")
    func suspectStaysBelowTrip() throws {
        var c = Calibration()
        c.idle = [0.3, 0.32, 0.29, 0.31]
        c.arc = [2.5, 3.1, 4.0, 5.2, 4.4, 3.8]
        let s = try #require(c.suggestion())
        #expect(s.suspectAmps < s.tripAmps)
        #expect(s.problems.isEmpty)
    }

    @Test("Eine gemessene Kurzschlussreihe legt den Grenzwert dazwischen")
    func usesStuckMeasurement() throws {
        var c = Calibration()
        c.idle = [0.3, 0.3, 0.3]
        c.arc = [2.0, 3.0, 4.0, 3.5, 2.8]
        c.stuck = [9.0, 9.02, 8.99]
        let s = try #require(c.suggestion())
        #expect(s.tripAmps > 4.0)
        #expect(s.tripAmps < 9.0)
    }

    @Test("Bogen-Aus liegt immer unter Bogen-Ein")
    func hysteresisOrdering() throws {
        var c = Calibration()
        c.idle = [0.5, 0.55, 0.48, 0.52]
        c.arc = [1.0, 1.4, 2.0, 1.8, 1.2]
        let s = try #require(c.suggestion())
        #expect(s.arcOffAmps < s.arcOnAmps)
    }
}

// MARK: - Konfiguration

@Suite("GuardConfig")
struct GuardConfigTests {
    @Test("Standardwerte sind in sich stimmig")
    func defaultsAreConsistent() {
        #expect(GuardConfig().problems.isEmpty)
    }

    @Test("Verdachtswert über dem Grenzwert wird beanstandet")
    func flagsUselessFlatness() {
        var c = GuardConfig()
        c.suspectAmps = 12
        c.tripAmps = 8
        #expect(!c.problems.isEmpty)
    }

    @Test("Verdrehte Hysterese wird beanstandet")
    func flagsInvertedHysteresis() {
        var c = GuardConfig()
        c.arcOnAmps = 0.5
        c.arcOffAmps = 1.0
        #expect(!c.problems.isEmpty)
    }
}

// MARK: - Befehle

@Suite("PlugCommand")
struct PlugCommandTests {
    @Test("Schaltbefehle")
    func power() {
        #expect(PlugCommand.power(on: true) == "Power%20On")
        #expect(PlugCommand.power(on: false) == "Power%20Off")
    }

    @Test("Selbstabschaltung nutzt die Auftrags-ID")
    func autoOff() {
        #expect(PlugCommand.autoOffArm(seconds: 30, id: 91)
                == "addRepeatingEventID%2030%201%2091%20POWER%20OFF")
        #expect(PlugCommand.autoOffCancel(id: 91) == "cancelRepeatingEvent%2091")
    }

    @Test("Sekunden werden in den gültigen Bereich geklemmt")
    func clamping() {
        #expect(PlugCommand.clamp(0) == 1)
        #expect(PlugCommand.clamp(99_999) == 3600)
    }

    @Test("Fehlerhafte Antworten der Dose werden erkannt", arguments: [
        ("Unknown command", true), ("{\"POWER\":\"ON\"}", false), ("Invalid argument", true),
    ])
    func unknownCommand(text: String, expected: Bool) {
        #expect(PlugCommand.indicatesUnknownCommand(text) == expected)
    }

    @Test("Schaltzustand wird aus der Antwort gelesen")
    func powerState() {
        #expect(PlugLink.parsePowerState(Data(#"{"POWER":"ON"}"#.utf8)) == true)
        #expect(PlugLink.parsePowerState(Data(#"{"POWER":"OFF"}"#.utf8)) == false)
        #expect(PlugLink.parsePowerState(Data(#"{"x":1}"#.utf8)) == nil)
    }
}

// MARK: - Auswertung

@Suite("Session")
struct SessionTests {
    private func session(samples: [Sample], arcs: [ArcEvent] = []) -> Session {
        var s = Session(started: Date(timeIntervalSince1970: 1_770_000_000))
        s.samples = samples
        s.arcs = arcs
        return s
    }

    @Test("Energie wird über die Messreihe integriert")
    func integratesEnergy() {
        // 3600 W konstant über 2 s = 2 Wh
        let s = session(samples: [Sample(t: 0, v: 230, a: 15.6, w: 3600),
                                  Sample(t: 2, v: 230, a: 15.6, w: 3600)])
        #expect(abs(s.wattHours - 2.0) < 0.001)
    }

    @Test("Lücken werden nicht überbrückt")
    func skipsGaps() {
        // 30 s Lücke: dazwischen wurde nicht gemessen, also darf auch keine
        // Energie erfunden werden.
        let s = session(samples: [Sample(t: 0, v: 230, a: 15.6, w: 3600),
                                  Sample(t: 30, v: 230, a: 15.6, w: 3600)])
        #expect(s.wattHours == 0)
    }

    @Test("CSV hat Kopfzeile und Punkt als Dezimaltrenner")
    func csvFormat() {
        let s = session(samples: [Sample(t: 0.5, v: 231.2, a: 3.081, w: 712.4)])
        let lines = s.csv.split(separator: "\n")
        #expect(lines.first == "t_s,volts,amps,watts")
        #expect(lines[1] == "0.500,231.2,3.081,712.4")
    }

    @Test("Bogenzeiten summieren sich, offene Bögen zählen nicht mit")
    func arcTotals() {
        let s = session(samples: [], arcs: [
            ArcEvent(start: 0, end: 1.5),
            ArcEvent(start: 3, end: 5.5),
            ArcEvent(start: 8, end: nil),      // brennt noch
        ])
        #expect(abs(s.totalArcSeconds - 4.0) < 0.001)
        #expect(s.longestArc == 2.5)
    }
}

@Suite("Auswertung über mehrere Sessions")
struct AggregateTests {
    private func made(electrode: String, arcs: [ArcEvent], started: Date) -> Session {
        var s = Session(started: started, electrode: electrode)
        s.arcs = arcs
        s.samples = [Sample(t: 0, v: 230, a: 5, w: 1150)]
        return s
    }

    @Test("Rekorde nehmen die Bestwerte über alle Sessions")
    func records() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let all = [
            made(electrode: "A", arcs: [ArcEvent(start: 0, end: 2)], started: base),
            made(electrode: "A", arcs: [ArcEvent(start: 0, end: 7)], started: base.addingTimeInterval(100)),
        ]
        let r = Records.from(all)
        #expect(r.longestArc == 7)
        #expect(r.sessionCount == 2)
        #expect(abs(r.totalArcSeconds - 9) < 0.001)
    }

    @Test("Verschleiss wird je Elektrode summiert und absteigend sortiert")
    func wear() {
        let base = Date(timeIntervalSince1970: 1_770_000_000)
        let all = [
            made(electrode: "Kupfer", arcs: [ArcEvent(start: 0, end: 2)], started: base),
            made(electrode: "Wolfram", arcs: [ArcEvent(start: 0, end: 9)], started: base.addingTimeInterval(60)),
            made(electrode: "Kupfer", arcs: [ArcEvent(start: 0, end: 3)], started: base.addingTimeInterval(120)),
        ]
        let w = ElectrodeWear.from(all)
        #expect(w.first?.name == "Wolfram")
        let kupfer = w.first { $0.name == "Kupfer" }
        #expect(kupfer?.sessions == 2)
        #expect(abs((kupfer?.arcSeconds ?? 0) - 5) < 0.001)
        #expect(kupfer?.lastUsed == base.addingTimeInterval(120))
    }
}

// MARK: - Energie & Kosten

@Suite("EnergyCost")
struct EnergyCostTests {
    /// Gregorianisch, Wien, Woche ab Montag — fixiert, damit der Test nicht von
    /// der Regionseinstellung des Testrechners abhängt.
    private var cal: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Europe/Vienna")!
        c.firstWeekday = 2
        return c
    }

    private func date(_ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        DateComponents(calendar: cal, year: y, month: m, day: d, hour: hour).date!
    }

    /// Session mit exakt 1 Wh: zwei Messpunkte, 1 s Abstand, 3600 W.
    private func session(started: Date) -> Session {
        var s = Session(started: started)
        s.samples = [Sample(t: 0, v: 230, a: 15.7, w: 3600),
                     Sample(t: 1, v: 230, a: 15.7, w: 3600)]
        return s
    }

    @Test("Summen buchen auf Tag, Woche, Monat und Gesamt")
    func sums() {
        // Mo 2026-08-10: heute. So 2026-08-09: Monat, aber nicht Woche. Juli: nur Gesamt.
        let now = date(2026, 8, 10)
        let all = [session(started: now.addingTimeInterval(-3600)),
                   session(started: date(2026, 8, 9)),
                   session(started: date(2026, 7, 15))]
        let s = EnergyCost.sums(sessions: all, now: now, calendar: cal)
        #expect(abs(s.todayKwh - 0.001) < 1e-9)
        #expect(abs(s.weekKwh - 0.001) < 1e-9)
        #expect(abs(s.monthKwh - 0.002) < 1e-9)
        #expect(abs(s.alltimeKwh - 0.003) < 1e-9)
    }

    @Test("Tagesliste gruppiert nach Kalendertag, älteste zuerst")
    func days() {
        let all = [session(started: date(2026, 8, 9, hour: 9)),
                   session(started: date(2026, 8, 9, hour: 21)),
                   session(started: date(2026, 8, 10))]
        let d = EnergyCost.days(sessions: all, calendar: cal)
        #expect(d.count == 2)
        #expect(d.first?.date == cal.startOfDay(for: date(2026, 8, 9)))
        #expect(abs((d.first?.kwh ?? 0) - 0.002) < 1e-9)
        #expect(abs((d.last?.kwh ?? 0) - 0.001) < 1e-9)
    }

    @Test("Euro aus kWh und ct/kWh")
    func euro() {
        #expect(EnergyCost.euro(2.0, ctPerKwh: 30) == 0.6)
    }

    @Test("aWATTar-Antwort wird geparst (Eur/MWh → ct/kWh, ms-Epoche)")
    func awattarParse() throws {
        let json = """
        {"data":[{"start_timestamp":1754820000000,"end_timestamp":1754823600000,"marketprice":92.34},
                 {"start_timestamp":1754823600000,"end_timestamp":1754827200000,"marketprice":-5.0}]}
        """
        let prices = Awattar.parse(Data(json.utf8))
        #expect(prices.count == 2)
        let first = try #require(prices.first)
        #expect(abs(first.ctPerKwh - 9.234) < 1e-9)
        #expect(first.start == Date(timeIntervalSince1970: 1_754_820_000))
        #expect(prices.last?.ctPerKwh == -0.5)   // negative Börsenpreise gibt es wirklich
    }

    @Test("Kaputte aWATTar-Antwort ergibt leere Liste")
    func awattarGarbage() {
        #expect(Awattar.parse(Data("<html>".utf8)).isEmpty)
        #expect(Awattar.parse(Data(#"{"data":"nope"}"#.utf8)).isEmpty)
    }
}
