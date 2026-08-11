//
//  CameraView.swift — Sucher mit Messwert-HUD und Auslöser-Schaltern.
//
//  Die Kamera ist bewusst von der Überwachung entkoppelt: fehlt die
//  Berechtigung oder schlägt der Aufbau fehl, bleibt der Rest der App voll
//  bedienbar. Was hier nicht funktioniert, darf nie den Aufbau blockieren.
//

import AVFoundation
import AVKit
import SwiftUI
import UIKit

struct CameraView: View {
    @State private var engine = CaptureEngine.shared
    @State private var plug = PlugLink.shared
    @State private var controller = ArcController.shared

    @AppStorage("captureMode") private var modeKey = CaptureMode.video.rawValue
    @AppStorage("triggerBrightness") private var triggerBrightness = true
    @AppStorage("triggerCurrent") private var triggerCurrent = true
    @AppStorage("triggerAudio") private var triggerAudio = false
    @AppStorage("triggerAuto") private var triggerAuto = false

    @State private var showPreview = false

    // Fallback .video fängt auch den alten Einstellungs-Wert „clip" ab —
    // der frühere Fallback auf Zeitlupe hat den Foto-Modus unerreichbar gemacht.
    private var mode: CaptureMode { CaptureMode(rawValue: modeKey) ?? .video }

