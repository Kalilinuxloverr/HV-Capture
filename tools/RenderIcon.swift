// RenderIcon.swift — erzeugt die App-Icons für HV-Capture.
//
// Motiv: die Jakobsleiter aus der Startanimation — zwei nach oben divergierende
// Elektroden, dazwischen ein wandernder Lichtbogen. Der Transformator aus der
// Animation fehlt bewusst: bei 60 px Kantenlänge wird aus zwei Motiven Matsch.
//
// Aufruf: swift RenderIcon.swift <zielordner>

import AppKit
import CoreGraphics
import Foundation

let size = 1024.0

// Farben aus HVCapture/Design/Palette.swift — Theme „karbon", Akzent „lichtbogen".
let karbonBG = (0.05, 0.05, 0.06)
let karbonCard = (0.10, 0.10, 0.12)
let arcNear = (0.78, 0.87, 1.00)
let arcFar = (0.42, 0.62, 1.00)

/// Deterministischer Zufall — dasselbe Icon bei jedem Lauf.
struct LCG {
    var state: UInt64
    mutating func next() -> Double {
        state = state &* 6364136223846793005 &+ 1442695040888963407
        return Double(state >> 11) / Double(UInt64(1) << 53)
    }
    mutating func symmetric(_ amount: Double) -> Double { (next() * 2 - 1) * amount }
}

/// Gezackter Entladungspfad zwischen zwei Punkten, mit seitlicher Auslenkung.
func arcPath(from a: CGPoint, to b: CGPoint, seed: UInt64, roughness: Double) -> CGPath {
    var rng = LCG(state: seed)
    let segments = 16
    let dx = b.x - a.x, dy = b.y - a.y
    let length = (dx * dx + dy * dy).squareRoot()
    // Einheitsnormale zur Verbindungslinie — dorthin wird ausgelenkt.
    let nx = -dy / length, ny = dx / length

    let path = CGMutablePath()
    path.move(to: a)
    for i in 1..<segments {
        let t = Double(i) / Double(segments)
        // In der Mitte am stärksten auslenken, an den Enden auf null.
        let taper = sin(t * .pi)
        let offset = rng.symmetric(roughness * length * 0.09) * taper
        path.addLine(to: CGPoint(x: a.x + dx * t + nx * offset,
                                 y: a.y + dy * t + ny * offset))
    }
    path.addLine(to: b)
    return path
}

/// Zeichnet den Bogen mehrlagig: breiter Schein aussen, heller Kern innen.
/// Das erzeugt den Glüheindruck ohne Bildfilter.
func drawArc(_ ctx: CGContext, path: CGPath, scale: Double, mono: Bool) {
    let layers: [(width: Double, alpha: Double, color: (Double, Double, Double))] = [
        (72, 0.14, arcFar),
        (44, 0.28, arcFar),
        (26, 0.55, arcNear),
        (14, 0.92, arcNear),
        (6, 1.00, (1.0, 1.0, 1.0)),
    ]
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    for layer in layers {
        let c = mono ? (1.0, 1.0, 1.0) : layer.color
        ctx.setStrokeColor(red: c.0, green: c.1, blue: c.2, alpha: layer.alpha)
        ctx.setLineWidth(layer.width * scale)
        ctx.addPath(path)
        ctx.strokePath()
    }
}

/// Eine Elektrode: kegelig zulaufender Stab.
func electrode(tip: CGPoint, base: CGPoint, halfWidth: Double) -> CGPath {
    let dx = tip.x - base.x, dy = tip.y - base.y
    let len = (dx * dx + dy * dy).squareRoot()
    let nx = -dy / len, ny = dx / len
    let p = CGMutablePath()
    p.move(to: CGPoint(x: base.x + nx * halfWidth, y: base.y + ny * halfWidth))
    p.addLine(to: CGPoint(x: tip.x + nx * halfWidth * 0.35, y: tip.y + ny * halfWidth * 0.35))
    p.addLine(to: CGPoint(x: tip.x - nx * halfWidth * 0.35, y: tip.y - ny * halfWidth * 0.35))
    p.addLine(to: CGPoint(x: base.x - nx * halfWidth, y: base.y - ny * halfWidth))
    p.closeSubpath()
    return p
}

