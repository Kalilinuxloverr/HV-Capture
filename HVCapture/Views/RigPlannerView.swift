//
//  RigPlannerView.swift — Aufbau-Planer: Konfiguration, Wiring-Diagramm,
//  Anleitung, Warnhinweise und ein rein erklärender Resonanz-Abschnitt.
//
//  Die App hilft beim kondensatorlosen Aufbau (Reihe/Parallel, EMI, Vorlast)
//  und zeichnet das passende Schaltbild. Der Resonanz-Teil erklärt nur, WAS
//  Resonanz mit Kondensatoren macht und warum sie gefährlich ist — er ist
//  bewusst keine Bauanleitung: ein geladener Kondensator bleibt tödlich, auch
//  wenn der Stecker längst gezogen ist.
//

import SwiftUI

struct RigPlannerView: View {
    @AppStorage("rigMotCount") private var motCount = 2
    @AppStorage("rigTopology") private var topologyKey = RigTopology.series.rawValue
    @AppStorage("rigEmiBoard") private var emiBoard = true
    @AppStorage("rigBallast") private var ballast = true

    private var plan: RigPlan {
        RigPlan(motCount: motCount,
                topology: RigTopology(rawValue: topologyKey) ?? .series,
                emiBoard: emiBoard,
                ballast: ballast)
    }

    var body: some View {
        List {
            configSection
            diagramSection
            keyValuesSection
            stepsSection
            cautionsSection

            Section {
                NavigationLink {
                    ResonanceExplainerView()
                } label: {
                    Label("Was ist Resonanz? (nur erklärt)", systemImage: "waveform.path.ecg")
                }
                .accessibilityLabel("Resonanz erklärt")
            } footer: {
                Text("Erklärt, was Kondensatoren im Schwingkreis bewirken — ohne Bauanleitung. Ein geladener Kondensator bleibt lebensgefährlich, auch nach dem Ausstecken.")
            }
        }
        .navigationTitle("Aufbau-Planer")
    }

    // MARK: Konfiguration

