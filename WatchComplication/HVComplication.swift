//
//  HVComplication.swift — Zifferblatt-Komplikation der Apple Watch.
//
//  Ein Schnellstart aufs Zifferblatt: ein Tipp öffnet die Watch-App mit dem
//  grossen Not-Aus-Knopf. Bewusst statisch (kein App-Group nötig) — die
//  Komplikation ist der schnelle Weg zum Aus-Knopf, die Live-Werte stehen in
//  der App selbst.
//
//  Eigenes Target mit eigenem @main — deshalb in einem separaten Ordner und
//  NICHT im Quellordner der Watch-App (die hat ihr eigenes @main).
//

import SwiftUI
import WidgetKit

private struct ComplicationEntry: TimelineEntry {
    let date: Date
}

private struct ComplicationProvider: TimelineProvider {
    func placeholder(in context: Context) -> ComplicationEntry { ComplicationEntry(date: .now) }

    func getSnapshot(in context: Context, completion: @escaping (ComplicationEntry) -> Void) {
        completion(ComplicationEntry(date: .now))
    }

    func getTimeline(in context: Context, completion: @escaping (Timeline<ComplicationEntry>) -> Void) {
        completion(Timeline(entries: [ComplicationEntry(date: .now)], policy: .never))
    }
}

private struct ComplicationView: View {
    @Environment(\.widgetFamily) private var family

    var body: some View {
        switch family {
        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                Image(systemName: "bolt.shield.fill")
                    .font(.title3)
            }
            .widgetLabel("HV-Capture")
        case .accessoryInline:
            Label("HV-Capture", systemImage: "bolt.shield.fill")
        case .accessoryCorner:
            Image(systemName: "bolt.shield.fill")
                .font(.title2)
                .widgetLabel("Not-Aus")
        default:
            Image(systemName: "bolt.shield.fill")
        }
    }
}

struct HVComplication: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "HVComplication", provider: ComplicationProvider()) { _ in
            ComplicationView()
        }
        .configurationDisplayName("HV-Capture")
        .description("Öffnet den Not-Aus am Handgelenk.")
        .supportedFamilies([.accessoryCircular, .accessoryInline, .accessoryCorner])
    }
}

@main
struct HVComplicationBundle: WidgetBundle {
    var body: some Widget {
        HVComplication()
    }
}
