//
//  CaptureEngine.swift — Kamera mit vier Modi: Foto, normales Video, Bogen-Clip
//  (Ringpuffer + Auslöser) und Zeitlupe.
//
//  Foto und Video laufen wie die System-Kamera über AVCapturePhotoOutput bzw.
//  AVCaptureMovieFileOutput: Hardware-Encoder, Stabilisierung, Autofokus —
//  scharf, flüssig, richtige Ausrichtung, und die CPU bleibt kalt. Nur die
//  Bogen-Modi brauchen den Segment-Ring, weil ein Auslöser auch die Sekunden
//  VOR dem Ereignis sichern können muss. Die Session wird je Modus neu
//  zusammengesetzt — was ein Modus nicht braucht, läuft auch nicht mit.
//

import AVFoundation
import Accelerate
import CoreMedia
import Photos
import SwiftUI
import UIKit

// MARK: - Modi

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, video, arc, slowMotion
    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "Foto"
        case .video: return "Video"
        case .arc: return "Bogen"
        case .slowMotion: return "Zeitlupe"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "camera.fill"
        case .video: return "video.fill"
        case .arc: return "bolt.circle.fill"
        case .slowMotion: return "slowmo"
        }
    }

    /// Bogen und Zeitlupe puffern über den Segment-Ring und kennen Auslöser
    /// mit Vorlauf; Foto und Video verhalten sich wie die System-Kamera.
    var usesRing: Bool { self == .arc || self == .slowMotion }
}

enum TriggerSource: String, CaseIterable, Identifiable {
    case manual, brightness, current, audio
    var id: String { rawValue }

    var label: String {
        switch self {
        case .manual: return "Hand"
        case .brightness: return "Helligkeit"
        case .current: return "Strom"
        case .audio: return "Ton"
        }
    }

    var symbol: String {
        switch self {
        case .manual: return "hand.tap.fill"
        case .brightness: return "sun.max.fill"
        case .current: return "bolt.fill"
        case .audio: return "waveform"
        }
    }
}

// MARK: - Voreinstellungen

private enum CaptureDefaults {
    static let ringBufferSeconds = 5.0
    static let ringBufferRange = 2.0...10.0
    static let postRollSeconds = 3.0
    static let brightnessDelta = 0.18
    static let audioDelta = 0.25
    // Bogen-Belichtung ist Opt-in (Knopf im Sucher), nicht Standard: Automatik
    // liefert nachts die brauchbaren Videos (Szene + Bogen).
    static let exposureDuration = 1.0 / 250
    static let exposureISO = 200.0
    static let albumName = "HV-Capture"
    /// Sperrzeit nach einem Auslöser — ein Ereignis soll einmal gesichert
    /// werden, nicht zehnmal.
    static let triggerCooldown = 1.5
    /// Zeitlupe wird geschrieben, als wären es 30 fps.
    static let slowMotionPlaybackFPS = 30.0
    static let maxZoom = 8.0
}

// MARK: - Engine

@MainActor
@Observable
final class CaptureEngine: NSObject {
    static let shared = CaptureEngine()

    private(set) var isRunning = false
    private(set) var isRecording = false
    private(set) var permissionDenied = false
    private(set) var lastError: String?
    private(set) var lastSavedName: String?
    /// Letzte Aufnahme für die Vorschau im Sucher — es ist immer nur eines
    /// von beiden gesetzt (Clip oder Foto, das jeweils neuere).
    private(set) var lastClipURL: URL?
    private(set) var lastPhoto: UIImage?
    private(set) var bufferedSeconds: Double = 0
    private(set) var recordingSeconds: Double = 0
    private(set) var audioLevel: Double = 0
    private(set) var spectrum: [Double] = Array(repeating: 0, count: 16)
    private(set) var currentLuma: Double = 0
    private(set) var lastTrigger: TriggerSource?
    private(set) var isConfigured = false
    private(set) var zoomFactor: Double = 1
    private(set) var torchOn = false
    /// Hinweis, sobald das Gerät thermisch drosselt; bei kritischer Hitze
    /// stoppt die Kamera ganz — das iPhone soll nie wegen der App kochen.
    private(set) var thermalWarning: String?

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let movieOutput = AVCaptureMovieFileOutput()
    private let queue = DispatchQueue(label: "dev.leonfrohlich.hvcapture.capture")

    private var device: AVCaptureDevice?
    private var micAllowed = false
    private var lastTriggerAt: Date?
    private var lastWatts: Double?
    private var nominalFPS: Double = 30
    /// Modus, für den die Session gerade zusammengesetzt ist.
    private var configuredMode: CaptureMode?
    /// Rotationswinkel der Aufnahme in Grad (90 = Hochformat).
    private var rotationAngle: Double = 90
    private var recordingTimer: Task<Void, Never>?
    private var autoStopTask: Task<Void, Never>?
    private var thermalObserver: NSObjectProtocol?

    /// Zustand, der ausschliesslich auf der Capture-Queue lebt: der Segment-Ring
    /// und die Auslöser-Analyse.
    private final class QueueState: @unchecked Sendable {
        var ring: SegmentRing?
        var lumaAverage: Double?
        var audioAverage: Double?
        var videoFrameCount = 0
        var audioFrameCount = 0
    }
    private let q = QueueState()