func render(dark: Bool, mono: Bool, transparent: Bool) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    // App-Icons müssen deckend sein — ein Alphakanal führt beim Hochladen zur
    // Ablehnung. Nur die getönte Variante ist eine Maske und braucht ihn.
    let alpha = transparent
        ? CGImageAlphaInfo.premultipliedLast.rawValue
        : CGImageAlphaInfo.noneSkipLast.rawValue
    guard let ctx = CGContext(data: nil, width: Int(size), height: Int(size),
                              bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                              bitmapInfo: alpha)
    else { return nil }

    let s = size / 1024.0

    // --- Hintergrund -------------------------------------------------------
    if !transparent {
        let centre = dark ? karbonBG : karbonCard
        let edge = dark ? (0.02, 0.02, 0.03) : karbonBG
        if let gradient = CGGradient(colorsSpace: cs, colors: [
            CGColor(red: centre.0, green: centre.1, blue: centre.2, alpha: 1),
            CGColor(red: edge.0, green: edge.1, blue: edge.2, alpha: 1),
        ] as CFArray, locations: [0, 1]) {
            ctx.drawRadialGradient(gradient,
                                   startCenter: CGPoint(x: size / 2, y: size * 0.56),
                                   startRadius: 0,
                                   endCenter: CGPoint(x: size / 2, y: size * 0.5),
                                   endRadius: size * 0.75,
                                   options: [.drawsAfterEndLocation])
        }
    }

    // --- Elektroden --------------------------------------------------------
    // Fusspunkte eng, Spitzen weit auseinander: die Leiter, an der der Bogen
    // nach oben wandert und dabei länger wird.
    // Innerhalb der Sicherheitszone bleiben: iOS maskiert das Icon rund, was zu
    // nah an Ecke oder Rand sitzt, wird beschnitten.
    let baseY = size * 0.17
    let tipY = size * 0.83
    let baseGap = size * 0.045
    let tipGap = size * 0.26

    let left = electrode(tip: CGPoint(x: size / 2 - tipGap, y: tipY),
                         base: CGPoint(x: size / 2 - baseGap, y: baseY),
                         halfWidth: 40 * s)
    let right = electrode(tip: CGPoint(x: size / 2 + tipGap, y: tipY),
                          base: CGPoint(x: size / 2 + baseGap, y: baseY),
                          halfWidth: 40 * s)

    // Dunkles Metall: die Elektroden sind der Rahmen, nicht das Motiv. Hell
    // gefüllt lesen sie bei kleiner Darstellung als Buchstabe „V" und ziehen
    // den Blick vom Bogen weg.
    for rod in [left, right] {
        if mono {
            ctx.setFillColor(red: 1, green: 1, blue: 1, alpha: 0.38)
        } else {
            ctx.setFillColor(red: 0.30, green: 0.32, blue: 0.37, alpha: 1)
        }
        ctx.addPath(rod)
        ctx.fillPath()
        // Schmale Lichtkante innen — gibt den Stäben Rundung.
        ctx.addPath(rod)
        ctx.setStrokeColor(red: 0.55, green: 0.58, blue: 0.64, alpha: mono ? 0.25 : 0.7)
        ctx.setLineWidth(3 * s)
        ctx.strokePath()
    }

    // --- Bogen -------------------------------------------------------------
    // Sitzt auf etwa zwei Dritteln Höhe: schon gewandert, noch nicht abgerissen.
    let arcT = 0.70
    let y = baseY + (tipY - baseY) * arcT
    let halfSpan = baseGap + (tipGap - baseGap) * arcT
    let a = CGPoint(x: size / 2 - halfSpan, y: y)
    let b = CGPoint(x: size / 2 + halfSpan, y: y)

    ctx.saveGState()
    if !mono {
        ctx.setShadow(offset: .zero, blur: 90 * s,
                      color: CGColor(red: arcFar.0, green: arcFar.1, blue: arcFar.2, alpha: 0.85))
    }
    drawArc(ctx, path: arcPath(from: a, to: b, seed: 0x48564341, roughness: 1.0),
            scale: s, mono: mono)
    ctx.restoreGState()

    // Bewusst keine Verästelung: bei 60 px Kantenlänge liest sie als Kratzer,
    // nicht als Entladung.

    // --- Fusspunkt ---------------------------------------------------------
    // Heller Kern dort, wo die Entladung zündet.
    // Klein halten — ein grosser weicher Fleck erschlägt sonst das ganze Motiv.
    if !mono, let glow = CGGradient(colorsSpace: cs, colors: [
        CGColor(red: 1, green: 1, blue: 1, alpha: 0.85),
        CGColor(red: arcFar.0, green: arcFar.1, blue: arcFar.2, alpha: 0),
    ] as CFArray, locations: [0, 1]) {
        ctx.drawRadialGradient(glow,
                               startCenter: CGPoint(x: size / 2, y: baseY + size * 0.01),
                               startRadius: 0,
                               endCenter: CGPoint(x: size / 2, y: baseY + size * 0.01),
                               endRadius: size * 0.065,
                               options: [])
    }

    return ctx.makeImage()
}

// MARK: - Schreiben

let out = CommandLine.arguments.count > 1
    ? URL(fileURLWithPath: CommandLine.arguments[1])
    : URL(fileURLWithPath: ".")

func write(_ image: CGImage?, _ name: String) {
    guard let image else { print("Fehler: \(name) nicht gerendert"); exit(1) }
    let rep = NSBitmapImageRep(cgImage: image)
    guard let data = rep.representation(using: .png, properties: [:]) else {
        print("Fehler: \(name) nicht kodiert"); exit(1)
    }
    let url = out.appendingPathComponent(name)
    try? data.write(to: url)
    print("geschrieben: \(url.path)")
}

write(render(dark: false, mono: false, transparent: false), "icon-any.png")
write(render(dark: true, mono: false, transparent: false), "icon-dark.png")
write(render(dark: true, mono: true, transparent: true), "icon-tinted.png")
