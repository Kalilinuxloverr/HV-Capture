//
//  ResonanceExplainerView.swift — Interaktive Erklärung von Resonanz.
//
//  Bewusst nur Erklärung, keine Bauanleitung: der Regler fährt die Frequenz
//  durch, die Kurve zeigt, wie die Spannung bei Resonanz aufschaukelt, und der
//  Text sagt, was ein Kondensator dabei tut. Es werden KEINE Bauteilwerte,
//  keine Verschaltung und keine Dimensionierung genannt — der Abschnitt endet
//  mit dem Grund, warum ich beim Kondensator-Aufbau nicht mitbaue: die
//  gespeicherte Ladung bleibt tödlich, auch wenn der Stecker gezogen ist.
//

import SwiftUI

struct ResonanceExplainerView: View {
    /// Anregungsfrequenz 0…1; 0,5 ist Resonanz (Kurvenspitze).
    @State private var tuning = 0.28

    /// Resonanzüberhöhung als Glockenkurve um die Mitte.
    private func response(at x: Double) -> Double {
        exp(-60 * (x - 0.5) * (x - 0.5))
    }

    private var currentGain: Double { response(at: tuning) }

    var body: some View {
        List {
            introSection
            curveSection
            capSection
            dangerSection
        }
        .navigationTitle("Resonanz")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Einleitung

    private var introSection: some View {
        Section {
            Text("Ein Kondensator und eine Spule bilden zusammen einen Schwingkreis. Regt man ihn genau in seiner Eigenfrequenz an, schaukelt sich die Spannung von Schwingung zu Schwingung auf — wie ein Kind auf der Schaukel, das man im richtigen Takt anschubst. Das ist Resonanz.")
                .font(.callout)
        } header: {
            Text("Die Idee")
        }
    }

    // MARK: Kurve

    private var curveSection: some View {
        Section {
            ResonanceCurve(tuning: tuning, gain: currentGain)
                .frame(height: 180)
                .listRowInsets(EdgeInsets(top: 8, leading: 8, bottom: 8, trailing: 8))
                .accessibilityLabel("Resonanzkurve")
                .accessibilityValue(gainWord)

            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text("Anregungsfrequenz")
                    Spacer()
                    Text(String(format: "×%.1f Spannung", 1 + currentGain * 9))
                        .monospacedDigit()
                        .foregroundStyle(currentGain > 0.6 ? Palette.danger : Palette.accent)
                }
                Slider(value: $tuning, in: 0...1)
                    .accessibilityLabel("Anregungsfrequenz")
            }
            .font(.subheadline)
        } header: {
            Text("Ausprobieren")
        } footer: {
            Text(explanationText)
        }
    }

    private var gainWord: String {
        switch currentGain {
        case ..<0.15: return "weit weg von der Resonanz, kaum Überhöhung"
        case ..<0.6: return "nähert sich der Resonanz"
        default: return "nahe der Resonanz, starke Überhöhung"
        }
    }

    private var explanationText: String {
        switch currentGain {
        case ..<0.15:
            return "Fern der Eigenfrequenz passiert wenig — der Kreis schluckt die Anregung, die Spannung bleibt niedrig."
        case ..<0.6:
            return "Näher an der Eigenfrequenz beginnt der Kreis mitzuschwingen, die Spannung steigt merklich über die Eingangsspannung."
        default:
            return "In Resonanz addieren sich die Schwingungen: Die Spannung kann ein Vielfaches der Eingangsspannung erreichen — genau das macht einen Kondensator-Aufbau so viel stärker und zugleich so viel gefährlicher."
        }
    }

    // MARK: Kondensator

    private var capSection: some View {
        Section {
            Text("Der Kondensator ist das Bauteil, das die Energie zwischenspeichert. Er lädt sich in jeder Halbwelle auf und gibt die Ladung wieder ab. Im Resonanzfall pendelt so viel Energie zwischen Spule und Kondensator hin und her, dass die Spannungsspitzen die einzelne Trafo-Spannung weit übersteigen.")
                .font(.callout)
            Label("Deshalb liefert ein resonanter Aufbau längere, hellere Bögen — bei gleicher Netzleistung.",
                  systemImage: "arrow.up.right")
                .font(.footnote)
                .foregroundStyle(Palette.accent)
        } header: {
            Text("Was der Kondensator tut")
        }
    }

    // MARK: Gefahr / meine Linie

    private var dangerSection: some View {
        Section {
            Label {
                Text("Genau diese gespeicherte Ladung ist der Grund, warum ich bei Kondensator-Aufbauten nicht mitbaue. Bei deinem kondensatorlosen Aufbau gilt: Stecker raus, Spannung weg. Ein geladener Kondensator dagegen hält seine tödliche Ladung, auch wenn der Stecker längst gezogen ist — er kann Stunden später noch einen lebensgefährlichen Schlag abgeben.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "exclamationmark.octagon.fill")
                    .foregroundStyle(Palette.danger)
            }
            Label {
                Text("Wer trotzdem einen Schwingkreis aufbaut, muss jeden Kondensator vor dem Anfassen aktiv entladen — nicht darauf vertrauen, dass er sich selbst entlädt.")
                    .font(.footnote)
                    .fixedSize(horizontal: false, vertical: true)
            } icon: {
                Image(systemName: "bolt.slash.fill")
                    .foregroundStyle(Palette.warn)
            }
        } header: {
            Text("Warum das gefährlich ist")
        }
    }
}

