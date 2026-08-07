// Components.swift — HV-Capture
//
// Wiederverwendbare UI-Bausteine: Haptik, Live-Theme und die Kernkomponenten
// für Leistungsanzeige und Steuerung der Smart-Steckdose.

import SwiftUI
import UIKit
import Observation

// MARK: - Haptik

/// Zentrale Haptik-Auslösung; respektiert die Nutzereinstellung "hapticsEnabled".
enum Haptics {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "hapticsEnabled") as? Bool ?? true
    }

    static func tap() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    static func light() {
        guard enabled else { return }
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }

    static func success() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    static func error() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.error)
    }

    static func warning() {
        guard enabled else { return }
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
}

// MARK: - Live-Theme

/// Reaktives Theme, das die aktuelle Wirkleistung der Steckdose in einen
/// Glüh-Faktor (0…1) übersetzt. Die exponentielle Glättung verhindert,
/// dass die UI bei jedem Messwertsprung der Steckdose flackert.
@MainActor
@Observable
final class LiveTheme {
    static let shared = LiveTheme()

    /// Geglätteter Lastpegel 0…1.
    private(set) var level: Double = 0

    private init() {}

    /// Neuen Messwert einspeisen; `nil` (keine Verbindung) fährt gegen 0.
    func feed(watts: Double?) {
        let stored = UserDefaults.standard.object(forKey: "liveThemeMaxWatts") as? Double ?? 2000
        let maxWatts = max(stored, 100) // Absicherung gegen Fehlkonfiguration
        let target = min(max((watts ?? 0) / maxWatts, 0), 1)
        level += (target - level) * 0.25
    }

    /// Glüh-Akzent, wenn das Live-Theme aktiv ist, sonst der statische Akzent.
    var accent: Color {
        let enabled = UserDefaults.standard.object(forKey: "liveThemeEnabled") as? Bool ?? true
        return enabled ? Palette.hot(level) : Palette.accent
    }

    var glowRadius: CGFloat { CGFloat(level) * 28 }

    func reset() { level = 0 }
}

// MARK: - View-Bausteine

extension View {
    /// Standard-Karte: dunkle Fläche mit dezentem Akzentrand.
    func card() -> some View {
        self
            .padding(16)
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .strokeBorder(
                        LinearGradient(colors: [Palette.accent.opacity(0.25),
                                                Palette.accent2.opacity(0.08)],
                                       startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 1)
            )
            .shadow(color: .black.opacity(0.35), radius: 8, y: 4)
    }

    /// App-Hintergrund mit sehr dezenter radialer Akzent-Aufhellung oben.
    func appBackground() -> some View {
        self.background {
            ZStack {
                Palette.bg
                RadialGradient(colors: [Palette.accent.opacity(0.08), .clear],
                               center: .top, startRadius: 0, endRadius: 420)
            }
            .ignoresSafeArea()
        }
    }

    /// Mehrstufiger Schatten-Stack für den Lichtbogen-Look.
    func glow(_ radius: CGFloat, color: Color) -> some View {
        self
            .shadow(color: color.opacity(0.8), radius: radius * 0.35)
            .shadow(color: color.opacity(0.5), radius: radius)
            .shadow(color: color.opacity(0.25), radius: radius * 2)
    }
}

// MARK: - StatTile

/// Kompakte Messwertkachel für V/A/W-Anzeigen.
struct StatTile: View {
    let title: String
    let value: String
    var unit: String? = nil
    let symbol: String
    var tint: Color? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text(value)
                    .font(.title2.weight(.semibold).monospacedDigit())
                    .foregroundStyle(tint ?? .primary)
                    .contentTransition(.numericText())
                if let unit {
                    Text(unit)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(unit.map { "\(value) \($0)" } ?? value)
    }
}

// MARK: - BigActionButton

/// Großer runder Aktionsknopf für EIN/AUS und Not-Aus.
struct BigActionButton: View {
    let title: String
    let symbol: String
    let tint: Color
    var isEnabled: Bool = true
    let action: () -> Void

    var body: some View {
        Button {
            Haptics.tap()
            action()
        } label: {
            VStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(tint.opacity(isEnabled ? 0.18 : 0.06))
                    Circle()
                        .strokeBorder(tint.opacity(isEnabled ? 0.7 : 0.25), lineWidth: 2)
                    Image(systemName: symbol)
                        .font(.title2.weight(.bold))
                        .foregroundStyle(isEnabled ? tint : .secondary)
                }
                .frame(width: 72, height: 72) // über der 64-pt-Mindestgröße
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isEnabled ? .primary : .secondary)
            }
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(title)
        .accessibilityHint(isEnabled ? "" : "Derzeit nicht verfügbar")
    }
}

// MARK: - ArcMeter

/// Runde Leistungsanzeige: 270°-Bogen von 0 bis maxWatts, Wattwert in der Mitte.
/// Bei fehlender Verbindung (`watts == nil`) gedämpfter Ring und „—".
struct ArcMeter: View {
    var watts: Double?
    var maxWatts: Double
    var tripping: Bool = false

    private var fraction: Double {
        guard let watts, maxWatts > 0 else { return 0 }
        return min(max(watts / maxWatts, 0), 1)
    }

    private var ringColor: Color {
        if tripping { return Palette.danger }
        if watts == nil { return Color.secondary.opacity(0.4) }
        return LiveTheme.shared.accent
    }

    var body: some View {
        ZStack {
            // Bogen um 135° gedreht, damit die Lücke unten liegt.
            Group {
                Circle()
                    .trim(from: 0, to: 0.75)
                    .stroke(Color.white.opacity(0.08),
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                Circle()
                    .trim(from: 0, to: 0.75 * fraction)
                    .stroke(ringColor,
                            style: StrokeStyle(lineWidth: 14, lineCap: .round))
                    .glow(watts == nil ? 0 : LiveTheme.shared.glowRadius, color: ringColor)
            }
            .rotationEffect(.degrees(135))
            .animation(.easeOut(duration: 0.3), value: fraction)

            VStack(spacing: 2) {
                Text(watts.map { "\(Int($0.rounded()))" } ?? "—")
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .contentTransition(.numericText())
                Text("Watt")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if tripping {
                    // Textliche Kennzeichnung, nicht nur die rote Färbung.
                    Label("Auslösung", systemImage: "bolt.trianglebadge.exclamationmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Palette.danger)
                }
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .padding(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Leistung")
        .accessibilityValue(accessibilityText)
    }

    private var accessibilityText: String {
        guard let watts else { return "Keine Messwerte" }
        let base = "\(Int(watts.rounded())) von maximal \(Int(maxWatts)) Watt"
        return tripping ? base + ", Sicherung ausgelöst" : base
    }
}

// MARK: - WarningBanner

/// Banner in voller Breite für Trip- und Verbindungswarnungen.
struct WarningBanner: View {
    let text: String
    let symbol: String
    let tint: Color

    var body: some View {
        Label(text, systemImage: symbol)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(tint.opacity(0.12),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(tint.opacity(0.35), lineWidth: 1)
            )
            .accessibilityElement(children: .combine)
    }
}
