// SessionsView.swift — HV-Capture
//
// Historie: Rekorde, Elektrodenverschleiss und alle abgeschlossenen Sessions.
// Detailansicht mit Leistungskurve, Bogen-Bändern und Trip-Protokoll;
// Vergleichsansicht legt zwei Sessions auf ein gemeinsames Zeitraster.

import SwiftUI
import Charts

// MARK: - Format-Hilfen

/// Sekunden als „m:ss".
private func mmss(_ seconds: Double) -> String {
    let total = Int(seconds.rounded())
    return String(format: "%d:%02d", total / 60, total % 60)
}

/// Eine Nachkommastelle, regionsgerecht formatiert.
private func dec1(_ value: Double) -> String {
    value.formatted(.number.precision(.fractionLength(1)))
}

private func arcText(_ n: Int) -> String { n == 1 ? "1 Bogen" : "\(n) Bögen" }

// MARK: - Übersicht

struct SessionsView: View {
    @State private var store = SessionStore.shared

    @State private var compareMode = false
    @State private var selection: [Session] = []
    @State private var comparePair: ComparePair?

    struct ComparePair: Identifiable {
        let a: Session
        let b: Session
        var id: String { a.id.uuidString + b.id.uuidString }
    }

    var body: some View {
        NavigationStack {
            Group {
                if store.sessions.isEmpty {
                    ContentUnavailableView {
                        Label("Noch keine Sessions", systemImage: "bolt.slash")
                    } description: {
                        Text("Starte eine Messfahrt — abgeschlossene Sessions samt Rekorden und Elektrodenverschleiss erscheinen hier.")
                    }
                } else {
                    sessionList
                }
            }
            .appBackground()
            .navigationTitle("Sessions")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button(compareMode ? "Fertig" : "Vergleichen") {
                        Haptics.light()
                        compareMode.toggle()
                        selection.removeAll()
                    }
                    .disabled(!compareMode && store.sessions.count < 2)
                    .accessibilityLabel(compareMode ? "Vergleich beenden" : "Zwei Sessions vergleichen")
                }
            }
            .sheet(item: $comparePair) { pair in
                NavigationStack { SessionCompareView(a: pair.a, b: pair.b) }
            }
        }
        .onAppear { store.load() }
    }

    private var sessionList: some View {
        List {
            Section("Rekorde") {
                recordsGrid
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
            }

            Section {
                NavigationLink {
                    EnergyCostView()
                } label: {
                    Label("Energie & Kosten", systemImage: "eurosign.circle")
                }
                .listRowBackground(Palette.card)
                .accessibilityLabel("Energie und Kosten")
            }

            if !store.electrodeWear.isEmpty {
                Section("Elektroden") {
                    ForEach(store.electrodeWear) { wear in
                        electrodeRow(wear)
                            .listRowBackground(Palette.card)
                    }
                }
            }

            Section(compareMode ? "Zwei Sessions zum Vergleich antippen" : "Sessions") {
                ForEach(store.sessions) { session in
                    sessionRow(session)
                        .listRowBackground(Palette.card)
                }
                .onDelete { offsets in
                    let doomed = offsets.map { store.sessions[$0] }
                    for s in doomed { store.delete(s) }
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    private var recordsGrid: some View {
        let r = store.records
        return LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Längster Bogen", value: dec1(r.longestArc), unit: "s",
                     symbol: "bolt")
            StatTile(title: "Spitzenleistung", value: "\(Int(r.peakWatts.rounded()))", unit: "W",
                     symbol: "gauge.with.dots.needle.100percent")
            StatTile(title: "Spitzenstrom", value: dec1(r.peakAmps), unit: "A",
                     symbol: "waveform.path.ecg")
            StatTile(title: "Meiste Bögen", value: "\(r.mostArcsInSession)",
                     symbol: "flame")
            StatTile(title: "Gesamt-Bogenzeit", value: mmss(r.totalArcSeconds),
                     symbol: "clock")
            StatTile(title: "Gesamtenergie", value: dec1(r.totalWattHours), unit: "Wh",
                     symbol: "battery.100percent.bolt")
            StatTile(title: "Sessions", value: "\(r.sessionCount)",
                     symbol: "tray.full")
        }
        .padding(.vertical, 4)
    }

    private func electrodeRow(_ wear: ElectrodeWear) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(wear.name)
                    .font(.subheadline.weight(.semibold))
                Text("\(mmss(wear.arcSeconds)) Bogenzeit · \(wear.sessions) Sessions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if let last = wear.lastUsed {
                Text(last.formatted(.relative(presentation: .named)))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func sessionRow(_ session: Session) -> some View {
        if compareMode {
            Button {
                Haptics.light()
                toggleSelection(session)
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: isSelected(session) ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected(session) ? Palette.accent : .secondary)
                    SessionRowLabel(session: session)
                }
            }
            .accessibilityLabel("Session vom \(session.started.formatted(date: .abbreviated, time: .shortened)) für den Vergleich auswählen")
        } else {
            NavigationLink {
                SessionDetailView(session: session)
            } label: {
                SessionRowLabel(session: session)
            }
        }
    }

    private func isSelected(_ session: Session) -> Bool {
        selection.contains { $0.id == session.id }
    }

    private func toggleSelection(_ session: Session) {
        if let i = selection.firstIndex(where: { $0.id == session.id }) {
            selection.remove(at: i)
        } else {
            selection.append(session)
            if selection.count == 2 {
                comparePair = ComparePair(a: selection[0], b: selection[1])
                selection.removeAll()
                compareMode = false
            }
        }
    }
}

