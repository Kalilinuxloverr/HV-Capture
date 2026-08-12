//
//  SettingsView.swift — Einstellungen als Kategorien-Übersicht im Stil der
//  System-Einstellungen: jede Kategorie eine eigene Seite, die Übersicht
//  bleibt eine kurze, selbsterklärende Liste.
//

import SwiftUI
import UniformTypeIdentifiers

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

/// Zeile der Kategorien-Übersicht: farbiges Symbol-Quadrat wie in den
/// System-Einstellungen.
private struct CategoryRow: View {
    let title: String
    let symbol: String
    let color: Color

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(RoundedRectangle(cornerRadius: 7).fill(color))
            Text(title)
        }
    }
}

// MARK: - Übersicht

struct SettingsView: View {
    @State private var plug = PlugLink.shared
    @AppStorage("devModeUnlocked") private var devUnlocked = false
    @State private var devTaps = 0

    var body: some View {
        List {
            Section {
                NavigationLink { ConnectionSettingsView() } label: {
                    CategoryRow(title: "Steckdose & Verbindung",
                                symbol: "poweroutlet.type.f.fill", color: .blue)
                }
                .accessibilityLabel("Steckdose und Verbindung")
            } header: {
                Text("Verbindung")
            } footer: {
                Text(plug.reachable ? "Steckdose erreichbar." : "Steckdose derzeit nicht erreichbar.")
            }

            Section("Sicherheit") {
                NavigationLink { GuardSettingsView() } label: {
                    CategoryRow(title: "Wächter & Grenzwerte",
                                symbol: "gauge.with.needle", color: .orange)
                }
                .accessibilityLabel("Wächter und Grenzwerte")
                NavigationLink { CalibrationView() } label: {
                    CategoryRow(title: "Kalibrierung",
                                symbol: "slider.horizontal.3", color: .yellow)
                }
                .accessibilityLabel("Kalibrierfahrt")
                NavigationLink { SafetySettingsView() } label: {
                    CategoryRow(title: "Alarme & Schutz",
                                symbol: "bell.badge.fill", color: .red)
                }
                .accessibilityLabel("Alarme und Schutz")
            }

            Section("Kamera") {
                NavigationLink { CameraSettingsView() } label: {
                    CategoryRow(title: "Aufnahme", symbol: "camera.fill", color: .indigo)
                }
                .accessibilityLabel("Aufnahme-Einstellungen")
                NavigationLink { TriggerSettingsView() } label: {
                    CategoryRow(title: "Auslöser", symbol: "wand.and.rays", color: .purple)
                }
                .accessibilityLabel("Auslöser-Einstellungen")
            }

            Section("Erscheinungsbild") {
                NavigationLink { DesignSettingsView() } label: {
                    CategoryRow(title: "Design", symbol: "paintpalette.fill", color: .pink)
                }
                .accessibilityLabel("Design")
                NavigationLink { LanguageSettingsView() } label: {
                    CategoryRow(title: "Sprache", symbol: "globe", color: .teal)
                }
                .accessibilityLabel("Sprache")
            }

            Section("Aufbau") {
                NavigationLink { RigPlannerView() } label: {
                    CategoryRow(title: "Aufbau-Planer",
                                symbol: "square.grid.3x3.middle.filled", color: .green)
                }
                .accessibilityLabel("Aufbau-Planer")
                NavigationLink { ElectrodeSettingsView() } label: {
                    CategoryRow(title: "Elektrode", symbol: "bolt.horizontal.fill", color: .brown)
                }
                .accessibilityLabel("Elektrode")
            }

            Section("Daten") {
                NavigationLink { DataSettingsView() } label: {
                    CategoryRow(title: "Backup & Wiederherstellen",
                                symbol: "externaldrive.fill", color: .gray)
                }
                .accessibilityLabel("Backup und Wiederherstellen")
            }

            developerSection
        }
        .navigationTitle("Einstellungen")
    }

    // MARK: Entwickler (versteckt, per 10 Tipps auf die Version)

    private var developerSection: some View {
        Section {
            if devUnlocked {
                NavigationLink { DevModeView() } label: {
                    CategoryRow(title: "Entwickler",
                                symbol: "wrench.and.screwdriver.fill", color: .mint)
                }
                .accessibilityLabel("Entwickler-Ansicht")
            }
        } footer: {
            Text("HV-Capture 1.0")
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture {
                    devTaps += 1
                    if devTaps >= 10, !devUnlocked {
                        devUnlocked = true
                        Haptics.success()
                    }
                }
                .accessibilityLabel("Version HV-Capture 1.0")
        }
    }
}

