// ControlView.swift — HV-Capture
//
// Hauptansicht: schalten, messen, überwachen. Schaltet nie selbst —
// alles läuft über ArcController.shared.

import SwiftUI
import Charts

struct ControlView: View {
    @State private var controller = ArcController.shared
    @State private var plug = PlugLink.shared
    @State private var recorder = SessionRecorder.shared

    @AppStorage("timerSeconds") private var timerSeconds = 30
    @AppStorage("pulseOn") private var pulseOn = 5
    @AppStorage("pulseOff") private var pulseOff = 10
    @AppStorage("pulseRepeats") private var pulseRepeats = 3
    @AppStorage("liveThemeMaxWatts") private var maxWatts = 2000.0

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                if let trip = controller.pendingTrip { tripBanner(trip) }
                connectionBanners
                meterCard
                actionCard
                if controller.secondsRemaining != nil { countdownCard }
                modeCard
                guardCard
                historyCard
            }
            .padding()
        }
        .appBackground()
        .navigationTitle("Steuerung")
    }

    // MARK: - Trip

    private func tripBanner(_ trip: ArcController.TripRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            WarningBanner(
                text: "\(trip.reason.label) · \(trip.date.formatted(date: .omitted, time: .standard))",
                symbol: trip.reason.symbol,
                tint: Palette.danger)
            if let detail = trip.detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("Einschalten ist gesperrt, bis die Abschaltung quittiert ist.")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Palette.danger)
            Button {
                Haptics.tap()
                controller.acknowledgeTrip()
            } label: {
                Label("Quittieren", systemImage: "checkmark.circle.fill")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.danger)
            .accessibilityLabel("Abschaltung quittieren")
        }
        .card()
    }

    // MARK: - Verbindung

    @ViewBuilder
    private var connectionBanners: some View {
        if !plug.isConfigured {
            WarningBanner(text: "Keine IP-Adresse hinterlegt — bitte in den Einstellungen eintragen.",
                          symbol: "wifi.slash", tint: Palette.warn)
        }
        if controller.isArmed && !plug.reachable {
            WarningBanner(text: "Steckdose antwortet nicht.",
                          symbol: "wifi.exclamationmark", tint: Palette.danger)
        }
        if plug.watchdogFallbackInUse {
            WarningBanner(text: "Rückfallweg der Selbstabschaltung aktiv — ältere Firmware ohne Auftrags-IDs.",
                          symbol: "exclamationmark.triangle", tint: Palette.warn)
        }
    }

    // MARK: - Messwerte

    private var meterCard: some View {
        VStack(spacing: 12) {
            ArcMeter(watts: plug.reading?.watts,
                     maxWatts: max(maxWatts, 100),
                     tripping: controller.pendingTrip != nil)
                .frame(maxWidth: 260)
            HStack(spacing: 10) {
                StatTile(title: "Spannung", value: fmt(plug.reading?.volts, 0),
                         unit: "V", symbol: "bolt.fill")
                StatTile(title: "Strom", value: fmt(plug.reading?.amps, 2),
                         unit: "A", symbol: "waveform.path.ecg")
                StatTile(title: "Energie", value: fmt(plug.reading?.kwh, 3),
                         unit: "kWh", symbol: "battery.100percent.bolt")
            }
        }
    }

    // MARK: - Hauptknopf und Not-Aus

    private var actionCard: some View {
        VStack(spacing: 10) {
            HStack(spacing: 32) {
                if controller.mode == .deadManSwitch {
                    DeadManButton(controller: controller,
                                  locked: controller.pendingTrip != nil)
                } else {
                    BigActionButton(
                        title: controller.isArmed ? "AUS" : "EIN",
                        symbol: "power",
                        tint: controller.isArmed ? Palette.warn : Palette.ok,
                        isEnabled: controller.isArmed
                            || (controller.pendingTrip == nil && plug.isConfigured)
                    ) {
                        Task {
                            if controller.isArmed {
                                await controller.disarm()
                            } else {
                                await controller.arm()
                            }
                        }
                    }
                }

                // Immer bedienbar — auch wenn gerade nichts läuft.
                BigActionButton(title: "Not-Aus",
                                symbol: "exclamationmark.octagon.fill",
                                tint: Palette.danger) {
                    Task { await controller.emergencyOff() }
                }
                .accessibilityLabel("Not-Aus, sofort abschalten")
            }
            if let message = controller.statusMessage {
                Text(message)
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .card()
    }

    // MARK: - Countdown

    private var countdownCard: some View {
        VStack(spacing: 4) {
            if let s = controller.secondsRemaining {
                if s >= 0 {
                    Text("\(s)")
                        .font(.system(size: 56, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("Sekunden verbleibend")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Pause · \(abs(s)) s")
                        .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                        .contentTransition(.numericText())
                    Text("Durchgang \(controller.pulseCycle) von \(controller.pulseRepeats)")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity)
        .card()
        .accessibilityElement(children: .combine)
    }

    // MARK: - Betriebsart

    private var modeCard: some View {
        // Lokales Binding, weil `mode` am @Observable-Controller hängt.
        let mode = Binding(get: { controller.mode }, set: { controller.mode = $0 })
        return VStack(alignment: .leading, spacing: 10) {
            Text("Betriebsart")
                .font(.headline)
            Picker("Betriebsart", selection: mode) {
                ForEach(RunMode.allCases) { m in
                    Text(m.label).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .disabled(controller.isArmed)   // Moduswechsel nie im laufenden Betrieb

            Text(controller.mode.explanation)
                .font(.footnote)
                .foregroundStyle(.secondary)

            switch controller.mode {
            case .timer:
                Stepper(value: $timerSeconds, in: 1...3600) {
                    Text("Dauer: \(timerSeconds) s")
                        .monospacedDigit()
                }
                .accessibilityLabel("Timer-Dauer in Sekunden")
            case .pulse:
                Stepper(value: $pulseOn, in: 1...3600) {
                    Text("An-Phase: \(pulseOn) s").monospacedDigit()
                }
                .accessibilityLabel("Dauer der An-Phase in Sekunden")
                Stepper(value: $pulseOff, in: 1...3600) {
                    Text("Aus-Phase: \(pulseOff) s").monospacedDigit()
                }
                .accessibilityLabel("Dauer der Aus-Phase in Sekunden")
                Stepper(value: $pulseRepeats, in: 1...100) {
                    Text("Durchgänge: \(pulseRepeats)").monospacedDigit()
                }
                .accessibilityLabel("Anzahl der Durchgänge")
            case .free, .deadManSwitch:
                EmptyView()
            }
        }
        .card()
    }

    // MARK: - Wächter

    private var guardCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Stromwächter")
                .font(.headline)
            guardRow("Grenzwert", "\(fmt(controller.guardConfig.tripAmps, 1)) A")
            guardRow("Haltezeit", "\(fmt(controller.guardConfig.holdSeconds, 1)) s")
            guardRow("Verdachtswert", "\(fmt(controller.guardConfig.suspectAmps, 1)) A")

            let problems = controller.guardConfig.problems
            if !problems.isEmpty {
                ForEach(problems, id: \.self) { p in
                    Label(p, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Palette.warn)
                }
            }

            NavigationLink("Grenzwerte einstellen") {
                GuardSettingsView()
            }
            .font(.subheadline.weight(.semibold))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    private func guardRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }
        .font(.subheadline)
    }

    // MARK: - Live-Verlauf

    private var historyCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Live-Verlauf")
                .font(.headline)
            let points = recentSamples
            if points.isEmpty {
                Text("Keine laufende Aufzeichnung.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Chart(points) { sample in
                    LineMark(x: .value("Zeit", sample.t),
                             y: .value("Leistung", sample.w))
                        .foregroundStyle(Palette.accent)
                        .interpolationMethod(.monotone)
                }
                .chartXAxis(.hidden)
                .frame(height: 120)
                .accessibilityLabel("Leistungsverlauf der letzten 60 Sekunden")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card()
    }

    /// Letzte ~60 s, höchstens 300 Punkte — mehr bringt dem kleinen Chart nichts.
    private var recentSamples: [Sample] {
        guard let samples = recorder.current?.samples, let last = samples.last else { return [] }
        let cutoff = last.t - 60
        return samples.suffix(300).filter { $0.t >= cutoff }
    }

    // MARK: - Formatierung

    /// Messwert mit fester Nachkommastellenzahl, „—" wenn er fehlt.
    private func fmt(_ value: Double?, _ digits: Int) -> String {
        value?.formatted(.number.precision(.fractionLength(digits))) ?? "—"
    }
}

// MARK: - Totmann-Taste

/// Halte-Knopf: Strom fliesst nur bei Kontakt. Kein Button — der würde das
/// Loslassen verschlucken, deshalb eine DragGesture ohne Mindestdistanz.
private struct DeadManButton: View {
    let controller: ArcController
    let locked: Bool

    @State private var holding = false

    var body: some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill((holding ? Palette.ok : Palette.warn).opacity(locked ? 0.06 : 0.18))
                Circle()
                    .strokeBorder((holding ? Palette.ok : Palette.warn).opacity(locked ? 0.25 : 0.7),
                                  lineWidth: 2)
                Image(systemName: "hand.raised.fill")
                    .font(.title2.weight(.bold))
                    .foregroundStyle(locked ? .secondary : (holding ? Palette.ok : Palette.warn))
            }
            .frame(width: 72, height: 72)
            .scaleEffect(holding ? 1.08 : 1)
            .animation(.easeOut(duration: 0.15), value: holding)
            Text(holding ? "Halten…" : "Halten = EIN")
                .font(.caption.weight(.semibold))
                .foregroundStyle(locked ? .secondary : .primary)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard !holding, !locked else { return }
                    holding = true
                    Haptics.tap()
                    Task { await controller.arm() }
                }
                .onEnded { _ in
                    holding = false
                    Haptics.tap()
                    Task { await controller.deadManReleased() }
                }
        )
        .accessibilityLabel("Totmann-Taste, halten zum Einschalten, loslassen schaltet ab")
        .accessibilityAddTraits(.isButton)
    }
}

#Preview {
    NavigationStack { ControlView() }
}
