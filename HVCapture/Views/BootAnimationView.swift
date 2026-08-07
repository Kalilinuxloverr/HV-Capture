// BootAnimationView.swift — HV-Capture
//
// Startanimation: Ein Transformator baut sich auf, speist eine Jakobsleiter,
// die Entladung wandert nach oben und reisst ab — dann blitzt der Schriftzug.
// Reines SwiftUI (Canvas + TimelineView), keine Bilder, keine Pakete.

import SwiftUI

// MARK: - Schalter

enum BootAnimation {
    /// UserDefaults-Bool "bootAnimationEnabled", Standard: an.
    static var isEnabled: Bool {
        UserDefaults.standard.object(forKey: "bootAnimationEnabled") as? Bool ?? true
    }
}

// MARK: - Phasengrenzen (Sekunden)

private enum Phase {
    static let coreEnd: Double     = 0.5   // Kern zeichnet sich
    static let windingStart        = 0.4   // Wicklungen laufen ein
    static let windingEnd          = 1.0
    static let wireStart           = 0.9   // Leitungen zu den Stäben
    static let wireEnd             = 1.2
    static let igniteStart         = 1.2   // Zündung am engsten Spalt
    static let igniteEnd           = 1.4
    static let climbStart          = 1.4   // Entladung wandert nach oben
    static let climbEnd            = 2.2
    static let flashStart          = 2.2   // Abriss + Schriftzug
    static let flashEnd            = 2.4
    static let total               = 2.6
}

// MARK: - Deterministischer Pseudo-Zufall

/// Kleiner linearer Kongruenzgenerator — pro Seed reproduzierbar,
/// damit ein einzelner Frame beim Neuzeichnen stabil bleibt.
private struct LCG {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed &* 2_862_933_555_777_941_757 &+ 3_037_000_493
    }

    /// Gleichverteilt in [0, 1).
    mutating func next() -> Double {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return Double(state >> 11) / Double(1 << 53)
    }

    /// Gleichverteilt in [-1, 1).
    mutating func symmetric() -> Double { next() * 2 - 1 }
}

// MARK: - Kleine Helfer

private func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    min(max((t - a) / (b - a), 0), 1)
}

private func lerp(_ a: CGPoint, _ b: CGPoint, _ t: Double) -> CGPoint {
    CGPoint(x: Double(a.x) + Double(b.x - a.x) * t,
            y: Double(a.y) + Double(b.y - a.y) * t)
}

/// Zackiger Entladungspfad zwischen zwei Punkten. Zwischenpunkte werden
/// senkrecht zur Verbindungslinie ausgelenkt; ein bis zwei kurze
/// Verästelungen zweigen vom Hauptpfad ab.
private func arcPath(from a: CGPoint, to b: CGPoint, seed: UInt64, roughness: Double) -> Path {
    var rng = LCG(seed: seed)
    let segments = 14

    let ax = Double(a.x), ay = Double(a.y)
    let dx = Double(b.x - a.x), dy = Double(b.y - a.y)
    let len = max((dx * dx + dy * dy).squareRoot(), 0.001)
    let nx = -dy / len, ny = dx / len   // Einheitsnormale

    var xs = [ax], ys = [ay]
    for i in 1..<segments {
        let t = Double(i) / Double(segments)
        // Enden bleiben fest, Mitte lenkt am stärksten aus.
        let amp = roughness * len * 0.06 * sin(Double.pi * t)
        let off = rng.symmetric() * amp
        xs.append(ax + dx * t + nx * off)
        ys.append(ay + dy * t + ny * off)
    }
    xs.append(Double(b.x)); ys.append(Double(b.y))

    var path = Path()
    path.move(to: CGPoint(x: xs[0], y: ys[0]))
    for i in 1...segments {
        path.addLine(to: CGPoint(x: xs[i], y: ys[i]))
    }

    // Verästelungen
    let dirAngle = atan2(dy, dx)
    let branches = rng.next() < 0.5 ? 1 : 2
    for _ in 0..<branches {
        let idx = 3 + Int(rng.next() * Double(segments - 6))
        let px = xs[idx], py = ys[idx]
        let side: Double = rng.next() < 0.5 ? 1 : -1
        let ang = dirAngle + side * (0.7 + rng.next() * 0.6)
        let blen = len * (0.07 + rng.next() * 0.09)
        let kink = rng.symmetric() * blen * 0.35
        path.move(to: CGPoint(x: px, y: py))
        path.addLine(to: CGPoint(x: px + cos(ang) * blen * 0.5 + nx * kink,
                                 y: py + sin(ang) * blen * 0.5 + ny * kink))
        path.addLine(to: CGPoint(x: px + cos(ang) * blen,
                                 y: py + sin(ang) * blen))
    }
    return path
}

// MARK: - View

struct BootAnimationView: View {
    let onFinish: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var start = Date()
    /// Einmal pro Erscheinen gezogen — jeder App-Start flackert leicht anders.
    @State private var baseSeed = UInt64.random(in: 1...UInt64.max)
    @State private var finished = false

    var body: some View {
        if reduceMotion {
            staticScene
        } else {
            animatedScene
        }
    }