// MARK: - Steckdose & Verbindung

struct ConnectionSettingsView: View {
    @State private var plug = PlugLink.shared
    @AppStorage("plugIP") private var plugIP = ""
    @AppStorage("pollIntervalMs") private var pollIntervalMs = 200
    @AppStorage("watchdogWindow") private var watchdogWindow = 30

    var body: some View {
        List {
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
        .navigationTitle("Steckdose & Verbindung")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Alarme & Schutz

struct SafetySettingsView: View {
    @AppStorage("tripNotificationsEnabled") private var tripNotifications = true
    @AppStorage("alarmSoundEnabled") private var alarmSound = true
    @AppStorage("geigerEnabled") private var geiger = false
    @AppStorage("appLockEnabled") private var appLock = false
    @AppStorage("preRollSeconds") private var preRollSeconds = 3

    var body: some View {
        List {
            Section {
                Toggle("Mitteilung bei Abschaltung", isOn: $tripNotifications)
                    .accessibilityLabel("Mitteilung bei Abschaltung")
                Toggle("Alarmton bei Abschaltung", isOn: $alarmSound)
                    .accessibilityLabel("Alarmton bei Abschaltung")
            } header: {
                Text("Abschaltungen")
            } footer: {
                Text("Beides kommt nur bei echten Schutzabschaltungen (Grenzwert, Kleben, Datenverlust, Dead-Man, App im Hintergrund) — nicht bei geplantem Aus.")
            }

            Section {
                Toggle("Geiger-Klicken bei Betrieb", isOn: $geiger)
                    .accessibilityLabel("Geiger-Klicken bei Betrieb")
            } header: {
                Text("Hörbare Leistung")
            } footer: {
                Text("Solange scharfgeschaltet ist, klickt es wie ein Geigerzähler: je mehr Watt, desto schneller. Du hörst den Strom, ohne aufs Display zu schauen — die volle Klickrate liegt bei derselben Watt-Marke wie die volle Glut des Live-Themes.")
            }

            Section {
                Toggle("App per Face ID sperren", isOn: $appLock)
                    .accessibilityLabel("App per Face ID sperren")
                Stepper(preRollSeconds == 0 ? "Einschalt-Countdown: aus"
                                            : "Einschalt-Countdown: \(preRollSeconds) s",
                        value: $preRollSeconds, in: 0...10)
                    .accessibilityLabel("Einschalt-Countdown")
                    .accessibilityValue(preRollSeconds == 0 ? "aus" : "\(preRollSeconds) Sekunden")
            } header: {
                Text("Schutz")
            } footer: {
                Text("Der Countdown gibt dir vor dem Einschalten ein paar Sekunden zum Zurücktreten; Not-Aus geht immer sofort. Im Frei-Modus kommt zusätzlich vor jedem Einschalten eine Sicherheitsabfrage.")
            }
        }
        .navigationTitle("Alarme & Schutz")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Aufnahme

struct CameraSettingsView: View {
    @AppStorage("captureMode") private var captureMode = "arc"
    @AppStorage("videoQuality") private var videoQuality = "1080p"
    @AppStorage("ringBufferSeconds") private var ringBufferSeconds = 4
    @AppStorage("postRollSeconds") private var postRollSeconds = 2
    @AppStorage("burstCount") private var burstCount = 3
    @AppStorage("hudBurnIn") private var hudBurnIn = false
    @AppStorage("photosExportEnabled") private var photosExport = true

    // Vier Modi, jeder mit einer Zeile, was er tut. „clip"/altes „video" werden
    // in der Engine auf „arc" migriert.
    private let captureModes: [(key: String, label: String, hint: String)] = [
        ("photo", "Foto", "Einzel- oder Serienfotos in voller Auflösung."),
        ("video", "Video", "Ganz normales Video wie die System-Kamera — scharf, flüssig, stabilisiert."),
        ("arc", "Bogen", "Ringpuffer-Clips: ein Auslöser sichert auch die Sekunden VOR dem Bogen."),
        ("slowMotion", "Zeitlupe", "Hohe Bildrate, zeitlich gestreckt — für den Moment des Zündens."),
    ]

    private var isRingMode: Bool { captureMode == "arc" || captureMode == "slowMotion" }

    var body: some View {
        List {
            Section {
                Picker("Modus", selection: $captureMode) {
                    ForEach(captureModes, id: \.key) { mode in
                        Text(mode.label).tag(mode.key)
                    }
                }
                .accessibilityLabel("Aufnahmemodus")
                if let hint = captureModes.first(where: { $0.key == captureMode })?.hint {
                    Text(hint)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if captureMode == "video" {
                    Picker("Auflösung", selection: $videoQuality) {
                        Text("1080p").tag("1080p")
                        Text("4K").tag("4k")
                    }
                    .pickerStyle(.segmented)
                    .accessibilityLabel("Video-Auflösung")
                    Text("4K ist schärfer, braucht aber mehr Speicher und lässt das iPhone schneller warm werden.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if captureMode == "photo" {
                    Stepper(burstCount == 1 ? "Einzelfoto"
                                            : "Serie: \(burstCount) Fotos je Auslösung",
                            value: $burstCount, in: 1...10)
                        .accessibilityLabel("Serienbilder je Auslösung")
                        .accessibilityValue("\(burstCount)")
                    Text("Eine schnelle Serie statt einem Einzelbild — der beste Frame ist meistens dabei.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if isRingMode {
                    Stepper("Ringpuffer: \(ringBufferSeconds) s",
                            value: $ringBufferSeconds, in: 2...10)
                        .accessibilityLabel("Ringpuffer")
                        .accessibilityValue("\(ringBufferSeconds) Sekunden")
                    Stepper("Nachlauf: \(postRollSeconds) s",
                            value: $postRollSeconds, in: 1...10)
                        .accessibilityLabel("Nachlauf")
                        .accessibilityValue("\(postRollSeconds) Sekunden")
                }

                Toggle("Messwerte einbrennen", isOn: $hudBurnIn)
                    .accessibilityLabel("Messwerte ins Video einbrennen")
            } header: {
                Text("Aufnahme")
            } footer: {
                Text("Der Ringpuffer hält die letzten Sekunden ständig im Speicher; ein Auslöser sichert sie samt Nachlauf als Clip. Eingebrannte Messwerte liegen fest im Videobild und lassen sich nachträglich nicht entfernen.")
            }

            Section {
                Toggle("Automatisch in Fotos sichern", isOn: $photosExport)
                    .accessibilityLabel("Automatisch in die Fotomediathek sichern")
            } header: {
                Text("Fotomediathek")
            } footer: {
                Text("Jede Aufnahme landet zusätzlich im Album „HV-Capture“ der Fotos-App. Ausgeschaltet bleibt alles nur in der App-Galerie — teilen geht von dort trotzdem.")
            }
        }
        .navigationTitle("Aufnahme")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Auslöser

struct TriggerSettingsView: View {
    @AppStorage("triggerAuto") private var triggerAuto = false
    @AppStorage("triggerBrightness") private var triggerBrightness = true
    @AppStorage("triggerCurrent") private var triggerCurrent = true
    @AppStorage("triggerAudio") private var triggerAudio = false

    var body: some View {
        List {
            Section {
                Toggle("Automatik", isOn: $triggerAuto)
                    .accessibilityLabel("Auslöser-Automatik")
            } footer: {
                Text(triggerAuto ? "Automatik aktiv — alle Auslöser sind aktiv."
                                 : "Automatik aus — die Auslöser unten gelten einzeln.")
            }

            Section {
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
            } header: {
                Text("Quellen")
            } footer: {
                Text("Helligkeit: das Aufblitzen des Bogens im Bild. Strom: ein deutlicher Leistungssprung an der Dose. Knall: das Zündgeräusch im Mikrofon. Jeder Auslöser sichert im Bogen-Modus auch die Sekunden davor.")
            }
        }
        .navigationTitle("Auslöser")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Design

struct DesignSettingsView: View {
    @AppStorage("accentColor") private var accentColor = "lichtbogen"
    @AppStorage("themeChoice") private var themeChoice = "karbon"
    @AppStorage("liveThemeEnabled") private var liveThemeEnabled = true
    @AppStorage("liveThemeMaxWatts") private var liveThemeMaxWatts = 2000.0
    @AppStorage("bootAnimationEnabled") private var bootAnimationEnabled = true
    @AppStorage("hapticsEnabled") private var hapticsEnabled = true

    var body: some View {
        List {
            Section("Farben") {
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
            }

            Section {
                Toggle("Live-Theme", isOn: $liveThemeEnabled)
                    .accessibilityLabel("Live-Theme")

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
            } header: {
                Text("Live-Theme")
            } footer: {
                Text("Die Oberfläche folgt der Momentanleistung: je mehr Watt, desto weiter glüht der Akzent Richtung Weissglut.")
            }

            Section("Verhalten") {
                Toggle("Startanimation", isOn: $bootAnimationEnabled)
                    .accessibilityLabel("Startanimation")
                Toggle("Haptik", isOn: $hapticsEnabled)
                    .accessibilityLabel("Haptik")
            }
        }
        .navigationTitle("Design")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Sprache

struct LanguageSettingsView: View {
    @AppStorage("appLanguage") private var appLanguage = "de"

    var body: some View {
        List {
            Section {
                Picker("Sprache", selection: $appLanguage) {
                    Text("Deutsch").tag("de")
                    Text("English").tag("en")
                    Text("Wie das System").tag("system")
                }
                .pickerStyle(.inline)
                .labelsHidden()
                .accessibilityLabel("App-Sprache")
            } footer: {
                Text("Gilt ab dem nächsten Start der App. Deutsch ist die Referenz und vollständig; die englische Übersetzung deckt noch nicht jede Ansicht ab. „Wie das System“ kann auf einem englischen iPhone deshalb gemischt wirken.")
            }
        }
        .navigationTitle("Sprache")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Elektrode

struct ElectrodeSettingsView: View {
    @State private var store = SessionStore.shared
    @AppStorage("electrodeName") private var electrodeName = "Standard"

    var body: some View {
        List {
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
        .navigationTitle("Elektrode")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Daten

struct DataSettingsView: View {
    @State private var store = SessionStore.shared
    @State private var backupURL: URL?
    @State private var showImporter = false
    @State private var backupMessage: String?

    var body: some View {
        List {
            Section {
                Button {
                    do {
                        backupURL = try store.exportBackup()
                    } catch {
                        backupMessage = "Backup fehlgeschlagen: \(error.localizedDescription)"
                    }
                } label: {
                    Label("Backup erstellen", systemImage: "arrow.up.doc")
                }
                .accessibilityLabel("Backup erstellen")
                if let backupURL {
                    ShareLink(item: backupURL) {
                        Label("Backup teilen / sichern", systemImage: "square.and.arrow.up")
                    }
                }
                Button {
                    showImporter = true
                } label: {
                    Label("Backup wiederherstellen", systemImage: "arrow.down.doc")
                }
                .accessibilityLabel("Backup wiederherstellen")
            } header: {
                Text("Backup")
            } footer: {
                Text("Sichert alle Sessions und Einstellungen in eine Datei — zum Teilen, in die Cloud legen oder auf ein neues iPhone ziehen. Beim Wiederherstellen werden nur fehlende Sessions ergänzt, vorhandene bleiben.")
            }
        }
        .navigationTitle("Backup & Wiederherstellen")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: [.json]) { result in
            switch result {
            case .success(let url):
                do {
                    let added = try store.importBackup(from: url)
                    backupMessage = "Backup eingelesen — \(added) neue Session\(added == 1 ? "" : "s")."
                    Haptics.success()
                } catch {
                    backupMessage = "Backup konnte nicht gelesen werden: \(error.localizedDescription)"
                    Haptics.error()
                }
            case .failure(let error):
                backupMessage = error.localizedDescription
            }
        }
        .alert("Backup", isPresented: Binding(get: { backupMessage != nil },
                                              set: { if !$0 { backupMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(backupMessage ?? "")
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
    @AppStorage("devModeUnlocked") private var devUnlocked = false
    @State private var selfCheckResult: String?

    var body: some View {
        List {
            simulationSection
            ratesSection
            commandsSection
            rawSection
            selfCheckSection
            storageSection
            leaveSection
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
            Text("Synthetische Messreihen statt echter HTTP-Abfragen — damit lassen sich Auswertung und Oberfläche ohne angeschlossene Hardware prüfen. Solange der Entwicklermodus aktiv ist, lässt sich die Start-Checkliste überspringen.")
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
                selfCheckResult = RecorderSelfCheck.run() + "\n" + RigPlanSelfCheck.run()
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

    private var leaveSection: some View {
        Section {
            Button("Entwicklermodus deaktivieren", role: .destructive) {
                devUnlocked = false
                Haptics.warning()
            }
            .accessibilityLabel("Entwicklermodus deaktivieren")
        } footer: {
            Text("Danach verschwinden diese Ansicht und der Überspringen-Knopf der Start-Checkliste wieder; freischalten geht erneut über 10 Tipps auf die Versionszeile.")
        }
    }
}
