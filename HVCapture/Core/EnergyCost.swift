//
//  EnergyCost.swift — Kosten-Mathe aus den Session-Energien + EPEX-Spot-Preise
//  Österreich (aWATTar). Portiert aus CoolerOS, aber ohne dessen CYD/MQTT-
//  Buchhaltung: Datenquelle ist hier die integrierte Energie der Sessions
//  (Trapez über die Messreihe) — also genau das, was während einer Messfahrt
//  an der Dose hing, und sonst nichts.
//

import Foundation

/// Kosten-Mathe: Fixtarif, Preis in ct/kWh. Alles aus `Session.wattHours`,
/// gebucht auf den Starttag der Session.
enum EnergyCost {
    struct Sums: Equatable {
        var todayKwh = 0.0
        var weekKwh = 0.0
        var monthKwh = 0.0
        var alltimeKwh = 0.0
    }

    static func sums(sessions: [Session], now: Date = Date(),
                     calendar: Calendar = .current) -> Sums {
        var s = Sums()
        let dayStart = calendar.startOfDay(for: now)
        let weekStart = calendar.dateInterval(of: .weekOfYear, for: now)?.start
        let monthStart = calendar.dateInterval(of: .month, for: now)?.start
        for session in sessions {
            let kwh = session.wattHours / 1000
            s.alltimeKwh += kwh
            if session.started >= dayStart { s.todayKwh += kwh }
            if let ws = weekStart, session.started >= ws { s.weekKwh += kwh }
            if let ms = monthStart, session.started >= ms { s.monthKwh += kwh }
        }
        return s
    }

    /// Ein Tag mit Session-Energie — Grundlage des Balken-Charts.
    struct Day: Equatable, Identifiable {
        let date: Date
        let kwh: Double
        var id: Date { date }
    }

    /// Tages-Summen der letzten `limit` Kalendertage mit Sessions, älteste zuerst.
    static func days(sessions: [Session], limit: Int = 14,
                     calendar: Calendar = .current) -> [Day] {
        var byDay: [Date: Double] = [:]
        for session in sessions {
            byDay[calendar.startOfDay(for: session.started), default: 0]
                += session.wattHours / 1000
        }
        return byDay.keys.sorted().suffix(limit)
            .map { Day(date: $0, kwh: byDay[$0] ?? 0) }
    }

    /// € aus kWh und ct/kWh — zentral, damit UI und Tests dieselbe Rundung nutzen.
    static func euro(_ kwh: Double, ctPerKwh: Double) -> Double {
        kwh * ctPerKwh / 100
    }
}

/// Stündlicher EPEX-Spot-Preis Österreich (Börsenpreis, netto — NICHT der
/// Endkundenpreis; bei Fixtarif reine Info).
struct SpotPrice: Equatable, Identifiable {
    let start: Date
    let ctPerKwh: Double
    var id: Date { start }
}

enum Awattar {
    static let url = URL(string: "https://api.awattar.at/v1/marketdata")!

    /// `{"data":[{"start_timestamp":<ms>,"end_timestamp":<ms>,"marketprice":<Eur/MWh>},…]}`
    static func parse(_ data: Data) -> [SpotPrice] {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = obj["data"] as? [[String: Any]] else { return [] }
        return rows.compactMap { row in
            guard let ts = (row["start_timestamp"] as? NSNumber)?.doubleValue,
                  let price = (row["marketprice"] as? NSNumber)?.doubleValue
            else { return nil }
            // Eur/MWh → ct/kWh: 1 Eur/MWh = 0,1 ct/kWh
            return SpotPrice(start: Date(timeIntervalSince1970: ts / 1000), ctPerKwh: price / 10)
        }
    }

    /// Heutige (+ ab ~14 Uhr morgige) Stundenpreise — [] bei Netz-/API-Fehler.
    static func fetch() async -> [SpotPrice] {
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return [] }
        return parse(data)
    }
}