    private var configSection: some View {
        Section {
            Picker("Topologie", selection: $topologyKey) {
                ForEach(RigTopology.allCases) { t in
                    Text(t.label).tag(t.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .accessibilityLabel("Topologie")

            if plan.topology != .single {
                Stepper(value: $motCount, in: 2...16) {
                    HStack {
                        Text("Anzahl MOTs")
                        Spacer()
                        Text("\(motCount)")
                            .monospacedDigit()
                            .foregroundStyle(Palette.accent)
                    }
                }
                .accessibilityLabel("Anzahl MOTs")
                .accessibilityValue("\(motCount)")
            }

            Toggle("EMI-Filterplatine", isOn: $emiBoard)
                .accessibilityLabel("EMI-Filterplatine verwenden")
            Toggle("Vorschaltlast (Vorlast)", isOn: $ballast)
                .accessibilityLabel("Vorschaltlast verwenden")
        } header: {
            Text("Konfiguration")
        } footer: {
            Text(RigTopology(rawValue: topologyKey)?.effect ?? "")
        }
    }

    // MARK: Diagramm

    private var diagramSection: some View {
        Section("Schaltbild") {
            WiringDiagram(plan: plan)
                .frame(height: 260)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .listRowInsets(EdgeInsets())
                .accessibilityLabel(diagramDescription)
        }
    }

    private var diagramDescription: String {
        var parts = ["Netz"]
        if emiBoard { parts.append("EMI-Filter mit Sicherung") } else { parts.append("Sicherung") }
        parts.append("Messsteckdose")
        if ballast { parts.append("Vorlast") }
        parts.append("\(plan.effectiveCount) MOT in \(plan.topology.label)")
        return "Schaltbild: " + parts.joined(separator: ", dann ")
    }

    // MARK: Kennwerte

    private var keyValuesSection: some View {
        Section("Grössenordnung") {
            LabeledContent("Leerlaufspannung") {
                Text("~\(fmtKV(plan.openCircuitVolts))")
                    .monospacedDigit()
                    .foregroundStyle(Palette.accent)
            }
            LabeledContent("Primärleistung") {
                Text("~\(Int(plan.powerWatts)) W")
                    .monospacedDigit()
            }
            LabeledContent("Netzstrom (primär)") {
                Text("~\(String(format: "%.1f", plan.primaryAmps)) A")
                    .monospacedDigit()
                    .foregroundStyle(plan.primaryAmps > 13 ? Palette.warn : .primary)
            }
            if plan.secondaryAmpsFactor > 1 {
                LabeledContent("Sekundärstrom") {
                    Text("~\(plan.secondaryAmpsFactor)× einzeln")
                        .monospacedDigit()
                }
            }
        }
    }

    private func fmtKV(_ volts: Double) -> String {
        volts >= 1000 ? String(format: "%.0f kV", volts / 1000) : "\(Int(volts)) V"
    }

    // MARK: Anleitung

    private var stepsSection: some View {
        Section("Anleitung") {
            ForEach(Array(plan.steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 12) {
                    Text("\(i + 1)")
                        .font(.footnote.weight(.bold).monospacedDigit())
                        .foregroundStyle(Palette.accent)
                        .frame(width: 22, height: 22)
                        .background(Palette.accent.opacity(0.15), in: Circle())
                    Text(step)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Schritt \(i + 1): \(step)")
            }
        }
    }

    // MARK: Warnhinweise

    private var cautionsSection: some View {
        Section("Worauf achten") {
            ForEach(plan.cautions) { caution in
                Label {
                    Text(caution.text)
                        .font(.footnote)
                        .fixedSize(horizontal: false, vertical: true)
                } icon: {
                    Image(systemName: symbol(caution.level))
                        .foregroundStyle(color(caution.level))
                }
                .accessibilityLabel("\(levelWord(caution.level)): \(caution.text)")
            }
        }
    }

    private func symbol(_ l: RigPlan.Caution.Level) -> String {
        switch l {
        case .high: return "exclamationmark.octagon.fill"
        case .medium: return "exclamationmark.triangle.fill"
        case .low: return "info.circle.fill"
        }
    }

    private func color(_ l: RigPlan.Caution.Level) -> Color {
        switch l {
        case .high: return Palette.danger
        case .medium: return Palette.warn
        case .low: return .secondary
        }
    }

    private func levelWord(_ l: RigPlan.Caution.Level) -> String {
        switch l {
        case .high: return "Achtung"
        case .medium: return "Hinweis"
        case .low: return "Info"
        }
    }
}

// MARK: - Wiring-Diagramm

/// Zeichnet die Kette Netz → (EMI) → Sicherung → Messdose → (Vorlast) → MOTs
/// als Blockschaltbild. Alles per Canvas, keine externen Grafiken.
private struct WiringDiagram: View {
    let plan: RigPlan

    var body: some View {
        Canvas { ctx, size in
            let accent = GraphicsContext.Shading.color(Palette.accent)
            let line = GraphicsContext.Shading.color(.secondary)
            let danger = GraphicsContext.Shading.color(Palette.danger)

            // Blockkette oben.
            var blocks: [(String, GraphicsContext.Shading)] = [("Netz\n230 V", line)]
            blocks.append(plan.emiBoard ? ("EMI-\nFilter", accent) : ("Siche-\nrung", accent))
            blocks.append(("Mess-\ndose", accent))
            if plan.ballast { blocks.append(("Vor-\nlast", accent)) }

            let topY = size.height * 0.20
            let blockW = min(72.0, (size.width - 24) / Double(blocks.count + 1))
            let blockH = 46.0
            let gap = (size.width - 16 - blockW * Double(blocks.count)) / Double(max(1, blocks.count))

            var lastBlockRect = CGRect.zero
            for (i, block) in blocks.enumerated() {
                let x = 8 + gap / 2 + (blockW + gap) * Double(i)
                let rect = CGRect(x: x, y: topY, width: blockW, height: blockH)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 8), with: block.1, lineWidth: 1.6)
                drawText(ctx, block.0, at: CGPoint(x: rect.midX, y: rect.midY), size: 10)
                if i > 0 {
                    var wire = Path()
                    wire.move(to: CGPoint(x: lastBlockRect.maxX, y: lastBlockRect.midY))
                    wire.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
                    ctx.stroke(wire, with: line, lineWidth: 1.4)
                }
                lastBlockRect = rect
            }

            // Sammelknoten unter dem letzten Block → Primärschiene der MOTs.
            let busY = size.height * 0.55
            var down = Path()
            down.move(to: CGPoint(x: lastBlockRect.midX, y: lastBlockRect.maxY))
            down.addLine(to: CGPoint(x: lastBlockRect.midX, y: busY))
            ctx.stroke(down, with: line, lineWidth: 1.4)

            // MOTs zeichnen (maximal 6, Rest als Text).
            let count = min(plan.effectiveCount, 16)
            let motY = size.height * 0.66
            let motH = size.height * 0.24
            let shown = plan.topology == .single ? 1 : min(count, 6)
            let motW = min(40.0, (size.width - 24) / Double(max(1, shown)))
            let motGap = (size.width - 16 - motW * Double(shown)) / Double(max(1, shown))
            var motCenters: [CGPoint] = []

            for i in 0..<shown {
                let x = 8 + motGap / 2 + (motW + motGap) * Double(i)
                let rect = CGRect(x: x, y: motY, width: motW, height: motH)
                ctx.stroke(Path(roundedRect: rect, cornerRadius: 6), with: accent, lineWidth: 1.6)
                var coil = Path()
                coil.move(to: CGPoint(x: rect.midX, y: rect.minY + 6))
                coil.addLine(to: CGPoint(x: rect.midX, y: rect.maxY - 6))
                ctx.stroke(coil, with: accent, lineWidth: 1)
                drawText(ctx, "MOT", at: CGPoint(x: rect.midX, y: rect.maxY - 9), size: 8)
                motCenters.append(CGPoint(x: rect.midX, y: rect.minY))
            }

            // Primär-Sammelschiene: alle MOTs hängen parallel am Netz.
            var bus = Path()
            bus.move(to: CGPoint(x: 8, y: busY))
            bus.addLine(to: CGPoint(x: size.width - 8, y: busY))
            ctx.stroke(bus, with: line, lineWidth: 1.4)
            for c in motCenters {
                var drop = Path()
                drop.move(to: CGPoint(x: c.x, y: busY))
                drop.addLine(to: c)
                ctx.stroke(drop, with: line, lineWidth: 1.2)
            }

            // Sekundär-Kopplung je nach Topologie (Verbindung zwischen den MOTs).
            if plan.topology != .single, motCenters.count > 1 {
                let coupleY = motY + motH + 6
                let shading = plan.topology == .parallel ? danger : accent
                var couple = Path()
                couple.move(to: CGPoint(x: motCenters.first!.x, y: coupleY))
                couple.addLine(to: CGPoint(x: motCenters.last!.x, y: coupleY))
                ctx.stroke(couple, with: shading,
                           style: StrokeStyle(lineWidth: 1.6,
                                              dash: plan.topology == .parallel ? [4, 3] : []))
                let label = plan.topology == .series ? "Kerne verbunden = Reihe"
                                                     : "Ausgänge parallel — Phase sichern!"
                drawText(ctx, label, at: CGPoint(x: size.width / 2, y: coupleY + 10),
                         size: 9, shading: shading)
            }

            if count > shown {
                drawText(ctx, "+ \(count - shown) weitere",
                         at: CGPoint(x: size.width - 46, y: motY + motH / 2), size: 8)
            }
        }
    }

    private func drawText(_ ctx: GraphicsContext, _ string: String, at point: CGPoint,
                          size: CGFloat,
                          shading: GraphicsContext.Shading? = nil) {
        let text = Text(string).font(.system(size: size, weight: .semibold))
        var resolved = ctx.resolve(text)
        resolved.shading = shading ?? .color(.primary)
        ctx.draw(resolved, at: point, anchor: .center)
    }
}

#Preview {
    NavigationStack { RigPlannerView() }
}
