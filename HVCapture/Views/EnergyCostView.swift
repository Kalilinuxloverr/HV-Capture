//
//  EnergyCostView.swift — „Energie & Kosten": was die Messfahrten an Strom
//  gekostet haben (Fixtarif), Tages-Chart und EPEX-Spot-Info (aWATTar).
//  Portiert aus CoolerOS; Datenquelle sind hier die Sessions, nicht der
//  Dosen-Zähler — der zählt alles, was je in der Dose steckte, die Sessions
//  nur den Trafo während einer Messfahrt.
//

import Charts
import SwiftUI

struct EnergyCostView: View {
    @State private var store = SessionStore.shared
    @AppStorage("strompreisCt") private var priceCt = 30.0
    @State private var spot: [SpotPrice] = []
    @State private var spotLoaded = false

    private var sums: EnergyCost.Sums { EnergyCost.sums(sessions: store.sessions) }
    private var chartDays: [EnergyCost.Day] { EnergyCost.days(sessions: store.sessions) }

    var body: some View {
        List {
            summarySection
            chartSection
            priceSection
            spotSection
        }
        .scrollContentBackground(.hidden)
        .appBackground()
        .navigationTitle("Energie & Kosten")
        .task {
            spot = await Awattar.fetch()
            spotLoaded = true
        }
    }

    private func euroText(_ kwh: Double) -> String {
        EnergyCost.euro(kwh, ctPerKwh: priceCt)
            .formatted(.currency(code: "EUR").precision(.fractionLength(2)))
    }

    // MARK: Zusammenfassung

    private var summarySection: some View {
        Section {
            HStack(spacing: 12) {
                costStat("Heute", sums.todayKwh)
                costStat("Woche", sums.weekKwh)
                costStat("Monat", sums.monthKwh)
                costStat("Gesamt", sums.alltimeKwh)
            }
            .listRowBackground(Palette.card)
        } header: {
            Text("Kosten (\(priceCt.formatted(.number.precision(.fractionLength(0...1)))) ct/kWh)")
        } footer: {
            Text("Berechnet aus der integrierten Energie der Sessions × deinem Preis. Es zählt nur, was während einer Messfahrt an der Dose hing — steck also ausser dem Trafo nichts dazu, sonst zahlt es der Trafo auf dem Papier mit.")
        }
    }

    private func costStat(_ title: String, _ kwh: Double) -> some View {
        VStack(spacing: 3) {
            Text(euroText(kwh))
                .font(.subheadline.weight(.bold))
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(kwh.formatted(.number.precision(.fractionLength(3))) + " kWh")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .monospacedDigit()
                .minimumScaleFactor(0.6)
                .lineLimit(1)
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue("\(euroText(kwh)), \(kwh.formatted(.number.precision(.fractionLength(3)))) Kilowattstunden")
    }

    // MARK: Tages-Chart

    @ViewBuilder private var chartSection: some View {
        if !chartDays.isEmpty {
            Section("Tages-Verlauf") {
                Chart(chartDays) { day in
                    BarMark(
                        x: .value("Tag", day.date, unit: .day),
                        y: .value("€", EnergyCost.euro(day.kwh, ctPerKwh: priceCt))
                    )
                    .foregroundStyle(Palette.accent)
                    .cornerRadius(3)
                }
                .chartYAxisLabel("€ / Tag")
                .frame(height: 160)
                .listRowBackground(Palette.card)
                .accessibilityLabel("Tageskosten der letzten \(chartDays.count) Session-Tage")
            }
        }
    }

    // MARK: Strompreis

    private var priceSection: some View {
        Section {
            HStack {
                TextField("30,0", value: $priceCt, format: .number.precision(.fractionLength(0...2)))
                    .keyboardType(.decimalPad)
                    .frame(width: 90)
                    .accessibilityLabel("Strompreis in Cent pro Kilowattstunde")
                Text("ct/kWh")
                    .foregroundStyle(.secondary)
            }
            .listRowBackground(Palette.card)
        } header: {
            Text("Dein Strompreis")
        } footer: {
            Text("Gesamtpreis von deiner Rechnung (Energie + Netz + Abgaben).")
        }
    }

    // MARK: EPEX-Spot Österreich

    private var currentSpot: SpotPrice? {
        spot.last { $0.start <= Date() }
    }

    private var spotSection: some View {
        Section {
            if spot.isEmpty {
                Text(spotLoaded ? "Spot-Preise gerade nicht abrufbar." : "Lade Spot-Preise…")
                    .foregroundStyle(.secondary)
                    .listRowBackground(Palette.card)
            } else {
                Chart(spot) { p in
                    BarMark(
                        x: .value("Stunde", p.start, unit: .hour),
                        y: .value("ct/kWh", p.ctPerKwh)
                    )
                    .foregroundStyle(p.id == currentSpot?.id ? Palette.accent : Palette.accent.opacity(0.35))
                }
                .chartYAxisLabel("ct/kWh")
                .frame(height: 130)
                .listRowBackground(Palette.card)
                .accessibilityLabel("Stündliche Börsenpreise")
                if let cur = currentSpot {
                    LabeledContent("Jetzt", value: "\(cur.ctPerKwh.formatted(.number.precision(.fractionLength(1)))) ct/kWh")
                        .listRowBackground(Palette.card)
                }
            }
        } header: {
            Text("Börsenpreis Österreich")
        } footer: {
            Text("EPEX Spot AT (aWATTar), stündlich, netto — der Börsenpreis fürs ganze Land, nicht dein Tarif. Bei Fixtarif reine Info.")
        }
    }
}