    private override init() { super.init() }

    // MARK: Einstellungen

    var mode: CaptureMode {
        get {
            CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "")
                ?? .arc
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "captureMode") }
    }

    /// „clip" (uralt) und „video" (bis 1.0 der Ringpuffer-Modus) heissen jetzt
    /// „arc" — Video ist seither der normale System-Kamera-Modus.
    private func migrateModeKey() {
        let d = UserDefaults.standard
        let raw = d.string(forKey: "captureMode")
        if raw == "clip" || (raw == "video" && !d.bool(forKey: "modeMigratedToArc")) {
            d.set(CaptureMode.arc.rawValue, forKey: "captureMode")
        }
        d.set(true, forKey: "modeMigratedToArc")
    }

    var ringSeconds: Double {
        let v = UserDefaults.standard.object(forKey: "ringBufferSeconds") as? Double
            ?? CaptureDefaults.ringBufferSeconds
        return Swift.min(Swift.max(v, CaptureDefaults.ringBufferRange.lowerBound),
                         CaptureDefaults.ringBufferRange.upperBound)
    }

    var postRoll: Double {
        UserDefaults.standard.object(forKey: "postRollSeconds") as? Double
            ?? CaptureDefaults.postRollSeconds
    }

    private var wants4K: Bool {
        UserDefaults.standard.string(forKey: "videoQuality") == "4k"
    }

    private var autoAll: Bool { UserDefaults.standard.bool(forKey: "triggerAuto") }

    func isEnabled(_ source: TriggerSource) -> Bool {
        if autoAll { return true }
        switch source {
        case .manual: return true
        case .brightness: return (UserDefaults.standard.object(forKey: "triggerBrightness") as? Bool) ?? true
        case .current: return (UserDefaults.standard.object(forKey: "triggerCurrent") as? Bool) ?? true
        case .audio: return UserDefaults.standard.bool(forKey: "triggerAudio")
        }
    }

    // MARK: Aufbau

    /// Setzt die Session für den aktuellen Modus zusammen. Mehrfach aufrufbar —
    /// ein Moduswechsel im Sucher ruft genau das hier erneut.
    func configure() async {
        if !isConfigured {
            migrateModeKey()
            let camOK = await AVCaptureDevice.requestAccess(for: .video)
            micAllowed = await AVCaptureDevice.requestAccess(for: .audio)
            guard camOK else {
                permissionDenied = true
                lastError = "Ohne Kamerazugriff kann nicht aufgenommen werden."
                return
            }
            permissionDenied = false
            startThermalWatch()
        }

        let m = mode
        guard m != configuredMode else { return }
        if isRecording { stopRecording() }

        session.beginConfiguration()

        if session.inputs.isEmpty {
            guard let cam = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
                  let input = try? AVCaptureDeviceInput(device: cam),
                  session.canAddInput(input)
            else {
                session.commitConfiguration()
                lastError = "Keine nutzbare Kamera gefunden."
                return
            }
            session.addInput(input)
            device = cam
            if micAllowed, let mic = AVCaptureDevice.default(for: .audio),
               let micInput = try? AVCaptureDeviceInput(device: mic),
               session.canAddInput(micInput) {
                session.addInput(micInput)
            }
        }

        // Ausgänge je Modus frisch — was der Modus nicht braucht, kostet sonst
        // nur Strom und Wärme (die Frame-Analyse lief früher IMMER mit).
        for output in session.outputs { session.removeOutput(output) }
        q.ring = nil

        switch m {
        case .photo:
            session.sessionPreset = .photo
            if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }
            photoOutput.maxPhotoQualityPrioritization = .quality
            // Helligkeits-Auslöser funktioniert auch für Serienfotos.
            addAnalysisOutputs(audio: false)

        case .video:
            let fourK = AVCaptureSession.Preset.hd4K3840x2160
            session.sessionPreset = wants4K && session.canSetSessionPreset(fourK)
                ? fourK : .hd1920x1080
            if session.canAddOutput(movieOutput) { session.addOutput(movieOutput) }
            configureMovieConnection()

        case .arc, .slowMotion:
            session.sessionPreset = .hd1920x1080
            addAnalysisOutputs(audio: true)
        }

        session.commitConfiguration()

        if m == .slowMotion {
            applyHighFrameRate()
        } else {
            nominalFPS = 30
        }

        // Standard ist Belichtungs-Automatik — die macht nachts brauchbare
        // Videos (Szene + Bogen). Die dunkle Bogen-Belichtung gibt es als
        // Knopf im Sucher, in den Bogen-Modi zusätzlich als Start-Option.
        if m.usesRing,
           (UserDefaults.standard.object(forKey: "manualExposure") as? Bool) ?? false {
            applyArcPreset()
        } else {
            setAutoExposure()
        }

        if m.usesRing {
            let r = SegmentRing(queue: queue)
            r.ringSeconds = ringSeconds
            r.rotationAngle = rotationAngle
            r.slowFactor = m == .slowMotion
                ? Swift.max(1, nominalFPS / CaptureDefaults.slowMotionPlaybackFPS) : 1
            r.onBuffered = { [weak self] seconds in
                Task { @MainActor in self?.bufferedSeconds = seconds }
            }
            r.onFinished = { [weak self] url in
                Task { @MainActor in
                    guard let self else { return }
                    if let url {
                        await self.saveVideo(url)
                    } else {
                        self.lastError = "Clip konnte nicht zusammengesetzt werden."
                    }
                    self.isRecording = false
                }
            }
            q.ring = r
        }

        bufferedSeconds = 0
        zoomFactor = Double(device?.videoZoomFactor ?? 1)
        configuredMode = m
        isConfigured = true
        refreshRotation()
    }

    private func addAnalysisOutputs(audio: Bool) {
        // Späte Frames verwerfen statt aufstauen — ein voller Puffer äussert
        // sich sonst als wachsender Versatz und Ruckeln im Clip.
        videoOutput.alwaysDiscardsLateVideoFrames = true
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }
        if audio {
            audioOutput.setSampleBufferDelegate(self, queue: queue)
            if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }
        }
    }

    private func configureMovieConnection() {
        guard let c = movieOutput.connection(with: .video) else { return }
        if c.isVideoStabilizationSupported { c.preferredVideoStabilizationMode = .auto }
        if movieOutput.availableVideoCodecTypes.contains(.hevc) {
            movieOutput.setOutputSettings([AVVideoCodecKey: AVVideoCodecType.hevc], for: c)
        }
    }

    func start() {
        guard isConfigured, !isRunning else { return }
        isRunning = true
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        guard isRunning else { return }
        if isRecording { stopRecording() }
        if torchOn { toggleTorch() }
        isRunning = false
        let s = session
        Task.detached { s.stopRunning() }
    }

    // MARK: Ausrichtung

    /// Übernimmt die aktuelle Geräte-Ausrichtung in alle Aufnahmewege. Ohne das
    /// landet jedes Hochformat-Video liegend in der Mediathek.
    func refreshRotation() {
        let angle: Double
        switch UIDevice.current.orientation {
        case .portrait: angle = 90
        case .portraitUpsideDown: angle = 270
        case .landscapeLeft: angle = 0
        case .landscapeRight: angle = 180
        default: return   // faceUp/faceDown: letzte bekannte Lage behalten
        }
        rotationAngle = angle
        applyRotation()
    }

    private func applyRotation() {
        let angle = rotationAngle
        for c in [movieOutput.connection(with: .video), photoOutput.connection(with: .video)] {
            if let c, c.isVideoRotationAngleSupported(CGFloat(angle)) {
                c.videoRotationAngle = CGFloat(angle)
            }
        }
        let r = q.ring
        queue.async { r?.rotationAngle = angle }
    }

    // MARK: Thermik

    private func startThermalWatch() {
        updateThermal()
        thermalObserver = NotificationCenter.default.addObserver(
            forName: ProcessInfo.thermalStateDidChangeNotification,
            object: nil, queue: .main
        ) { _ in
            Task { @MainActor in CaptureEngine.shared.updateThermal() }
        }
    }

    private func updateThermal() {
        switch ProcessInfo.processInfo.thermalState {
        case .critical:
            thermalWarning = "iPhone zu heiss — Kamera pausiert, bis es abgekühlt ist."
            stop()
        case .serious:
            thermalWarning = "iPhone wird warm — kürzere Aufnahmen helfen, Zeitlupe meiden auch."
        default:
            thermalWarning = nil
        }
    }

    // MARK: Zoom, Fokus, Licht

    func setZoom(_ factor: Double) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        let limit = Swift.min(CaptureDefaults.maxZoom, Double(d.activeFormat.videoMaxZoomFactor))
        let f = Swift.min(Swift.max(factor, 1), limit)
        d.videoZoomFactor = CGFloat(f)
        zoomFactor = f
    }

    /// Fokus- und Belichtungspunkt auf die angetippte Stelle — die Automatik
    /// arbeitet danach um diesen Punkt herum weiter.
    func focus(at devicePoint: CGPoint) {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if d.isFocusPointOfInterestSupported, d.isFocusModeSupported(.continuousAutoFocus) {
            d.focusPointOfInterest = devicePoint
            d.focusMode = .continuousAutoFocus
        }
        if d.isExposurePointOfInterestSupported,
           d.isExposureModeSupported(.continuousAutoExposure) {
            d.exposurePointOfInterest = devicePoint
            d.exposureMode = .continuousAutoExposure
        }
    }

    func toggleTorch() {
        guard let d = device, d.hasTorch, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        let newValue = !torchOn
        d.torchMode = newValue ? .on : .off
        torchOn = newValue
    }

    // MARK: Belichtung

    /// Kurze Zeit, niedriger ISO, Fokus und Weissabgleich fest. Die Werte
    /// werden auf das geklemmt, was das Gerät im aktiven Format wirklich kann.
    func applyArcPreset() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }

        let wantSeconds = UserDefaults.standard.object(forKey: "exposureDuration") as? Double
            ?? CaptureDefaults.exposureDuration
        let wantISO = UserDefaults.standard.object(forKey: "exposureISO") as? Double
            ?? CaptureDefaults.exposureISO

        let f = d.activeFormat
        let minD = CMTimeGetSeconds(f.minExposureDuration)
        let maxD = CMTimeGetSeconds(f.maxExposureDuration)
        let seconds = Swift.min(Swift.max(wantSeconds, minD), maxD)
        let iso = Swift.min(Swift.max(Float(wantISO), f.minISO), f.maxISO)

        if d.isExposureModeSupported(.custom) {
            d.setExposureModeCustom(duration: CMTime(seconds: seconds, preferredTimescale: 1_000_000),
                                    iso: iso)
        }
        if d.isFocusModeSupported(.locked) { d.focusMode = .locked }
        if d.isWhiteBalanceModeSupported(.locked) { d.whiteBalanceMode = .locked }
    }

    func setAutoExposure() {
        guard let d = device, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        if d.isExposureModeSupported(.continuousAutoExposure) {
            d.exposureMode = .continuousAutoExposure
        }
        if d.isFocusModeSupported(.continuousAutoFocus) { d.focusMode = .continuousAutoFocus }
        if d.isWhiteBalanceModeSupported(.continuousAutoWhiteBalance) {
            d.whiteBalanceMode = .continuousAutoWhiteBalance
        }
    }

    /// Höchste verfügbare Bildrate wählen (240, sonst 120, sonst was da ist).
    func applyHighFrameRate() {
        guard let d = device else { return }
        let best = d.formats
            .compactMap { fmt -> (AVCaptureDevice.Format, Double)? in
                guard let r = fmt.videoSupportedFrameRateRanges
                    .max(by: { $0.maxFrameRate < $1.maxFrameRate }) else { return nil }
                return (fmt, r.maxFrameRate)
            }
            .max { $0.1 < $1.1 }
        guard let (fmt, fps) = best, (try? d.lockForConfiguration()) != nil else { return }
        defer { d.unlockForConfiguration() }
        d.activeFormat = fmt
        let duration = CMTime(value: 1, timescale: CMTimeScale(fps))
        d.activeVideoMinFrameDuration = duration
        d.activeVideoMaxFrameDuration = duration
        nominalFPS = fps
    }

    // MARK: Auslöser

    func trigger(_ source: TriggerSource) {
        guard isEnabled(source), isRunning, !isRecording else { return }
        let now = Date()
        if let last = lastTriggerAt, now.timeIntervalSince(last) < CaptureDefaults.triggerCooldown {
            return
        }
        lastTriggerAt = now
        lastTrigger = source
        Haptics.light()
        switch mode {
        case .photo:
            capturePhoto()
        case .video:
            // Kein Vorlauf möglich (der ist die Domäne des Bogen-Modus) —
            // dafür ein normales Video ab jetzt, ähnlich lang wie ein Clip.
            startRecording()
            let seconds = ringSeconds + postRoll
            autoStopTask = Task { [weak self] in
                try? await Task.sleep(for: .seconds(seconds))
                guard !Task.isCancelled else { return }
                self?.stopRecording()
            }
        case .arc, .slowMotion:
            isRecording = true
            let post = postRoll
            let r = q.ring
            queue.async { r?.beginClip(postRollSeconds: post) }
        }
    }

    /// Wird vom Messwertstrom gefüttert; ein deutlicher Leistungssprung löst aus.
    /// Der Sprungfaktor kommt aus dem Auslöser-Lernen (TriggerTuning) über die
    /// bisherigen Sessions; ohne Lernstand gilt 1,6.
    func externalPowerSignal(watts: Double?) {
        guard let w = watts else { lastWatts = nil; return }
        defer { lastWatts = w }
        guard let previous = lastWatts, previous > 1 else { return }
        let factor = UserDefaults.standard.object(forKey: TriggerTuning.storageKey) as? Double ?? 1.6
        if w > previous * factor { trigger(.current) }
    }

    // MARK: Aufnahme

    func capturePhoto() {
        guard isRunning, session.outputs.contains(photoOutput) else { return }
        let settings = AVCapturePhotoSettings()
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func startRecording() {
        guard isRunning, !isRecording else { return }
        isRecording = true
        switch mode {
        case .video:
            let url = FileManager.default.temporaryDirectory
                .appendingPathComponent("hv-vid-\(UUID().uuidString).mov")
            applyRotation()
            movieOutput.startRecording(to: url, recordingDelegate: self)
            recordingTimer = Task { [weak self] in
                while let self, self.isRecording, !Task.isCancelled {
                    self.recordingSeconds = self.movieOutput.recordedDuration.seconds
                    try? await Task.sleep(for: .milliseconds(500))
                }
            }
        case .arc, .slowMotion:
            // Durchgehende Aufnahme: der Ring wächst bis stopRecording();
            // der Vorlauf aus dem Puffer ist automatisch enthalten.
            let r = q.ring
            queue.async { r?.beginContinuous() }
        case .photo:
            isRecording = false
        }
    }

    func stopRecording() {
        guard isRecording else { return }
        autoStopTask?.cancel()
        autoStopTask = nil
        switch mode {
        case .video:
            movieOutput.stopRecording()   // isRecording endet im Delegate
        case .arc, .slowMotion:
            let r = q.ring
            queue.async { r?.endContinuous() }
        case .photo:
            isRecording = false
        }
    }

    // MARK: Mediathek

    private func saveVideo(_ url: URL) async {
        // Erst in die App-Ablage übernehmen — die Galerie in der App zeigt
        // diese Dateien, unabhängig von der Fotomediathek.
        let stored = CaptureStore.adopt(url) ?? url
        lastClipURL = stored
        lastPhoto = nil
        lastSavedName = stored.lastPathComponent
        SessionRecorder.shared.addMedia(stored.lastPathComponent)

        guard await ensurePhotoAccess() else { return }
        do {
            let album = try? await Self.album()
            try await PHPhotoLibrary.shared().performChanges {
                guard let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: stored)
                else { return }
                if let album, let placeholder = req.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            lastError = "Sichern in der Mediathek fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func savePhoto(_ data: Data) async {
        let stored = CaptureStore.savePhoto(data)
        lastPhoto = UIImage(data: data)
        lastClipURL = nil
        let name = stored?.lastPathComponent
            ?? "Foto \(Date().formatted(date: .omitted, time: .standard))"
        lastSavedName = name
        SessionRecorder.shared.addMedia(name)

        guard await ensurePhotoAccess() else { return }
        do {
            let album = try? await Self.album()
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
                if let album, let placeholder = req.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
        } catch {
            lastError = "Sichern in der Mediathek fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func ensurePhotoAccess() async -> Bool {
        // .readWrite statt .addOnly: album() muss die Mediathek LESEN, um das
        // Album zu finden — mit .addOnly killt TCC die App beim ersten Sichern
        // (real passiert am 10.08., Crash-Report HVCapture-2026-08-10-210845).
        let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        guard status == .authorized || status == .limited else {
            lastError = "Ohne Zugriff auf die Fotomediathek landet nichts im Album — in der App-Galerie liegt die Aufnahme trotzdem."
            return false
        }
        return true
    }

    private static func album() async throws -> PHAssetCollection? {
        let opts = PHFetchOptions()
        opts.predicate = NSPredicate(format: "title = %@", CaptureDefaults.albumName)
        let found = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: opts)
        if let existing = found.firstObject { return existing }

        var id: String?
        try await PHPhotoLibrary.shared().performChanges {
            let req = PHAssetCollectionChangeRequest
                .creationRequestForAssetCollection(withTitle: CaptureDefaults.albumName)
            id = req.placeholderForCreatedAssetCollection.localIdentifier
        }
        guard let id else { return nil }
        return PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [id], options: nil)
            .firstObject
    }

    // MARK: Bestes Einzelbild

    /// Bewertet Helligkeit UND Schärfe. Nur nach Helligkeit zu gehen liefert
    /// meist das überstrahlte, verwaschene Bild — die interessante Struktur des
    /// Bogens steckt in den Kanten.
    func bestFrame(from url: URL) async -> UIImage? {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return nil }
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero

        let total = CMTimeGetSeconds(duration)
        guard total > 0 else { return nil }
        let steps = Swift.max(4, Swift.min(40, Int(total * 10)))

        var bestScore = -1.0
        var bestImage: UIImage?
        for i in 0..<steps {
            let t = CMTime(seconds: total * Double(i) / Double(steps), preferredTimescale: 600)
            guard let cg = try? await generator.image(at: t).image else { continue }
            let score = Self.score(cg)
            if score > bestScore {
                bestScore = score
                bestImage = UIImage(cgImage: cg)
            }
        }
        return bestImage
    }

    /// Helligkeit mal Kantenmass, beides grob auf einem verkleinerten Raster.
    private static func score(_ image: CGImage) -> Double {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn: Bool = pixels.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h,
                                      bitsPerComponent: 8, bytesPerRow: w,
                                      space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue)
            else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard drawn else { return 0 }

        var sum = 0.0, edges = 0.0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Double(pixels[y * w + x])
                sum += c
                edges += abs(c - Double(pixels[y * w + x + 1]))
                    + abs(c - Double(pixels[(y + 1) * w + x]))
            }
        }
        let brightness = sum / Double(w * h) / 255
        let sharpness = edges / Double(w * h) / 255
        return brightness * sharpness
    }
}