    // MARK: Animierter Ablauf

    private var animatedScene: some View {
        TimelineView(.animation) { timeline in
            let elapsed = min(timeline.date.timeIntervalSince(start), Phase.total)
            let textIn = ramp(elapsed, Phase.flashStart, Phase.flashStart + 0.1)
            let flash = textIn == 0 ? 0 : max(0, 1 - ramp(elapsed, Phase.flashStart, Phase.flashEnd))

            ZStack {
                Palette.bg.ignoresSafeArea()
                Canvas { ctx, size in
                    drawScene(ctx, size: size, t: elapsed, seed: baseSeed)
                }
                .accessibilityHidden(true)

                VStack(spacing: 28) {
                    Spacer()
                    title(opacity: textIn, flash: flash)
                    Text("Tippen zum Überspringen")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .opacity(ramp(elapsed, 0.8, 1.1) * (1 - textIn))
                }
                .padding(.bottom, 48)
                .accessibilityHidden(true)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Startanimation überspringen")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish() }
        .task {
            try? await Task.sleep(for: .seconds(Phase.total + 0.05))
            finish()
        }
        .onAppear { start = Date() }
    }

    // MARK: Standbild bei Bewegungsreduktion

    private var staticScene: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            Canvas { ctx, size in
                drawScene(ctx, size: size, t: 2.0, seed: baseSeed)
            }
            .accessibilityHidden(true)

            VStack {
                Spacer()
                title(opacity: 1, flash: 0)
            }
            .padding(.bottom, 48)
            .accessibilityHidden(true)
        }
        .contentShape(Rectangle())
        .onTapGesture { finish() }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Startanimation überspringen")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { finish() }
        .task {
            try? await Task.sleep(for: .seconds(0.4))
            finish()
        }
    }

    private func title(opacity: Double, flash: Double) -> some View {
        Text("HV-CAPTURE")
            .font(.system(size: 28, weight: .heavy, design: .monospaced))
            .tracking(7)
            .foregroundStyle(Palette.accent)
            .brightness(0.55 * flash)
            .shadow(color: Palette.accent.opacity(0.9), radius: CGFloat(3 + 24 * flash))
            .opacity(opacity)
    }

    private func finish() {
        guard !finished else { return }
        finished = true
        onFinish()
    }

    // MARK: Zeichnung

    private func drawScene(_ ctx: GraphicsContext, size: CGSize, t: Double, seed: UInt64) {
        let w = size.width, h = size.height

        // Geometrie: Trafo links, Jakobsleiter rechts.
        let outer = CGRect(x: 0.14 * w, y: 0.44 * h, width: 0.22 * w, height: 0.28 * h)
        let inner = outer.insetBy(dx: 0.045 * w, dy: 0.06 * h)
        let footL = CGPoint(x: 0.615 * w, y: 0.74 * h)
        let footR = CGPoint(x: 0.685 * w, y: 0.74 * h)
        let topL  = CGPoint(x: 0.53 * w, y: 0.30 * h)
        let topR  = CGPoint(x: 0.77 * w, y: 0.30 * h)
        let metal = Color(white: 0.62)

        // Phase 1: laminierter Kern, progressiv nachgezogen.
        let coreP = ramp(t, 0, Phase.coreEnd)
        if coreP > 0 {
            let laminations: [CGFloat] = [0, 0.35, 0.7, 1]
            for (i, f) in laminations.enumerated() {
                let r = CGRect(x: outer.minX + (inner.minX - outer.minX) * f,
                               y: outer.minY + (inner.minY - outer.minY) * f,
                               width: outer.width + (inner.width - outer.width) * f,
                               height: outer.height + (inner.height - outer.height) * f)
                let local = min(max(coreP * 1.3 - Double(i) * 0.1, 0), 1)
                guard local > 0 else { continue }
                let edge = i == 0 || i == laminations.count - 1
                ctx.stroke(Path(r).trimmedPath(from: 0, to: local),
                           with: .color(metal.opacity(edge ? 0.9 : 0.35)),
                           lineWidth: edge ? 2 : 1)
            }
        }

        // Phase 2: Wicklungen — links wenige dicke, rechts viele feine.
        let windP = ramp(t, Phase.windingStart, Phase.windingEnd)
        if windP > 0 {
            drawWindings(ctx, centerX: (outer.minX + inner.minX) / 2,
                         bandWidth: inner.minX - outer.minX,
                         yTop: inner.minY, yBottom: inner.maxY,
                         turns: 5, progress: windP,
                         color: Palette.accent, lineWidth: 3)
            drawWindings(ctx, centerX: (outer.maxX + inner.maxX) / 2,
                         bandWidth: inner.minX - outer.minX,
                         yTop: inner.minY, yBottom: inner.maxY,
                         turns: 12, progress: windP,
                         color: Palette.accent2, lineWidth: 1.2)
        }

        // Phase 3: Leitungen zu den Fusspunkten, Stäbe wachsen nach oben.
        let wireP = ramp(t, Phase.wireStart, Phase.wireEnd)
        if wireP > 0 {
            var wire1 = Path()
            wire1.move(to: CGPoint(x: outer.maxX, y: inner.minY))
            wire1.addLine(to: CGPoint(x: footL.x, y: inner.minY))
            wire1.addLine(to: footL)
            var wire2 = Path()
            wire2.move(to: CGPoint(x: outer.maxX, y: inner.maxY))
            wire2.addLine(to: CGPoint(x: footR.x, y: inner.maxY))
            wire2.addLine(to: footR)
            let style = StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round)
            ctx.stroke(wire1.trimmedPath(from: 0, to: wireP),
                       with: .color(Palette.accent.opacity(0.85)), style: style)
            ctx.stroke(wire2.trimmedPath(from: 0, to: wireP),
                       with: .color(Palette.accent2.opacity(0.85)), style: style)
        }

