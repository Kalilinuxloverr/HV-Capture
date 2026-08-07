// Palette.swift — HV-Capture
//
// Zentrale Farbwelt der App. Wird AUCH von der Widget-Extension kompiliert:
// deshalb nur SwiftUI/UIKit importieren und keine anderen Projekttypen anfassen.

import SwiftUI
import UIKit

enum Palette {

    // MARK: - Akzente

    /// Akzentpaare (Hauptfarbe + Partnerfarbe für Verläufe),
    /// benannt nach Lichterscheinungen der Hochspannungstechnik.
    static let accents: [(key: String, name: String, color: Color, partner: Color)] = [
        ("lichtbogen", "Lichtbogen",
         Color(red: 0.78, green: 0.87, blue: 1.00), Color(red: 0.42, green: 0.62, blue: 1.00)),
        ("xenon", "Xenon",
         Color(red: 0.30, green: 0.90, blue: 1.00), Color(red: 0.88, green: 0.99, blue: 1.00)),
        ("kupfer", "Kupfer",
         Color(red: 0.95, green: 0.55, blue: 0.25), Color(red: 1.00, green: 0.76, blue: 0.47)),
        ("natrium", "Natrium",
         Color(red: 1.00, green: 0.71, blue: 0.18), Color(red: 1.00, green: 0.88, blue: 0.45)),
        ("neon", "Neon",
         Color(red: 1.00, green: 0.36, blue: 0.24), Color(red: 1.00, green: 0.58, blue: 0.30)),
        ("quecksilber", "Quecksilber",
         Color(red: 0.62, green: 0.48, blue: 1.00), Color(red: 0.44, green: 0.72, blue: 1.00)),
    ]

    // MARK: - Hintergrundwelten

    /// Dunkle Hintergrund-Themes (Grundfläche + Kartenfläche).
    static let themes: [(key: String, name: String, bg: UIColor, card: UIColor)] = [
        ("karbon", "Karbon",
         UIColor(red: 0.05, green: 0.05, blue: 0.06, alpha: 1), UIColor(red: 0.10, green: 0.10, blue: 0.12, alpha: 1)),
        ("ozon", "Ozon",
         UIColor(red: 0.03, green: 0.05, blue: 0.09, alpha: 1), UIColor(red: 0.07, green: 0.10, blue: 0.16, alpha: 1)),
        ("plasma", "Plasma",
         UIColor(red: 0.06, green: 0.04, blue: 0.10, alpha: 1), UIColor(red: 0.11, green: 0.08, blue: 0.17, alpha: 1)),
        ("kupfer", "Kupfer",
         UIColor(red: 0.07, green: 0.05, blue: 0.04, alpha: 1), UIColor(red: 0.13, green: 0.09, blue: 0.07, alpha: 1)),
        ("rost", "Rost",
         UIColor(red: 0.08, green: 0.04, blue: 0.03, alpha: 1), UIColor(red: 0.14, green: 0.08, blue: 0.06, alpha: 1)),
        ("labor", "Labor",
         UIColor(red: 0.04, green: 0.06, blue: 0.05, alpha: 1), UIColor(red: 0.08, green: 0.11, blue: 0.10, alpha: 1)),
    ]

    // MARK: - Aktive Auswahl (aus UserDefaults)

    private static var currentAccent: (key: String, name: String, color: Color, partner: Color) {
        let key = UserDefaults.standard.string(forKey: "accentColor") ?? "lichtbogen"
        return accents.first { $0.key == key } ?? accents[0]
    }

    private static var currentTheme: (key: String, name: String, bg: UIColor, card: UIColor) {
        let key = UserDefaults.standard.string(forKey: "themeChoice") ?? "karbon"
        return themes.first { $0.key == key } ?? themes[0]
    }

    static var accent: Color { currentAccent.color }
    static var accent2: Color { currentAccent.partner }

    static var accentGradient: LinearGradient {
        LinearGradient(colors: [accent, accent2],
                       startPoint: .topLeading, endPoint: .bottomTrailing)
    }

    /// Die App ist dark-only; der helle Zweig existiert nur als Absicherung,
    /// falls das System (z. B. im Widget) doch einmal Light anfragt.
    static var bg: Color {
        let theme = currentTheme
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor(red: 0.93, green: 0.94, blue: 0.96, alpha: 1)
                : theme.bg
        })
    }

    static var card: Color {
        let theme = currentTheme
        return Color(UIColor { traits in
            traits.userInterfaceStyle == .light
                ? UIColor.white
                : theme.card
        })
    }

    // MARK: - Statusfarben

    static let danger = Color(red: 1.00, green: 0.28, blue: 0.25)
    static let warn   = Color(red: 1.00, green: 0.70, blue: 0.20)
    static let ok     = Color(red: 0.30, green: 0.85, blue: 0.45)

    // MARK: - Weißglut

    /// Mischt den Akzent abhängig von der Last Richtung Weißglut:
    /// untere Hälfte Akzent → Amber, obere Hälfte Amber → fast Weiß.
    static func hot(_ level: Double) -> Color {
        let l = min(max(level, 0), 1)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(accent).getRed(&r, green: &g, blue: &b, alpha: &a)

        let base  = (Double(r), Double(g), Double(b))
        let amber = (1.00, 0.72, 0.30)
        let white = (1.00, 0.96, 0.90)

        return l < 0.5
            ? mix(base, amber, l * 2)
            : mix(amber, white, (l - 0.5) * 2)
    }

    /// Lineare RGB-Interpolation zwischen zwei Farben (t: 0…1).
    private static func mix(_ a: (Double, Double, Double),
                            _ b: (Double, Double, Double),
                            _ t: Double) -> Color {
        Color(red:   a.0 + (b.0 - a.0) * t,
              green: a.1 + (b.1 - a.1) * t,
              blue:  a.2 + (b.2 - a.2) * t)
    }
}