/// Eine Session-Zeile: Datum, Dauer, Bögen, Spitzenleistung, Trip-Hinweis.
private struct SessionRowLabel: View {
    let session: Session

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(session.started.formatted(date: .abbreviated, time: .shortened))
                    .font(.subheadline.weight(.semibold))
                // ponytail: peakWatts läuft über alle Samples — falls die Liste bei
                // sehr vielen langen Sessions ruckelt, Kennzahlen im Store cachen.
                Text("\(mmss(session.duration)) · \(arcText(session.arcCount)) · max. \(Int((session.peakWatts ?? 0).rounded())) W")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if !session.trips.isEmpty {
                Image(systemName: "bolt.trianglebadge.exclamationmark")
                    .foregroundStyle(Palette.warn)
                    .accessibilityLabel("Enthält Abschaltungen")
            }
        }
    }
}

// MARK: - Detail

struct SessionDetailView: View {
    @State private var store = SessionStore.shared
    @State private var session: Session
    /// Stand auf der Platte — gespeichert wird nur bei echter Änderung,
    /// die Session-Datei kann durch die Messreihe gross sein.
    @State private var saved: Session

    @State private var csvURL: URL?
    @State private var bundleURL: URL?
    @State private var exportError: String?

    /// Einmal beim Öffnen berechnet — die Samples ändern sich hier nicht mehr,
    /// und beides in body neu zu rechnen würde jeden Tastendruck teuer machen.
    private let plotSamples: [Sample]
    private let energyWh: Double

    init(session: Session) {
        _session = State(initialValue: session)
        _saved = State(initialValue: session)
        plotSamples = Self.thinned(session.samples)
        energyWh = session.wattHours
    }

