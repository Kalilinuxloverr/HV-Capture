//
//  SettingsView.swift — Einstellungen: Steckdose, Selbstabschaltung, Grenzwerte,
//  Kalibrierung, Design, Aufnahme, Elektrode und die versteckte Entwickler-Ansicht.
//

import SwiftUI

// MARK: - Hilfen

/// Bogensekunden als m:ss.
private func mmss(_ seconds: Double) -> String {
    let t = Int(seconds.rounded())
    return "\(t / 60):" + String(format: "%02d", t % 60)
}

private func fmt(_ v: Double, _ digits: Int = 2) -> String {
    v.formatted(.number.precision(.fractionLength(digits)))
}

/// Slider mit Titel, Wertanzeige und Erklärtext — der Standardbaustein der
/// Grenzwert-Ansicht.
private struct SliderRow: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var step: Double = 0.1
    var unit: String = "A"
    var digits: Int = 1
    var explanation: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text("\(fmt(value, digits)) \(unit)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: $value, in: range, step: step)
                .accessibilityLabel(title)
                .accessibilityValue("\(fmt(value, digits)) \(unit)")
            if let explanation {
                Text(explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - Einstellungen

struct SettingsView: View {
    @State private var plug = PlugLink.shared
    @State private var store = SessionStore.shared

    @AppStorage("plugIP") private var plugIP = ""
    @AppStorage("pollIntervalMs") private var pollIntervalMs = 200
    @AppStorage("watchdogWindow") private var watchdogWindow = 30

    @AppStorage("accentColor") private var accentColor = "lichtbogen"
    @AppStorage("themeChoice") private var themeChoice = "karbon"
    @AppStorage("liveThemeEnabled") private var liveThemeEnabled = true
    @AppStorage("liveThemeMaxWatts") private var liveThemeMaxWatts = 2000.0
    @AppStorage("bootAnimationEnabled") private var bootAnimationEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    @AppStorage("captureMode") private var captureMode = "clip"
    @AppStorage("ringBufferSeconds") private var ringBufferSeconds = 4
    @AppStorage("postRollSeconds") private var postRollSeconds = 2
    @AppStorage("triggerBrightness") private var triggerBrightness = true
    @AppStorage("triggerCurrent") private var triggerCurrent = true
    @AppStorage("triggerAudio") private var triggerAudio = false
    @AppStorage("triggerAuto") private var triggerAuto = false
    @AppStorage("hudBurnIn") private var hudBurnIn = false

    @AppStorage("electrodeName") private var electrodeName = "Standard"

    @State private var devTaps = 0
    @State private var showDev = false

    // Nur in dieser Datei — die Aufnahme-Engine liest denselben Schlüssel.
    private let captureModes: [(key: String, label: String)] = [
        ("clip", "Auto-Clip (Ringpuffer)"),
        ("video", "Durchgehendes Video"),
        ("slowMotion", "Zeitlupe (hohe Bildrate)"),
        ("photo", "Serienfotos"),
    ]

    var body: some View {
        List {
            plugSection
            watchdogSection

            Section {
                NavigationLink("Grenzwerte") { GuardSettingsView() }
                    .accessibilityLabel("Grenzwerte des Stromwächters")
                NavigationLink("Kalibrierung") { CalibrationView() }
                    .accessibilityLabel("Kalibrierfahrt")
            } header: {
                Text("Wächter")
            }

            designSection
            captureSection
            electrodeSection
            developerSection
        }
        .navigationTitle("Einstellungen")
    }

    // MARK: Steckdose

    private var plugSection: some View {
        Section {
            TextField("IP-Adresse der Steckdose", text: $plugIP)
                .keyboardType(.decimalPad)
                .autocorrectionDisabled()
                .accessibilityLabel("IP-Adresse der Steckdose")

            HStack(spacing: 8) {
                Circle()
                    .fill(plug.reachable ? Palette.ok : Palette.danger)
                    .frame(width: 10, height: 10)
                Text(plug.reachable ? "Erreichbar" : "Nicht erreichbar")
                Spacer()
                if let last = plug.lastSuccess {
                    Text("zuletzt \(last.formatted(date: .omitted, time: .standard))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Verbindungsstatus")
            .accessibilityValue(plug.reachable ? "erreichbar" : "nicht erreichbar")

            Stepper("Abfrageintervall: \(pollIntervalMs) ms",
                    value: $pollIntervalMs, in: 100...2000, step: 50)
                .accessibilityLabel("Abfrageintervall")
                .accessibilityValue("\(pollIntervalMs) Millisekunden")
        } header: {
            Text("Steckdose")
        } footer: {
            Text("Der Messchip der Dose liefert nur etwa im Sekundentakt neue Werte. Schnelleres Abfragen senkt nur die Latenz, bis ein neuer Wert sichtbar wird — mehr Messpunkte entstehen dadurch nicht.")
        }
    }

    // MARK: Selbstabschaltung

    private var watchdogSection: some View {
        Section {
            Stepper("Fenster: \(watchdogWindow) s",
                    value: $watchdogWindow, in: 10...300, step: 5)
                .accessibilityLabel("Fenster der Selbstabschaltung")
                .accessibilityValue("\(watchdogWindow) Sekunden")

            if plug.watchdogFallbackInUse {
                Label("Rückfallweg aktiv: Die Firmware der Dose kennt keine Auftrags-IDs. Beim Erneuern des Auftrags entsteht ein kurzes Fenster ganz ohne aktive Selbstabschaltung.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.warn)
                    .accessibilityLabel("Warnung: Rückfallweg der Selbstabschaltung aktiv")
            } else {
                Label(plug.watchdogActive
                        ? "Auftrag gesetzt (\(plug.watchdogWindow) s)"
                        : "Derzeit kein Auftrag gesetzt",
                      systemImage: "timer")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        } header: {
            Text("Selbstabschaltung")
        } footer: {
            Text("Dieser Auftrag läuft in der Steckdose selbst. Er greift deshalb auch dann, wenn die App abstürzt, das iPhone gesperrt wird oder das WLAN ausfällt.")
        }
    }

    // MARK: Design

    private var designSection: some View {
        Section("Design") {
            Picker("Akzentfarbe", selection: $accentColor) {
                ForEach(Palette.accents, id: \.key) { accent in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(LinearGradient(colors: [accent.color, accent.partner],
                                                 startPoint: .topLeading,
                                                 endPoint: .bottomTrailing))
                            .frame(width: 20, height: 20)
                        Text(accent.name)
                    }
                    .tag(accent.key)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityLabel("Akzentfarbe")

            Picker("Hintergrund", selection: $themeChoice) {
                ForEach(Palette.themes, id: \.key) { theme in
                    HStack(spacing: 10) {
                        Circle()
                            .fill(Color(theme.card))
                            .overlay(Circle().strokeBorder(.white.opacity(0.25)))
                            .frame(width: 20, height: 20)
                        Text(theme.name)
                    }
                    .tag(theme.key)
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityLabel("Hintergrund")

            Toggle("Live-Theme", isOn: $liveThemeEnabled)
                .accessibilityLabel("Live-Theme")
            Text("Die Oberfläche folgt der Momentanleistung: je mehr Watt, desto weiter glüht der Akzent Richtung Weissglut.")
                .font(.caption)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text("Volle Glut bei")
                    Spacer()
                    Text("\(Int(liveThemeMaxWatts)) W")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(value: $liveThemeMaxWatts, in: 200...4000, step: 100)
                    .accessibilityLabel("Volle Glut bei")
                    .accessibilityValue("\(Int(liveThemeMaxWatts)) Watt")
            }
            .disabled(!liveThemeEnabled)

            Toggle("Startanimation", isOn: $bootAnimationEnabled)
                .accessibilityLabel("Startanimation")
            Toggle("Haptik", isOn: $hapticsEnabled)
                .accessibilityLabel("Haptik")
        }
    }

    // MARK: Aufnahme

    private var captureSection: some View {
        Section {
            Picker("Modus", selection: $captureMode) {
                ForEach(captureModes, id: \.key) { mode in
                    Text(mode.label).tag(mode.key)
                }
            }
            .accessibilityLabel("Aufnahmemodus")

            Stepper("Ringpuffer: \(ringBufferSeconds) s",
                    value: $ringBufferSeconds, in: 2...10)
                .accessibilityLabel("Ringpuffer")
                .accessibilityValue("\(ringBufferSeconds) Sekunden")
            Stepper("Nachlauf: \(postRollSeconds) s",
                    value: $postRollSeconds, in: 1...10)
                .accessibilityLabel("Nachlauf")
                .accessibilityValue("\(postRollSeconds) Sekunden")

            Toggle("Automatik", isOn: $triggerAuto)
                .accessibilityLabel("Auslöser-Automatik")
            if triggerAuto {
                Text("Automatik aktiv — alle Auslöser sind aktiv.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Bei Automatik sind die Einzel-Auslöser fest „alle aktiv".
            Toggle("Helligkeitssprung", isOn: triggerAuto ? .constant(true) : $triggerBrightness)
                .disabled(triggerAuto)
                .accessibilityLabel("Auslöser Helligkeitssprung")
            Toggle("Stromanstieg", isOn: triggerAuto ? .constant(true) : $triggerCurrent)
                .disabled(triggerAuto)
                .accessibilityLabel("Auslöser Stromanstieg")
            Toggle("Knallgeräusch", isOn: triggerAuto ? .constant(true) : $triggerAudio)
                .disabled(triggerAuto)
                .accessibilityLabel("Auslöser Knallgeräusch")

            Toggle("Messwerte einbrennen", isOn: $hudBurnIn)
                .accessibilityLabel("Messwerte ins Video einbrennen")
        } header: {
            Text("Aufnahme")
        } footer: {
            Text("Der Ringpuffer hält die letzten Sekunden ständig im Speicher; ein Auslöser sichert sie samt Nachlauf als Clip. Eingebrannte Messwerte liegen fest im Videobild und lassen sich nachträglich nicht entfernen.")
        }
    }

    // MARK: Elektrode

    private var electrodeSection: some View {
        Section {
            TextField("Name der Elektrode", text: $electrodeName)
                .accessibilityLabel("Name der Elektrode")

            if store.electrodeWear.isEmpty {
                Text("Noch keine Bogenzeit aufgezeichnet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(store.electrodeWear) { wear in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(wear.name)
                            Text("\(wear.sessions) Sessions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(mmss(wear.arcSeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Elektrode \(wear.name)")
                    .accessibilityValue("\(mmss(wear.arcSeconds)) Bogenzeit in \(wear.sessions) Sessions")
                }
            }
        } header: {
            Text("Elektrode")
        } footer: {
            Text("Kumulierte Bogenzeit je Elektrodenname über alle Sessions (Minuten:Sekunden).")
        }
    }

    // MARK: Entwickler (versteckt)

    private var developerSection: some View {
        Section {
            if showDev {
                NavigationLink("Entwickler") { DevModeView() }
                    .accessibilityLabel("Entwickler-Ansicht")
            }
        } footer: {
            Text("HV-Capture 1.0")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    devTaps += 1
                    if devTaps >= 10, !showDev {
                        showDev = true
                        Haptics.success()
                    }
                }
                .accessibilityLabel("Version HV-Capture 1.0")
        }
    }
}

// MARK: - Grenzwerte

struct GuardSettingsView: View {
    @State private var controller = ArcController.shared
    @State private var config = GuardConfig()
    @State private var loaded = false

    var body: some View {
        List {
            Section {
                Toggle("Grenzwert-Abschaltung", isOn: $config.thresholdEnabled)
                    .accessibilityLabel("Grenzwert-Abschaltung")
                SliderRow(title: "Grenzwert", value: $config.tripAmps,
                          range: 0.5...20, step: 0.1,
                          explanation: "Liegt der Strom länger als die Haltezeit über diesem Wert, wird abgeschaltet.")
                SliderRow(title: "Haltezeit", value: $config.holdSeconds,
                          range: 0.2...10, step: 0.1, unit: "s",
                          explanation: "So lange darf der Strom über dem Grenzwert liegen, bevor ausgelöst wird — kurze Spitzen beim Zünden lösen so nicht aus.")
            } header: {
                Text("Harte Schwelle")
            }

            Section {
                Toggle("Flachheits-Abschaltung", isOn: $config.flatnessEnabled)
                    .accessibilityLabel("Flachheits-Abschaltung")
                SliderRow(title: "Verdachtswert", value: $config.suspectAmps,
                          range: 0.5...20, step: 0.1,
                          explanation: "Erst ab diesem Strom wird auf Kleben geprüft — ein brennender Bogen flackert, ein klebender Kurzschluss ist still.")
                SliderRow(title: "Fenster", value: $config.flatnessWindow,
                          range: 0.5...5, step: 0.1, unit: "s",
                          explanation: "Beobachtungszeitraum der Flachheitsprüfung.")
                SliderRow(title: "Max. Schwankung", value: $config.flatnessMaxRange,
                          range: 0.02...1.0, step: 0.01, digits: 2,
                          explanation: "Gemessen wird die Spannweite (grösster minus kleinster Wert) im Fenster, nicht die Standardabweichung: die App fragt schneller ab, als die Dose neue Werte liefert, und die vielen Wiederholungen würden eine Standardabweichung künstlich klein machen. Auf die Spannweite haben Wiederholungen keinen Einfluss.")
            } header: {
                Text("Flachheit")
            }

            Section("Datenverlust") {
                SliderRow(title: "Abschalten nach", value: $config.dataLossSeconds,
                          range: 1...20, step: 0.5, unit: "s",
                          explanation: "Kommen so lange keine plausiblen Messwerte, obwohl die Dose an ist, wird abgeschaltet — im Zweifel aus, nicht weiter.")
            }

            Section {
                SliderRow(title: "Bogen ein", value: $config.arcOnAmps,
                          range: 0.1...10, step: 0.1,
                          explanation: "Ab diesem Strom gilt ein Bogen als gezündet.")
                SliderRow(title: "Bogen aus", value: $config.arcOffAmps,
                          range: 0.1...10, step: 0.1,
                          explanation: "Darunter gilt er als erloschen (Hysterese). Reine Statistik für Zähler und Verschleiss, keine Sicherheitsfunktion.")
            } header: {
                Text("Bogen-Erkennung")
            }

            if !config.problems.isEmpty {
                Section("Probleme") {
                    ForEach(config.problems, id: \.self) { problem in
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote)
                            .foregroundStyle(Palette.danger)
                    }
                }
            }

            Section {
                Button("Auf Standardwerte zurücksetzen", role: .destructive) {
                    config = GuardConfig()
                    Haptics.warning()
                }
                .accessibilityLabel("Auf Standardwerte zurücksetzen")
            }
        }
        .navigationTitle("Grenzwerte")
        .onAppear {
            if !loaded {
                config = controller.guardConfig
                loaded = true
            }
        }
        // Lokale Kopie — jede Änderung wird sofort über den Controller gesichert.
        .onChange(of: config) { _, new in
            controller.saveConfig(new)
        }
    }
}

// MARK: - Kalibrierung

struct CalibrationView: View {
    @State private var controller = ArcController.shared

    var body: some View {
        List {
            Section {
                Text("Drei geführte Messungen. Währenddessen greift der Wächter absichtlich nicht ein — es werden ja gerade erst die Grenzwerte ermittelt.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(Calibration.Step.allCases) { step in
                stepSection(step)
            }

            suggestionSection
        }
        .navigationTitle("Kalibrierung")
        .onDisappear {
            // Verlassen der Ansicht beendet eine laufende Messung.
            controller.calibrating = false
        }
    }

    private func stepSection(_ step: Calibration.Step) -> some View {
        let samples = controller.calibration.samples(for: step)
        let isActive = controller.calibrating && controller.calibrationStep == step

        return Section {
            Text(step.instruction)
                .font(.footnote)
                .foregroundStyle(.secondary)

            LabeledContent("Gesammelte Werte", value: "\(samples.count)")
                .accessibilityLabel("Gesammelte Werte für \(step.title)")
                .accessibilityValue("\(samples.count)")

            if let lo = samples.min(), let hi = samples.max() {
                let mean = samples.reduce(0, +) / Double(samples.count)
                LabeledContent("Min / Max / Mittel") {
                    Text("\(fmt(lo)) / \(fmt(hi)) / \(fmt(mean)) A")
                        .monospacedDigit()
                }
            }

            Button(isActive ? "Messung stoppen" : "Messung starten") {
                if isActive {
                    controller.calibrating = false
                    Haptics.light()
                } else {
                    controller.calibrationStep = step
                    controller.calibrating = true
                    Haptics.tap()
                }
            }
            .foregroundStyle(isActive ? Palette.warn : Palette.accent)
            .accessibilityLabel(isActive ? "Messung für \(step.title) stoppen"
                                         : "Messung für \(step.title) starten")

            // ponytail: Der Controller bietet nur einen Komplett-Reset —
            // schrittweises Löschen bräuchte eine API in ArcController.
            Button("Alle Messungen verwerfen", role: .destructive) {
                controller.calibrating = false
                controller.resetCalibration()
                Haptics.warning()
            }
            .disabled(controller.calibration == Calibration())
            .accessibilityLabel("Alle Messungen verwerfen")
        } header: {
            HStack {
                Text(step.title)
                if isActive {
                    Text("läuft …")
                        .foregroundStyle(Palette.warn)
                }
            }
        } footer: {
            if step == .stuck {
                Text("Dieser Schritt ist optional und kann übersprungen werden.")
            }
        }
    }

    @ViewBuilder
    private var suggestionSection: some View {
        let cal = controller.calibration
        Section("Vorschlag") {
            if let suggestion = cal.suggestion(basedOn: controller.guardConfig) {
                compareRow("Grenzwert", old: controller.guardConfig.tripAmps, new: suggestion.tripAmps)
                compareRow("Verdachtswert", old: controller.guardConfig.suspectAmps, new: suggestion.suspectAmps)
                compareRow("Max. Schwankung", old: controller.guardConfig.flatnessMaxRange, new: suggestion.flatnessMaxRange)
                compareRow("Bogen ein", old: controller.guardConfig.arcOnAmps, new: suggestion.arcOnAmps)
                compareRow("Bogen aus", old: controller.guardConfig.arcOffAmps, new: suggestion.arcOffAmps)

                Button("Vorschlag übernehmen") {
                    controller.saveConfig(suggestion)
                    Haptics.success()
                }
                .accessibilityLabel("Vorschlag übernehmen")

                Text("Die Werte bleiben danach unter „Grenzwerte“ weiterhin von Hand justierbar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                // Lieber sagen, was fehlt, als eine Zahl zu erfinden.
                Text("Noch kein Vorschlag möglich. Benötigt werden mindestens 3 Leerlaufwerte (aktuell \(cal.idle.count)) und 5 Bogenwerte (aktuell \(cal.arc.count)).")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func compareRow(_ title: String, old: Double, new: Double) -> some View {
        LabeledContent(title) {
            Text("\(fmt(old)) → \(fmt(new)) A")
                .monospacedDigit()
        }
        .accessibilityLabel(title)
        .accessibilityValue("bisher \(fmt(old)) Ampere, Vorschlag \(fmt(new)) Ampere")
    }
}

// MARK: - Entwickler

struct DevModeView: View {
    @State private var plug = PlugLink.shared
    @State private var store = SessionStore.shared
    @State private var selfCheckResult: String?

    var body: some View {
        List {
            simulationSection
            ratesSection
            commandsSection
            rawSection
            selfCheckSection
            storageSection
        }
        .navigationTitle("Entwickler")
    }

    private var simulationSection: some View {
        Section {
            Picker("Szenario",
                   selection: Binding(get: { plug.simulation },
                                      set: { plug.simulation = $0 })) {
                Text("Aus").tag(PlugScenario?.none)
                ForEach(PlugScenario.allCases) { scenario in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(scenario.label)
                        Text(scenario.detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .tag(PlugScenario?.some(scenario))
                }
            }
            .pickerStyle(.navigationLink)
            .accessibilityLabel("Simulations-Szenario")
        } header: {
            Text("Simulation")
        } footer: {
            Text("Synthetische Messreihen statt echter HTTP-Abfragen — damit lassen sich Auswertung und Oberfläche ohne angeschlossene Hardware prüfen.")
        }
    }

    private var ratesSection: some View {
        Section {
            LabeledContent("Abfragerate", value: "\(fmt(plug.pollHz)) Hz")
            LabeledContent("Effektive Rate", value: "\(fmt(plug.effectiveHz)) Hz")
        } header: {
            Text("Raten")
        } footer: {
            Text("Abfragerate: wie oft die App fragt. Effektive Rate: wie oft die Dose tatsächlich einen neuen Wert liefert — der Messchip aktualisiert nur etwa im Sekundentakt, alles darüber sind Wiederholungen.")
        }
    }

    private var commandsSection: some View {
        Section {
            commandRow("Einschalten", PlugCommand.power(on: true))
            commandRow("Ausschalten", PlugCommand.power(on: false))
            commandRow("Messwerte", PlugCommand.status8)
            commandRow("Selbstabschaltung setzen (\(plug.watchdogWindow) s)",
                       PlugCommand.autoOffArm(seconds: plug.watchdogWindow,
                                              id: PlugCommand.watchdogEventID))
            commandRow("Selbstabschaltung aufheben",
                       PlugCommand.autoOffCancel(id: PlugCommand.watchdogEventID))
        } header: {
            Text("Befehle")
        } footer: {
            Text("Jeweils hinter http://<ip>/cm?cmnd= gehängt im Browser direkt gegen die Dose testbar.")
        }
    }

    private func commandRow(_ title: String, _ cmnd: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(cmnd)
                .font(.caption.monospaced())
                .textSelection(.enabled)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(title)
        .accessibilityValue(cmnd)
    }

    private var rawSection: some View {
        Section("Rohwerte") {
            if let r = plug.reading {
                LabeledContent("Zeitpunkt", value: r.date.formatted(date: .omitted, time: .standard))
                LabeledContent("Spannung", value: r.volts.map { "\(fmt($0, 1)) V" } ?? "—")
                LabeledContent("Strom", value: r.amps.map { "\(fmt($0, 3)) A" } ?? "—")
                LabeledContent("Leistung", value: r.watts.map { "\(fmt($0, 1)) W" } ?? "—")
                LabeledContent("Zähler", value: r.kwh.map { "\(fmt($0, 3)) kWh" } ?? "—")
            } else {
                Text("Keine Messwerte.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var selfCheckSection: some View {
        Section("Selbsttest") {
            #if DEBUG
            Button("Selbsttest ausführen") {
                selfCheckResult = RecorderSelfCheck.run()
            }
            .accessibilityLabel("Selbsttest ausführen")
            if let selfCheckResult {
                Text(selfCheckResult)
                    .font(.footnote)
                    .foregroundStyle(Palette.ok)
            }
            #else
            Text("Nur in Debug-Builds verfügbar.")
                .foregroundStyle(.secondary)
            #endif
        }
    }

    private var storageSection: some View {
        Section("Ablage") {
            LabeledContent("Sessions", value: "\(store.sessions.count)")
            ForEach(store.loadErrors, id: \.self) { error in
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.danger)
            }
        }
    }
}