// MARK: - Normales Video (MovieFileOutput)

extension CaptureEngine: AVCaptureFileOutputRecordingDelegate {
    nonisolated func fileOutput(_ output: AVCaptureFileOutput,
                                didFinishRecordingTo outputFileURL: URL,
                                from connections: [AVCaptureConnection],
                                error: Error?) {
        // „Fehler" kann auch nur das reguläre Ende melden — massgeblich ist,
        // ob die Datei fertig geschrieben wurde.
        let finished = error == nil
            || ((error as NSError?)?.userInfo[AVErrorRecordingSuccessfullyFinishedKey] as? Bool ?? false)
        let text = error?.localizedDescription
        Task { @MainActor in
            let engine = CaptureEngine.shared
            engine.recordingTimer?.cancel()
            engine.recordingTimer = nil
            engine.isRecording = false
            engine.recordingSeconds = 0
            if finished {
                await engine.saveVideo(outputFileURL)
            } else {
                engine.lastError = "Video fehlgeschlagen: \(text ?? "unbekannt")"
            }
        }
    }
}

// MARK: - Datenströme (Bogen-Modi und Foto-Auslöser)

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        // Läuft direkt auf der Capture-Queue. Der Buffer wird sofort ins
        // laufende Segment geschrieben und dem Treiber zurückgegeben — nie
        // aufbewahrt (deren Pool ist klein; leer = eingefrorener Sucher).
        let isVideo = output is AVCaptureVideoDataOutput
        q.ring?.ingest(sampleBuffer, isVideo: isVideo)
        if isVideo { analyseLuma(sampleBuffer) } else { analyseAudio(sampleBuffer) }
    }

    /// Mittlere Helligkeit aus der Luma-Ebene, jede 8. Zeile und Spalte —
    /// jedes Pixel zu lesen kostet bei 240 fps mehr, als die Genauigkeit wert ist.
    nonisolated private func analyseLuma(_ buffer: CMSampleBuffer) {
        guard let px = CMSampleBufferGetImageBuffer(buffer) else { return }
        CVPixelBufferLockBaseAddress(px, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(px, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(px, 0) else { return }

        let width = CVPixelBufferGetWidthOfPlane(px, 0)
        let height = CVPixelBufferGetHeightOfPlane(px, 0)
        let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(px, 0)
        let ptr = base.assumingMemoryBound(to: UInt8.self)

        var sum = 0, count = 0
        for y in Swift.stride(from: 0, to: height, by: 8) {
            for x in Swift.stride(from: 0, to: width, by: 8) {
                sum += Int(ptr[y * bytesPerRow + x])
                count += 1
            }
        }
        guard count > 0 else { return }
        let luma = Double(sum) / Double(count) / 255

        // Publizieren gedrosselt — pro Frame auf den MainActor zu springen
        // würde SwiftUI bei 240 fps ersticken.
        q.videoFrameCount += 1
        if q.videoFrameCount % 6 == 0 {
            Task { @MainActor [weak self] in self?.currentLuma = luma }
        }

        guard let avg = q.lumaAverage else { q.lumaAverage = luma; return }
        let delta = UserDefaults.standard.object(forKey: "brightnessDelta") as? Double
            ?? CaptureDefaults.brightnessDelta
        if luma - avg > delta {
            Task { @MainActor [weak self] in self?.trigger(.brightness) }
        }
        q.lumaAverage = avg * 0.9 + luma * 0.1
    }

    nonisolated private func analyseAudio(_ buffer: CMSampleBuffer) {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { return }
        var length = 0
        var pointer: UnsafeMutablePointer<Int8>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil,
                                          totalLengthOut: &length,
                                          dataPointerOut: &pointer) == noErr,
              let pointer, length > MemoryLayout<Int16>.size else { return }

        let count = length / MemoryLayout<Int16>.size
        var floats = [Float](repeating: 0, count: count)
        UnsafeRawPointer(pointer).withMemoryRebound(to: Int16.self, capacity: count) { src in
            vDSP_vflt16(src, 1, &floats, 1, vDSP_Length(count))
        }
        var scale = Float(Int16.max)
        vDSP_vsdiv(floats, 1, &scale, &floats, 1, vDSP_Length(count))

        var rms: Float = 0
        vDSP_rmsqv(floats, 1, &rms, vDSP_Length(count))
        let level = Double(rms)

        // Grobes 16-Band-Spektrum: mittlerer Betrag je Block, reicht für die Anzeige.
        let bands = 16
        let per = Swift.max(1, count / bands)
        let newSpectrum = (0..<bands).map { b -> Double in
            let lo = b * per, hi = Swift.min(lo + per, count)
            guard lo < hi else { return 0 }
            var m: Float = 0
            floats.withUnsafeBufferPointer { buf in
                vDSP_meamgv(buf.baseAddress! + lo, 1, &m, vDSP_Length(hi - lo))
            }
            return Swift.min(1, Double(m) * 8)
        }

        q.audioFrameCount += 1
        if q.audioFrameCount % 4 == 0 {
            Task { @MainActor [weak self] in
                self?.audioLevel = level
                self?.spectrum = newSpectrum
            }
        }

        guard let avg = q.audioAverage else { q.audioAverage = level; return }
        let delta = UserDefaults.standard.object(forKey: "audioDelta") as? Double
            ?? CaptureDefaults.audioDelta
        if level - avg > delta {
            Task { @MainActor [weak self] in self?.trigger(.audio) }
        }
        q.audioAverage = avg * 0.9 + level * 0.1
    }
}