    /// Auf ~2000 Punkte ausdünnen (jeden n-ten nehmen): mit zehntausenden
    /// Punkten wird das Diagramm bei langen Sessions zäh, optisch ändert
    /// die Ausdünnung nichts.
    private static func thinned(_ samples: [Sample], target: Int = 2000) -> [Sample] {
        guard samples.count > target else { return samples }
        let n = (samples.count + target - 1) / target
        return stride(from: 0, to: samples.count, by: n).map { samples[$0] }
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                headerCard
                statsGrid
                powerCard
                if !session.trips.isEmpty {
                    tripsCard
                }
            }
            .padding()
        }
        .appBackground()
        .navigationTitle(session.started.formatted(date: .abbreviated, time: .shortened))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    if let csvURL {
                        ShareLink(item: csvURL) { Label("CSV", systemImage: "tablecells") }
                    }
                    if let bundleURL {
                        ShareLink(item: bundleURL) { Label("Paket", systemImage: "folder") }
                    }
                } label: {
                    Image(systemName: "square.and.arrow.up")
                }
                .disabled(csvURL == nil && bundleURL == nil)
                .accessibilityLabel("Session teilen")
            }
        }
        .task { prepareExports() }
        .onDisappear(perform: persist)
        .alert("Export fehlgeschlagen",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: Kopfdaten

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("Start") {
                Text(session.started.formatted(date: .abbreviated, time: .standard))
            }
            LabeledContent("Dauer") {
                Text(mmss(session.duration)).monospacedDigit()
            }
            LabeledContent("Elektrode") {
                TextField("Elektrode", text: $session.electrode)
                    .multilineTextAlignment(.trailing)
                    .onSubmit(persist)
                    .accessibilityLabel("Elektrode bearbeiten")
            }
            Divider()
            TextField("Notiz", text: $session.note, axis: .vertical)
                .lineLimit(2...6)
                .accessibilityLabel("Notiz zur Session")
        }
        .card()
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
            StatTile(title: "Bögen", value: "\(session.arcCount)",
                     symbol: "flame")
            StatTile(title: "Längster Bogen", value: dec1(session.longestArc ?? 0), unit: "s",
                     symbol: "bolt")
            StatTile(title: "Spitzenleistung", value: "\(Int((session.peakWatts ?? 0).rounded()))", unit: "W",
                     symbol: "gauge.with.dots.needle.100percent")
            StatTile(title: "Spitzenstrom", value: dec1(session.peakAmps ?? 0), unit: "A",
                     symbol: "waveform.path.ecg")
            StatTile(title: "Energie", value: dec1(energyWh), unit: "Wh",
                     symbol: "battery.100percent.bolt")
            StatTile(title: "Trips", value: "\(session.trips.count)",
                     symbol: "bolt.trianglebadge.exclamationmark",
                     tint: session.trips.isEmpty ? nil : Palette.warn)
        }
    }

    // MARK: Leistungskurve

    private var powerCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leistungskurve")
                .font(.headline)
            if plotSamples.count < 2 {
                Text("Keine Messwerte aufgezeichnet.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    // Bogenphasen als Bänder hinter der Kurve
                    ForEach(session.arcs) { arc in
                        RectangleMark(
                            xStart: .value("Start", arc.start),
                            xEnd: .value("Ende", arc.end ?? plotSamples.last?.t ?? arc.start)
                        )
                        .foregroundStyle(Palette.accent2.opacity(0.14))
                    }
                    ForEach(plotSamples) { s in
                        LineMark(x: .value("Zeit", s.t), y: .value("Leistung", s.w))
                            .foregroundStyle(Palette.accent)
                    }
                }
                .chartXAxisLabel("s")
                .chartYAxisLabel("W")
                .frame(height: 220)
                .accessibilityLabel("Leistungskurve: \(arcText(session.arcCount)), Spitze \(Int((session.peakWatts ?? 0).rounded())) Watt")
            }
        }
        .card()
    }

    // MARK: Trips

    private var tripsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Abschaltungen")
                .font(.headline)
            ForEach(session.trips) { trip in
                tripRow(trip)
                if trip.id != session.trips.last?.id {
                    Divider()
                }
            }
        }
        .card()
    }

    private func tripRow(_ trip: Trip) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(trip.reason.label, systemImage: trip.reason.symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(trip.reason.requiresAcknowledgement ? Palette.danger : Palette.warn)
            Text("bei \(mmss(trip.t)) · \(trip.date.formatted(date: .omitted, time: .standard))")
                .font(.caption)
                .foregroundStyle(.secondary)
            let measured = [trip.amps.map { dec1($0) + " A" },
                            trip.watts.map { "\(Int($0.rounded())) W" }]
                .compactMap { $0 }
            if !measured.isEmpty {
                Text(measured.joined(separator: " · "))
                    .font(.caption.monospacedDigit())
            }
            if trip.context.count > 1 {
                // ±10-s-Ausschnitt um den Trip, rote Linie markiert den Moment.
                Chart {
                    ForEach(trip.context) { s in
                        LineMark(x: .value("Zeit", s.t), y: .value("Leistung", s.w))
                            .foregroundStyle(Palette.accent)
                    }
                    RuleMark(x: .value("Abschaltung", trip.t))
                        .foregroundStyle(Palette.danger.opacity(0.8))
                }
                .frame(height: 72)
                .accessibilityLabel("Kurvenausschnitt um die Abschaltung bei \(mmss(trip.t))")
            }
        }
    }

    // MARK: Speichern & Export

    private func persist() {
        guard session != saved else { return }
        store.update(session)
        saved = session
    }

    /// ShareLink braucht die URL synchron — deshalb werden beide Exporte beim
    /// Öffnen vorbereitet; Fehler landen im Alert statt im Nichts.
    private func prepareExports() {
        do {
            csvURL = try store.csvURL(for: session)
            bundleURL = try store.exportBundle(for: session)
        } catch {
            exportError = error.localizedDescription
        }
    }
}

