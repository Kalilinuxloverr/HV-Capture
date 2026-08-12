//
//  CameraView.swift — Sucher mit Messwert-HUD, Zoom, Tap-Fokus und Auslösern.
//
//  Die Kamera ist bewusst von der Überwachung entkoppelt: fehlt die
//  Berechtigung oder schlägt der Aufbau fehl, bleibt der Rest der App voll
//  bedienbar. Was hier nicht funktioniert, darf nie den Aufbau blockieren.
//

import AVFoundation
import AVKit
import Combine
import SwiftUI
import UIKit

struct CameraView: View {
    @State private var engine = CaptureEngine.shared
    @State private var plug = PlugLink.shared
    @State private var controller = ArcController.shared

    @AppStorage("captureMode") private var modeKey = CaptureMode.arc.rawValue
    @AppStorage("triggerBrightness") private var triggerBrightness = true
    @AppStorage("triggerCurrent") private var triggerCurrent = true
    @AppStorage("triggerAudio") private var triggerAudio = false
    @AppStorage("triggerAuto") private var triggerAuto = false

    @State private var showPreview = false
    /// Punkt des letzten Fokus-Tipps in Sucher-Koordinaten (für das Reticle).
    @State private var focusPoint: CGPoint?
    @State private var pinchBaseZoom: Double = 1

    private var mode: CaptureMode { CaptureMode(rawValue: modeKey) ?? .arc }

    var body: some View {
        ZStack {
            if engine.permissionDenied {
                deniedState
            } else {
                CameraPreview(session: engine.session,
                              onTap: { device, view in
                                  Haptics.light()
                                  engine.focus(at: device)
                                  withAnimation(.spring(duration: 0.25)) { focusPoint = view }
                                  Task {
                                      try? await Task.sleep(for: .seconds(1))
                                      withAnimation(.easeOut(duration: 0.3)) { focusPoint = nil }
                                  }
                              },
                              onPinch: { scale, began in
                                  if began { pinchBaseZoom = engine.zoomFactor }
                                  engine.setZoom(pinchBaseZoom * scale)
                              })
                    .overlay { reticle }
                    .ignoresSafeArea()
                    .accessibilityHidden(true)
                overlay
            }
        }
        .navigationTitle("Kamera")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                NavigationLink {
                    CapturesView()
                } label: {
                    Image(systemName: "photo.stack")
                }
                .accessibilityLabel("Aufnahmen-Galerie")
            }
        }
        .task {
            // Ohne das liefert UIDevice.orientation nur .unknown und Aufnahmen
            // rotieren nicht mit der Lage.
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            await engine.configure()
            engine.start()
        }
        // Moduswechsel setzt die Session um — nur die Ausgänge des gewählten
        // Modus laufen mit, alles andere kostet Akku und Wärme.
        .onChange(of: modeKey) {
            Task { await engine.configure() }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            engine.refreshRotation()
        }
        .onDisappear {
            engine.stop()
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
        }
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

    // MARK: Fokus-Reticle

    @ViewBuilder
    private var reticle: some View {
        if let p = focusPoint {
            Circle()
                .strokeBorder(Palette.warn, lineWidth: 1.5)
                .frame(width: 76, height: 76)
                .position(p)
                .transition(.scale(scale: 1.4).combined(with: .opacity))
                .allowsHitTesting(false)
        }
    }

    // MARK: Überlagerung

    private var overlay: some View {
        VStack(spacing: 10) {
            if let warn = engine.thermalWarning {
                WarningBanner(text: warn, symbol: "thermometer.high", tint: Palette.warn)
            }
            hud
            Spacer()
            zoomRow
            if mode.usesRing || mode == .photo { triggerRow }
            if mode.usesRing { exposureRow }
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
                if engine.isRecording {
                    RecordingBadge(seconds: mode.usesRing ? engine.bufferedSeconds
                                                          : engine.recordingSeconds)
                }
                if mode.usesRing || mode == .photo { spectrumBars }
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

    // MARK: Zoom und Licht

    private var zoomRow: some View {
        HStack(spacing: 10) {
            ForEach([1.0, 2.0, 4.0], id: \.self) { z in
                let active = abs(engine.zoomFactor - z) < 0.2
                Button(String(format: "%.0f×", z)) {
                    Haptics.light()
                    withAnimation(.snappy) { engine.setZoom(z) }
                }
                .fontWeight(active ? .bold : .regular)
                .foregroundStyle(active ? Palette.accent : .primary)
                .accessibilityLabel("Zoom \(Int(z))-fach")
            }
            if engine.zoomFactor > 1.05 {
                Text(String(format: "%.1f×", engine.zoomFactor))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .transition(.opacity)
            }
            Spacer()
            Button {
                Haptics.light()
                engine.toggleTorch()
            } label: {
                Image(systemName: engine.torchOn ? "flashlight.on.fill" : "flashlight.off.fill")
            }
            .foregroundStyle(engine.torchOn ? Palette.warn : .primary)
            .accessibilityLabel(engine.torchOn ? "Lampe ausschalten" : "Lampe einschalten")
        }
        .font(.caption)
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
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
            if mode.usesRing {
                triggerToggle("Ton", symbol: "waveform", binding: $triggerAudio)
            }
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
        .padding(.vertical, 2)
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
            case .video, .arc, .slowMotion:
                if engine.isRecording { engine.stopRecording() } else { engine.startRecording() }
            }
        } label: {
            ZStack {
                Circle().strokeBorder(.white.opacity(0.85), lineWidth: 4)
                    .frame(width: 74, height: 74)
                if engine.isRecording {
                    RoundedRectangle(cornerRadius: 6).fill(Palette.danger)
                        .frame(width: 30, height: 30)
                        .transition(.scale)
                } else {
                    Circle().fill(mode == .photo ? Color.white : Palette.danger)
                        .frame(width: 58, height: 58)
                        .transition(.scale)
                }
            }
            .animation(.snappy(duration: 0.2), value: engine.isRecording)
        }
        .buttonStyle(ShutterButtonStyle())
        .accessibilityLabel(engine.isRecording ? "Aufnahme beenden" : "Auslösen")
    }

    // MARK: Formatierung

    private func valueText(_ value: Double?, unit: String, digits: Int) -> String {
        guard let v = value else { return "— \(unit)" }
        return String(format: "%.\(digits)f %@", v, unit)
    }
}

// MARK: - Aufnahme-Anzeige

private struct RecordingBadge: View {
    let seconds: Double
    @State private var pulse = false

    private var timeText: String {
        let t = Int(seconds)
        return "\(t / 60):" + String(format: "%02d", t % 60)
    }

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(Palette.danger)
                .frame(width: 8, height: 8)
                .opacity(pulse ? 0.25 : 1)
                .animation(.easeInOut(duration: 0.7).repeatForever(autoreverses: true), value: pulse)
            Text(timeText)
                .font(.caption.monospacedDigit().weight(.semibold))
        }
        .onAppear { pulse = true }
        .accessibilityLabel("Aufnahme läuft, \(timeText)")
    }
}

private struct ShutterButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
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