extension CaptureEngine: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        // Fehler sichtbar machen statt still zu schlucken — „Fotos gehen nicht"
        // war sonst nicht diagnostizierbar.
        if let error {
            let text = error.localizedDescription
            Task { @MainActor [weak self] in self?.lastError = "Foto fehlgeschlagen: \(text)" }
            return
        }
        guard let data = photo.fileDataRepresentation() else {
            Task { @MainActor [weak self] in self?.lastError = "Foto ohne Bilddaten." }
            return
        }
        Task { @MainActor [weak self] in await self?.savePhoto(data) }
    }
}

// MARK: - Segment-Ring

/// Ringpuffer aus fertig kodierten ~1-s-Segmentdateien statt roher Kamerabuffer.
///
/// AVCaptureVideoDataOutput vergibt seine Buffer aus einem kleinen festen Pool.
/// Wer sie sekundenlang aufhebt (der alte Ringpuffer), leert den Pool — die
/// Kamera liefert dann keine Bilder mehr: eingefrorener Sucher, tote Auslöser.
/// Hier wird jedes Bild sofort ins laufende H.264-Segment geschrieben und der
/// Buffer zurückgegeben; der Ring besteht aus abgeschlossenen Dateien. Ein
/// Auslöser sammelt die behaltenen Segmente plus Nachlauf ein und setzt sie
/// ohne Neukodierung zu einem Clip zusammen; Zeitlupe streckt dabei nur die
/// Zeitachse (scaleTimeRange), ebenfalls ohne Neukodierung.
///
/// Alle Methoden laufen auf der Capture-Queue — darauf stützt sich das
/// @unchecked Sendable: der Zustand ist queue-confined, nicht gelockt.
final class SegmentRing: @unchecked Sendable {
    var ringSeconds: Double = 5
    var slowFactor: Double = 1
    /// Rotations-Metadatum in Grad (90 = Hochformat) — ohne das spielt jeder
    /// Player die Segmente quer ab, weil die Kamera liegend liefert.
    var rotationAngle: Double = 90
    /// Nach jeder Segment-Rotation (~1 Hz): gepufferte Sekunden.
    var onBuffered: ((Double) -> Void)?
    /// Fertiger Clip; nil = nichts zu sichern oder Zusammensetzen fehlgeschlagen.
    var onFinished: ((URL?) -> Void)?