    var body: some View {
        ZStack {
            if engine.permissionDenied {
                deniedState
            } else {
                CameraPreview(session: engine.session)
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                overlay
            }
        }
        .navigationTitle("Kamera")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            await engine.configure()
            engine.start()
        }
        .onDisappear { engine.stop() }
    }

    // MARK: Fehlender Zugriff

    private var deniedState: some View {
        VStack(spacing: 16) {
            WarningBanner(text: "HV-Capture darf nicht auf die Kamera zugreifen. In den Systemeinstellungen unter Datenschutz freigeben.",
                          symbol: "camera.fill",
                          tint: Palette.warn)
            Text("Überwachung und Protokoll laufen davon unabhängig weiter.")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let url = URL(string: UIApplication.openSettingsURLString) {
                Link("Einstellungen öffnen", destination: url)
                    .buttonStyle(.borderedProminent)
            }
            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .appBackground()
    }

    // MARK: Überlagerung

    private var overlay: some View {
        VStack {
            hud
            Spacer()
            triggerRow
            exposureRow
            controls
        }
        .padding()
    }

    private var hud: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 2) {
                Text(valueText(plug.reading?.watts, unit: "W", digits: 0))
                    .font(.system(size: 34, weight: .bold))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                HStack(spacing: 10) {
                    Text(valueText(plug.reading?.volts, unit: "V", digits: 1))
                    Text(valueText(plug.reading?.amps, unit: "A", digits: 2))
                }
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            .foregroundStyle(LiveTheme.shared.accent)

            Spacer()

            VStack(alignment: .trailing, spacing: 6) {
                if let s = controller.secondsRemaining {
                    Text(s >= 0 ? "\(s) s" : "Pause \(abs(s)) s")
                        .font(.title3.weight(.semibold).monospacedDigit())
                        .foregroundStyle(s >= 0 ? Palette.warn : .secondary)
                }
                spectrumBars
            }
        }
        .padding(12)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Messwerte im Sucher")
    }

    private var spectrumBars: some View {
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(Array(engine.spectrum.enumerated()), id: \.offset) { _, value in
                Capsule()
                    .fill(LiveTheme.shared.accent.opacity(0.8))
                    .frame(width: 3, height: Swift.max(2, value * 26))
            }
        }
        .frame(height: 26)
        .accessibilityHidden(true)
    }

    // MARK: Auslöser

    private var triggerRow: some View {
        HStack(spacing: 8) {
            Toggle("Auto", isOn: $triggerAuto)
                .toggleStyle(.button)
                .tint(Palette.ok)
                .accessibilityLabel("Alle Auslöser zusammen")
            triggerToggle("Helligkeit", symbol: "sun.max.fill", binding: $triggerBrightness)
            triggerToggle("Strom", symbol: "bolt.fill", binding: $triggerCurrent)
            triggerToggle("Ton", symbol: "waveform", binding: $triggerAudio)
        }
        .font(.caption)
        .padding(8)
        .background(.ultraThinMaterial, in: Capsule())
    }

    private func triggerToggle(_ title: String, symbol: String,
                               binding: Binding<Bool>) -> some View {
        Toggle(isOn: binding) {
            Label(title, systemImage: symbol).labelStyle(.iconOnly)
        }
        .toggleStyle(.button)
        .tint(Palette.accent)
        .disabled(triggerAuto)
        .accessibilityLabel("Auslöser \(title)")
    }

    private var exposureRow: some View {
        HStack(spacing: 10) {
            Button("Bogen-Belichtung") { engine.applyArcPreset() }
            Button("Automatik") { engine.setAutoExposure() }
            Spacer()
            Text(String(format: "Puffer %.1f s", engine.bufferedSeconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .font(.caption.weight(.semibold))
        .buttonStyle(.bordered)
        .padding(.vertical, 6)
    }

    // MARK: Bedienung

    private var controls: some View {
        VStack(spacing: 12) {
            Picker("Aufnahmemodus", selection: $modeKey) {
                ForEach(CaptureMode.allCases) { m in
                    Label(m.label, systemImage: m.symbol).tag(m.rawValue)
                }
            }
            .pickerStyle(.segmented)

            HStack {
                if engine.lastClipURL != nil || engine.lastPhoto != nil {
                    Button {
                        Haptics.light()
                        showPreview = true
                    } label: {
                        Label(engine.lastSavedName ?? "Letzte Aufnahme",
                              systemImage: "play.rectangle.fill")
                            .font(.caption2)
                            .lineLimit(1)
                    }
                    .foregroundStyle(Palette.ok)
                    .accessibilityLabel("Letzte Aufnahme ansehen")
                } else if let name = engine.lastSavedName {
                    Label(name, systemImage: "checkmark.circle.fill")
                        .font(.caption2)
                        .foregroundStyle(Palette.ok)
                        .lineLimit(1)
                }
                Spacer()
                shutter
                Spacer()
                if let source = engine.lastTrigger {
                    Label(source.label, systemImage: source.symbol)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .sheet(isPresented: $showPreview) {
                LastCaptureSheet(url: engine.lastClipURL, photo: engine.lastPhoto)
            }

            if let error = engine.lastError {
                Text(error)
                    .font(.caption2)
                    .foregroundStyle(Palette.warn)
                    .multilineTextAlignment(.center)
            }
        }
    }

    private var shutter: some View {
        Button {
            Haptics.tap()
            switch mode {
            case .photo:
                engine.capturePhoto()
            case .video, .slowMotion:
                if engine.isRecording { engine.stopRecording() } else { engine.startRecording() }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 74, height: 74)
                if engine.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.danger)
                        .frame(width: 30, height: 30)
                } else {
                    Circle().fill(mode == .photo ? Color.white : Palette.danger)
                        .frame(width: 58, height: 58)
                }
            }
        }
        .accessibilityLabel(engine.isRecording ? "Aufnahme beenden" : "Auslösen")
    }

    // MARK: Formatierung

    private func valueText(_ value: Double?, unit: String, digits: Int) -> String {
        guard let v = value else { return "— \(unit)" }
        return String(format: "%.\(digits)f %@", v, unit)
    }
}

// MARK: - Vorschau der letzten Aufnahme

private struct LastCaptureSheet: View {
    let url: URL?
    let photo: UIImage?

    var body: some View {
        NavigationStack {
            Group {
                if let url {
                    VideoPlayer(player: AVPlayer(url: url))
                        .ignoresSafeArea(edges: .bottom)
                } else if let photo {
                    Image(uiImage: photo)
                        .resizable()
                        .scaledToFit()
                } else {
                    ContentUnavailableView("Noch keine Aufnahme", systemImage: "camera")
                }
            }
            .navigationTitle("Letzte Aufnahme")
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.large])
    }
}

#Preview {
    NavigationStack { CameraView() }
}