        let rodP = ramp(t, Phase.wireStart, Phase.igniteStart)
        if rodP > 0 {
            for (foot, top) in [(footL, topL), (footR, topR)] {
                var rod = Path()
                rod.move(to: foot)
                rod.addLine(to: top)
                ctx.stroke(rod.trimmedPath(from: 0, to: rodP),
                           with: .color(metal),
                           style: StrokeStyle(lineWidth: 3, lineCap: .round))
            }
        }

        // Phasen 4–6: Zündung, Aufstieg, Abriss.
        let tearP = ramp(t, Phase.flashStart, Phase.flashStart + 0.08)
        let arcAlpha = ramp(t, Phase.igniteStart, Phase.igniteStart + 0.08) * (1 - tearP)
        if arcAlpha > 0 {
            let climbP = ramp(t, Phase.climbStart, Phase.climbEnd)
            let u = climbP * climbP * (3 - 2 * climbP)   // Smoothstep
            let a = lerp(footL, topL, 0.02 + 0.96 * u)
            let b = lerp(footR, topR, 0.02 + 0.96 * u)

            // Seed wechselt ~30×/s → Flackern, innerhalb eines Frames stabil.
            let frameSeed = seed &+ UInt64((t * 30).rounded(.down)) &* 7919
            let arc = arcPath(from: a, to: b, seed: frameSeed, roughness: 0.35 + 1.15 * u)

            let heightFade = 1 - 0.45 * u   // Schein nimmt mit der Höhe ab
            let ignitePulse = t < Phase.igniteEnd
                ? 1.0 + 0.8 * sin(Double.pi * ramp(t, Phase.igniteStart, Phase.igniteEnd))
                : 1.0
            let glowA = arcAlpha * heightFade * ignitePulse

            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            glow(ctx, at: mid,
                 radius: CGFloat((26 - 12 * u) * ignitePulse),
                 intensity: arcAlpha * heightFade)

            // Drei Lagen: weicher Aussenschein, Mittellage, fast weisser Kern.
            ctx.stroke(arc, with: .color(Palette.accent.opacity(0.22 * glowA)),
                       style: StrokeStyle(lineWidth: CGFloat(9 - 4 * u), lineCap: .round, lineJoin: .round))
            ctx.stroke(arc, with: .color(Palette.hot(0.55).opacity(0.8 * glowA)),
                       style: StrokeStyle(lineWidth: CGFloat(3.4 - 1.6 * u), lineCap: .round, lineJoin: .round))
            ctx.stroke(arc, with: .color(Palette.hot(0.97).opacity(min(1.0, arcAlpha * 1.2))),
                       style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
        }
    }

    /// Windungen als gestapelte Ellipsen um einen Kernschenkel; sie
    /// erscheinen nacheinander mit dem Fortschritt.
    private func drawWindings(_ ctx: GraphicsContext, centerX: CGFloat, bandWidth: CGFloat,
                              yTop: CGFloat, yBottom: CGFloat, turns: Int, progress: Double,
                              color: Color, lineWidth: CGFloat) {
        let shown = min(Int((Double(turns) * progress).rounded(.down)), turns)
        guard shown > 0 else { return }
        let step = (yBottom - yTop) / CGFloat(turns)
        let width = bandWidth * 1.9
        for i in 0..<shown {
            let y = yTop + step * (CGFloat(i) + 0.5)
            let rect = CGRect(x: centerX - width / 2, y: y - step * 0.38,
                              width: width, height: step * 0.76)
            ctx.stroke(Path(ellipseIn: rect), with: .color(color), lineWidth: lineWidth)
        }
    }

    /// Leuchtpunkt aus drei konzentrischen Scheiben — Schein ohne Bildfilter.
    private func glow(_ ctx: GraphicsContext, at p: CGPoint, radius: CGFloat, intensity: Double) {
        guard radius > 1, intensity > 0.01 else { return }
        let layers: [(CGFloat, Color)] = [
            (1.0, Palette.accent.opacity(0.16 * intensity)),
            (0.45, Palette.hot(0.6).opacity(0.35 * intensity)),
            (0.16, Palette.hot(1.0).opacity(0.9 * intensity)),
        ]
        for (f, color) in layers {
            let r = radius * f
            ctx.fill(Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r)),
                     with: .color(color))
        }
    }
}

#Preview {
    BootAnimationView(onFinish: {})
}