// MARK: - Vergleich

struct SessionCompareView: View {
    @Environment(\.dismiss) private var dismiss

    let a: Session
    let b: Session

    /// Gemeinsames Zeitraster, einmal beim Öffnen berechnet.
    private let points: [(t: Double, a: Double?, b: Double?)]

    init(a: Session, b: Session) {
        self.a = a
        self.b = b
        // ponytail: Schrittweite so wählen, dass höchstens ~1200 Rasterpunkte
        // entstehen — compare() sucht je Rasterpunkt linear, feiner lohnt nicht.
        let end = max(a.samples.last?.t ?? 0, b.samples.last?.t ?? 0)
        points = SessionStore.compare(a, b, step: max(0.25, end / 1200))
    }

    private var labelA: String {
        "A · \(a.started.formatted(date: .abbreviated, time: .shortened)) · \(a.electrode)"
    }
    private var labelB: String {
        "B · \(b.started.formatted(date: .abbreviated, time: .shortened)) · \(b.electrode)"
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                chartCard
                statsCard
            }
            .padding()
        }
        .appBackground()
        .navigationTitle("Vergleich")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Fertig") { dismiss() }
                    .accessibilityLabel("Vergleich schliessen")
            }
        }
    }

    private var chartCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Leistung im Vergleich")
                .font(.headline)
            if points.isEmpty {
                Text("Keine Messwerte zum Vergleichen.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Chart {
                    ForEach(points.indices, id: \.self) { i in
                        let p = points[i]
                        // Fehlende Werte werden übersprungen, nicht als 0 gezeichnet —
                        // bewusst keine Extrapolation, die Kurve zeigt nur Gemessenes.
                        if let w = p.a {
                            LineMark(x: .value("Zeit", p.t), y: .value("Leistung", w),
                                     series: .value("Session", "A"))
                                .foregroundStyle(by: .value("Session", labelA))
                        }
                        if let w = p.b {
                            LineMark(x: .value("Zeit", p.t), y: .value("Leistung", w),
                                     series: .value("Session", "B"))
                                .foregroundStyle(by: .value("Session", labelB))
                        }
                    }
                }
                .chartForegroundStyleScale([labelA: Palette.accent, labelB: Palette.warn])
                .chartXAxisLabel("s")
                .chartYAxisLabel("W")
                .frame(height: 260)
                .accessibilityLabel("Vergleich der Leistungskurven beider Sessions")
            }
        }
        .card()
    }

    private var statsCard: some View {
        Grid(alignment: .leading, horizontalSpacing: 16, verticalSpacing: 8) {
            GridRow {
                Text("Kennzahl")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("A")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.accent)
                Text("B")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.warn)
            }
            compareRow("Dauer", mmss(a.duration), mmss(b.duration))
            compareRow("Bögen", "\(a.arcCount)", "\(b.arcCount)")
            compareRow("Längster Bogen",
                       dec1(a.longestArc ?? 0) + " s", dec1(b.longestArc ?? 0) + " s")
            compareRow("Spitzenleistung",
                       "\(Int((a.peakWatts ?? 0).rounded())) W",
                       "\(Int((b.peakWatts ?? 0).rounded())) W")
            compareRow("Spitzenstrom",
                       dec1(a.peakAmps ?? 0) + " A", dec1(b.peakAmps ?? 0) + " A")
            compareRow("Energie",
                       dec1(a.wattHours) + " Wh", dec1(b.wattHours) + " Wh")
            compareRow("Trips", "\(a.trips.count)", "\(b.trips.count)")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
        .accessibilityElement(children: .combine)
    }

    private func compareRow(_ title: String, _ va: String, _ vb: String) -> some View {
        GridRow {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(va)
                .font(.subheadline.monospacedDigit())
            Text(vb)
                .font(.subheadline.monospacedDigit())
        }
    }
}