    private let queue: DispatchQueue
    private let segmentSeconds = 1.0
    private var writer: AVAssetWriter?
    private var videoIn: AVAssetWriterInput?
    private var audioIn: AVAssetWriterInput?
    private var segmentStart: CMTime?
    private var lastPTS: CMTime = .invalid
    private var done: [(url: URL, seconds: Double)] = []
    private var clipEnd: CMTime?
    private var continuous = false

    init(queue: DispatchQueue) {
        self.queue = queue
    }

    func ingest(_ buffer: CMSampleBuffer, isVideo: Bool) {
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)
        lastPTS = pts

        if writer == nil {
            guard isVideo else { return }        // Segmente beginnen mit einem Videobild
            startSegment(at: pts, like: buffer)
        }
        if isVideo, let end = clipEnd, pts >= end {
            finishClip()
            return
        }
        if isVideo, let start = segmentStart,
           CMTimeGetSeconds(pts - start) >= segmentSeconds {
            closeSegment()                        // rotieren …
            startSegment(at: pts, like: buffer)   // … und nahtlos weiter
        }
        guard let w = writer, w.status == .writing,
              let input = isVideo ? videoIn : audioIn,
              input.isReadyForMoreMediaData else { return }
        input.append(buffer)
    }

    /// Auslöser: behaltene Segmente + `postRollSeconds` Nachlauf werden ein Clip.
    func beginClip(postRollSeconds: Double) {
        guard clipEnd == nil, !continuous else { return }
        guard lastPTS.isValid else { onFinished?(nil); return }
        clipEnd = lastPTS + CMTime(seconds: postRollSeconds, preferredTimescale: 600)
    }

    /// Durchgehende Aufnahme: Pruning stoppt, der Ring wächst bis `endContinuous()`.
    func beginContinuous() {
        guard !continuous, clipEnd == nil else { return }
        continuous = true
    }

    func endContinuous() {
        guard continuous else { return }
        continuous = false
        finishClip()
    }

    // MARK: Segmente

    private func startSegment(at pts: CMTime, like buffer: CMSampleBuffer) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-seg-\(UUID().uuidString).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else { return }

        // Abmessungen aus dem echten Kamerabild statt fester Annahme — sonst
        // skaliert der Encoder und das Ergebnis wird weich.
        var width = 1920, height = 1080
        if let fd = CMSampleBufferGetFormatDescription(buffer) {
            let dims = CMVideoFormatDescriptionGetDimensions(fd)
            width = Int(dims.width)
            height = Int(dims.height)
        }

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
        ])
        vIn.expectsMediaDataInRealTime = true
        vIn.transform = CGAffineTransform(rotationAngle: rotationAngle * .pi / 180)
        if w.canAdd(vIn) { w.add(vIn) }
        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
        ])
        aIn.expectsMediaDataInRealTime = true
        if w.canAdd(aIn) { w.add(aIn) }
        w.startWriting()
        w.startSession(atSourceTime: pts)
        writer = w
        videoIn = vIn
        audioIn = aIn
        segmentStart = pts
    }

    /// Schliesst das laufende Segment; `then` läuft danach wieder auf der Queue.
    private func closeSegment(then completion: (() -> Void)? = nil) {
        guard let w = writer, let start = segmentStart else { completion?(); return }
        let seconds = lastPTS.isValid ? CMTimeGetSeconds(lastPTS - start) : 0
        let url = w.outputURL
        videoIn?.markAsFinished()
        audioIn?.markAsFinished()
        writer = nil
        videoIn = nil
        audioIn = nil
        segmentStart = nil
        w.finishWriting { [self] in
            queue.async {
                // Rotation ist 1/s, finishWriting braucht Millisekunden —
                // die Reihenfolge in `done` bleibt dadurch chronologisch.
                if w.status == .completed { self.done.append((url, seconds)) }
                self.prune()
                self.onBuffered?(self.done.reduce(0) { $0 + $1.seconds })
                completion?()
            }
        }
    }

    private func prune() {
        guard clipEnd == nil, !continuous else { return }
        var total = done.reduce(0) { $0 + $1.seconds }
        while total > ringSeconds, done.count > 1 {
            let old = done.removeFirst()
            total -= old.seconds
            try? FileManager.default.removeItem(at: old.url)
        }
    }

    private func finishClip() {
        clipEnd = nil
        let factor = slowFactor
        closeSegment { [self] in
            let parts = done
            done = []
            onBuffered?(0)
            guard !parts.isEmpty else { onFinished?(nil); return }
            let finish = onFinished
            Task.detached(priority: .userInitiated) {
                let url = await SegmentRing.assemble(parts.map(\.url), slowFactor: factor)
                for part in parts { try? FileManager.default.removeItem(at: part.url) }
                finish?(url)
            }
        }
    }

    /// Segmente ohne Neukodierung aneinanderhängen. Zeitlupe streckt die
    /// Zeitachse; der Ton entfällt dann — gestreckt wäre er unbrauchbar.
    private static func assemble(_ parts: [URL], slowFactor: Double) async -> URL? {
        let comp = AVMutableComposition()
        guard let vDst = comp.addMutableTrack(withMediaType: .video,
                                              preferredTrackID: kCMPersistentTrackID_Invalid)
        else { return nil }
        let aDst = slowFactor > 1 ? nil
            : comp.addMutableTrack(withMediaType: .audio,
                                   preferredTrackID: kCMPersistentTrackID_Invalid)
        var cursor = CMTime.zero
        var transform = CGAffineTransform.identity
        for url in parts {
            let asset = AVURLAsset(url: url)
            guard let duration = try? await asset.load(.duration),
                  duration.seconds > 0,
                  let video = try? await asset.loadTracks(withMediaType: .video).first
            else { continue }
            if let t = try? await video.load(.preferredTransform) { transform = t }
            let range = CMTimeRange(start: .zero, duration: duration)
            guard (try? vDst.insertTimeRange(range, of: video, at: cursor)) != nil else { continue }
            if let aDst, let audio = try? await asset.loadTracks(withMediaType: .audio).first {
                try? aDst.insertTimeRange(range, of: audio, at: cursor)
            }
            cursor = cursor + duration
        }
        guard cursor.seconds > 0 else { return nil }
        // Die Rotations-Metadaten der Segmente überleben die Composition nicht
        // von allein — ohne das hier wäre der fertige Clip wieder quer.
        vDst.preferredTransform = transform
        if slowFactor > 1 {
            comp.scaleTimeRange(CMTimeRange(start: .zero, duration: cursor),
                                toDuration: CMTimeMultiplyByFloat64(cursor, multiplier: slowFactor))
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-arc-\(Int(Date().timeIntervalSince1970)).mov")
        guard let export = AVAssetExportSession(asset: comp,
                                                presetName: AVAssetExportPresetPassthrough)
        else { return nil }
        do {
            try await export.export(to: out, as: .mov)
            return out
        } catch {
            return nil
        }
    }
}