// MARK: - Resonanzkurve

/// Glockenkurve der Spannungsüberhöhung über der Frequenz, mit beweglicher
/// Markierung an der eingestellten Frequenz. Rein illustrativ.
private struct ResonanceCurve: View {
    let tuning: Double
    let gain: Double

    var body: some View {
        Canvas { ctx, size in
            let grid = GraphicsContext.Shading.color(.secondary.opacity(0.2))
            let curve = GraphicsContext.Shading.color(Palette.accent)
            let marker = GraphicsContext.Shading.color(gain > 0.6 ? Palette.danger : Palette.accent)

            let inset = 12.0
            let w = size.width - inset * 2
            let h = size.height - inset * 2

            // Achsen.
            var axes = Path()
            axes.move(to: CGPoint(x: inset, y: inset))
            axes.addLine(to: CGPoint(x: inset, y: inset + h))
            axes.addLine(to: CGPoint(x: inset + w, y: inset + h))
            ctx.stroke(axes, with: grid, lineWidth: 1)

            func point(_ x: Double) -> CGPoint {
                let peak = exp(-60 * (x - 0.5) * (x - 0.5))
                return CGPoint(x: inset + x * w, y: inset + h - peak * h * 0.92)
            }

            // Kurve.
            var line = Path()
            line.move(to: point(0))
            for i in 1...120 {
                line.addLine(to: point(Double(i) / 120))
            }
            ctx.stroke(line, with: curve, lineWidth: 2)

            // Fläche unter der Kurve dezent füllen.
            var area = line
            area.addLine(to: CGPoint(x: inset + w, y: inset + h))
            area.addLine(to: CGPoint(x: inset, y: inset + h))
            area.closeSubpath()
            ctx.fill(area, with: .color(Palette.accent.opacity(0.10)))

            // Markierung an der eingestellten Frequenz.
            let p = point(tuning)
            var stem = Path()
            stem.move(to: CGPoint(x: p.x, y: inset + h))
            stem.addLine(to: p)
            ctx.stroke(stem, with: marker, lineWidth: 1.5)
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - 5, y: p.y - 5, width: 10, height: 10)),
                     with: marker)

            // Achsbeschriftung.
            let fLabel = ctx.resolve(Text("Frequenz").font(.system(size: 9)).foregroundColor(.secondary))
            ctx.draw(fLabel, at: CGPoint(x: inset + w / 2, y: inset + h + 2), anchor: .top)
            let vLabel = ctx.resolve(Text("Spannung").font(.system(size: 9)).foregroundColor(.secondary))
            ctx.draw(vLabel, at: CGPoint(x: inset + 2, y: inset), anchor: .topLeading)
        }
    }
}

#Preview {
    NavigationStack { ResonanceExplainerView() }
}
