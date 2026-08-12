//
//  HVWidgets.swift — Live Activity und Status-Widget.
//
//  Das Widget-Target kompiliert nur diesen Ordner, LiveState.swift und
//  Palette.swift — hier darf nichts aus Core/ oder Views/ auftauchen.
//

import ActivityKit
import SwiftUI
import WidgetKit

// MARK: - Statusfarbe

private func statusColor(_ state: HVActivityAttributes.ContentState) -> Color {
    if state.tripLabel != nil { return Palette.danger }
    if !state.armed { return .gray }
    return state.arcBurning ? Palette.warn : Palette.ok
}

// MARK: - Sperrbildschirm

private struct LockScreenView: View {
    let context: ActivityViewContext<HVActivityAttributes>
    private var state: HVActivityAttributes.ContentState { context.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(state.wattsText)
                        .font(.system(.title, design: .rounded).weight(.bold))
                        .foregroundStyle(Palette.accentGradient)
                        .accessibilityLabel("Leistung \(state.wattsText)")
                    Text("\(state.voltsText) · \(state.ampsText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("\(state.voltsText), \(state.ampsText)")
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 2) {
                    Text(state.countdownText)
                        .font(.title3.monospacedDigit().weight(.semibold))
                        .accessibilityLabel("Countdown \(state.countdownText)")
                    HStack(spacing: 4) {
                        Circle()
                            .fill(statusColor(state))
                            .frame(width: 8, height: 8)
                        Text(context.attributes.modeLabel)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(state.statusText)
                }
            }
            if state.recentWatts.count > 1 {
                Sparkline(values: state.recentWatts)
                    .frame(height: 26)
                    .accessibilityHidden(true)
            }
            if let trip = state.tripLabel {
                Label("Abgeschaltet — \(trip)", systemImage: "bolt.slash.fill")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .accessibilityLabel("Abgeschaltet. Grund: \(trip)")
            }
        }
        .padding()
    }
}

// MARK: - Sparkline

/// Mini-Leistungskurve für Sperrbildschirm und StandBy. Bewusst ohne Charts-
/// Framework (im Widget schlank halten) — nur ein normierter Pfad.
private struct Sparkline: View {
    let values: [Double]

    var body: some View {
        GeometryReader { geo in
            let maxV = max(values.max() ?? 1, 1)
            let w = geo.size.width
            let h = geo.size.height
            let step = values.count > 1 ? w / CGFloat(values.count - 1) : w
            Path { p in
                for (i, v) in values.enumerated() {
                    let x = CGFloat(i) * step
                    let y = h - CGFloat(v / maxV) * h
                    if i == 0 { p.move(to: CGPoint(x: x, y: y)) }
                    else { p.addLine(to: CGPoint(x: x, y: y)) }
                }
            }
            .stroke(Palette.accentGradient,
                    style: StrokeStyle(lineWidth: 1.6, lineCap: .round, lineJoin: .round))
        }
    }
}

// MARK: - Live Activity

struct HVLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: HVActivityAttributes.self) { context in
            LockScreenView(context: context)
                .activityBackgroundTint(Palette.bg)
                .activitySystemActionForegroundColor(Palette.accent)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Text(context.state.wattsText)
                        .font(.title3.weight(.bold))
                        .foregroundStyle(Palette.accent)
                        .accessibilityLabel("Leistung \(context.state.wattsText)")
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Text(context.state.countdownText)
                        .font(.title3.monospacedDigit())
                        .accessibilityLabel("Countdown \(context.state.countdownText)")
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Label(context.state.statusText, systemImage: context.state.statusSymbol)
                        .font(.footnote)
                        .foregroundStyle(statusColor(context.state))
                }
            } compactLeading: {
                Image(systemName: context.state.statusSymbol)
                    .foregroundStyle(statusColor(context.state))
                    .accessibilityLabel(context.state.statusText)
            } compactTrailing: {
                Text(context.state.wattsText)
                    .font(.caption.monospacedDigit())
                    .accessibilityLabel("Leistung \(context.state.wattsText)")
            } minimal: {
                Circle()
                    .fill(statusColor(context.state))
                    .frame(width: 10, height: 10)
                    .accessibilityLabel(context.state.statusText)
            }
        }
    }
}

// MARK: - Statisches Widget

private struct StatusEntry: TimelineEntry {
    let date: Date
}

private struct StatusProvider: TimelineProvider {
    func placeholder(in context: Context) -> StatusEntry { StatusEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (StatusEntry) -> Void) {
        completion(StatusEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<StatusEntry>) -> Void) {
        completion(Timeline(entries: [StatusEntry(date: .now)], policy: .never))
    }
}

struct HVStatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HVStatusWidget", provider: StatusProvider()) { _ in
            VStack(spacing: 6) {
                Image(systemName: "bolt.fill")
                    .font(.title)
                    .foregroundStyle(Palette.accentGradient)
                Text("HV-Capture")
                    .font(.headline)
                Text("In der App öffnen")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .containerBackground(Palette.bg, for: .widget)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("HV-Capture. In der App öffnen.")
        }
        .configurationDisplayName("HV-Capture")
        .description("Öffnet die App.")
        .supportedFamilies([.systemSmall])
    }
}

// MARK: - Bundle

@main
struct HVWidgetBundle: WidgetBundle {
    var body: some Widget {
        HVLiveActivity()
        HVStatusWidget()
    }
}
