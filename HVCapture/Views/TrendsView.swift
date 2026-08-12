//
//  TrendsView.swift — Trends über die Zeit: Bogenzeit, Spitzenleistung, Energie
//  und Anzahl Sessions je Tag.
//
//  Beantwortet „wird es mehr/besser?" — die Session-Liste zeigt Einzelfälle,
//  hier steht die Entwicklung. Alles aus den vorhandenen Sessions gerechnet.
//

import Charts
import SwiftUI

struct TrendsView: View {
    @State private var store = SessionStore.shared
    @State private var metric: Metric = .arcSeconds
    @State private var span = 30

    enum Metric: String, CaseIterable, Identifiable {
        case arcSeconds, peakWatts, energy, sessions
        var id: String { rawValue }
        var label: String {
            switch self {
            case .arcSeconds: return "Bogenzeit"
            case .peakWatts: return "Spitzenleistung"
            case .energy: return "Energie"
            case .sessions: return "Sessions"
            }
        }
        var unit: String {
            switch self {
            case .arcSeconds: return "s"
            case .peakWatts: return "W"
            case .energy: return "Wh"
            case .sessions: return ""
            }
        }
    }

    struct DayStat: Identifiable {
        let day: Date
        var arcSeconds = 0.0
        var peakWatts = 0.0
        var energy = 0.0
        var sessions = 0
        var id: Date { day }

        func value(_ m: Metric) -> Double {
            switch m {
            case .arcSeconds: return arcSeconds
            case .peakWatts: return peakWatts
            case .energy: return energy
            case .sessions: return Double(sessions)
            }
        }
    }

    /// Sessions auf Kalendertage bündeln, jüngste `span` Tage.
    private var days: [DayStat] {
        let cal = Calendar.current
        var byDay: [Date: DayStat] = [:]
        for s in store.sessions {
            let day = cal.startOfDay(for: s.started)
            var stat = byDay[day] ?? DayStat(day: day)
            stat.arcSeconds += s.totalArcSeconds
            stat.peakWatts = max(stat.peakWatts, s.peakWatts ?? 0)
            stat.energy += s.wattHours
            stat.sessions += 1
            byDay[day] = stat
        }
        return byDay.values.sorted { $0.day < $1.day }.suffix(span)
    }

    private var total: Double {
        days.reduce(0) { $0 + $1.value(metric) }
    }

    var body: some View {
        List {
            Section {
                Picker("Kennzahl", selection: $metric) {
                    ForEach(Metric.allCases) { m in Text(m.label).tag(m) }
                }
                .pickerStyle(.segmented)

                Picker("Zeitraum", selection: $span) {
                    Text("14 Tage").tag(14)
                    Text("30 Tage").tag(30)
                    Text("90 Tage").tag(90)
                }
                .pickerStyle(.segmented)
            }

            Section {
                if days.isEmpty {
                    ContentUnavailableView("Noch keine Daten",
                                           systemImage: "chart.bar",
                                           description: Text("Sobald Sessions aufgezeichnet sind, erscheint hier ihre Entwicklung."))
                        .listRowBackground(Color.clear)
                } else {
                    Chart(days) { d in
                        BarMark(
                            x: .value("Tag", d.day, unit: .day),
                            y: .value(metric.label, d.value(metric))
                        )
                        .foregroundStyle(Palette.accentGradient)
                        .cornerRadius(3)
                    }
                    .frame(height: 240)
                    .listRowBackground(Palette.card)
                    .accessibilityLabel("\(metric.label) je Tag über \(span) Tage")
                }
            } header: {
                Text(metric.label)
            } footer: {
                if !days.isEmpty {
                    let value = metric == .peakWatts
                        ? "Höchstwert \(Int(days.map { $0.value(metric) }.max() ?? 0)) \(metric.unit)"
                        : "Summe \(Int(total)) \(metric.unit)"
                    Text(value)
                }
            }
        }
        .navigationTitle("Trends")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { store.load() }
    }
}
