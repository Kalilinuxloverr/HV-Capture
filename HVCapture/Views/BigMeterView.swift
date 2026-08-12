//
//  BigMeterView.swift — Grossanzeige: iPhone quer hinlegen, Werte vom Aufbau
//  aus lesen. Erscheint automatisch, wenn die Steuerung ins Querformat dreht.
//
//  Bewusst nur Anzeige plus Not-Aus — wer quer liest, steht am Aufbau und
//  braucht genau eines schnell: aus.
//

import SwiftUI

struct BigMeterView: View {
    @State private var controller = ArcController.shared
    @State private var plug = PlugLink.shared

    private var statusColor: Color {
        if controller.pendingTrip != nil { return Palette.danger }
        guard controller.isArmed else { return .gray }
        return controller.arcBurning ? Palette.warn : Palette.ok
    }

    private var statusText: String {
        if let trip = controller.pendingTrip { return "Abgeschaltet — \(trip.reason.label)" }
        guard controller.isArmed else { return "Aus" }
        return controller.arcBurning ? "Bogen brennt" : "Scharf — kein Bogen"
    }

    private func fmt(_ v: Double?, _ digits: Int) -> String {
        v?.formatted(.number.precision(.fractionLength(digits))) ?? "—"
    }

    var body: some View {
        HStack(spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("\(Int((plug.reading?.watts ?? 0).rounded()))")
                    .font(.system(size: 150, weight: .bold, design: .rounded).monospacedDigit())
                    .foregroundStyle(Palette.accentGradient)
                    .contentTransition(.numericText())
                    .minimumScaleFactor(0.4)
                    .lineLimit(1)
                Text("Watt")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 14) {
                bigStat(fmt(plug.reading?.volts, 0), "V")
                bigStat(fmt(plug.reading?.amps, 2), "A")
                if let s = controller.secondsRemaining, s >= 0 {
                    bigStat("\(s)", "s")
                }
                HStack(spacing: 8) {
                    Circle().fill(statusColor).frame(width: 14, height: 14)
                    Text(statusText)
                        .font(.headline)
                }
                Button {
                    Task { await controller.emergencyOff() }
                } label: {
                    Label("Not-Aus", systemImage: "exclamationmark.octagon.fill")
                        .font(.title2.weight(.bold))
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                }
                .buttonStyle(.borderedProminent)
                .tint(Palette.danger)
                .accessibilityLabel("Not-Aus, sofort abschalten")
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
        .accessibilityElement(children: .contain)
    }

    private func bigStat(_ value: String, _ unit: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value)
                .font(.system(size: 44, weight: .semibold, design: .rounded).monospacedDigit())
                .contentTransition(.numericText())
            Text(unit)
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }
}

#Preview(traits: .landscapeLeft) {
    BigMeterView()
}