// MARK: - Sucher

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession
    /// Tipp auf den Sucher: (Gerätepunkt 0…1 für Fokus, Ansichtspunkt für die UI).
    var onTap: ((CGPoint, CGPoint) -> Void)? = nil
    /// Pinch: Skalierung relativ zum Gestenbeginn, `true` = Geste beginnt gerade.
    var onPinch: ((Double, Bool) -> Void)? = nil

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill

        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.tapped(_:)))
        v.addGestureRecognizer(tap)
        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.pinched(_:)))
        v.addGestureRecognizer(pinch)
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {
        context.coordinator.onTap = onTap
        context.coordinator.onPinch = onPinch
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onTap: onTap, onPinch: onPinch)
    }

    final class Coordinator: NSObject {
        var onTap: ((CGPoint, CGPoint) -> Void)?
        var onPinch: ((Double, Bool) -> Void)?

        init(onTap: ((CGPoint, CGPoint) -> Void)?, onPinch: ((Double, Bool) -> Void)?) {
            self.onTap = onTap
            self.onPinch = onPinch
        }

        @objc func tapped(_ g: UITapGestureRecognizer) {
            guard let v = g.view as? PreviewView else { return }
            let point = g.location(in: v)
            let devicePoint = v.previewLayer.captureDevicePointConverted(fromLayerPoint: point)
            onTap?(devicePoint, point)
        }

        @objc func pinched(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: onPinch?(Double(g.scale), true)
            case .changed: onPinch?(Double(g.scale), false)
            default: break
            }
        }
    }

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
