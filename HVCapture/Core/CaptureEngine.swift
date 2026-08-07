//
//  CaptureEngine.swift — Kamera mit Ringpuffer und automatischen Auslösern.
//
//  Das Motiv ist ein sehr heller, sehr kurzer Lichtbogen. Zwei Konsequenzen
//  bestimmen den Aufbau: Erstens läuft das Bild dauerhaft in einen Ringpuffer,
//  damit ein Auslöser auch die Sekunden VOR dem Ereignis sichern kann — sonst
//  ist alles vorbei, bevor der Finger den Knopf trifft. Zweitens ist die
//  Belichtung standardmässig manuell, weil jede Automatik am Bogen überstrahlt.
//

import AVFoundation
import Accelerate
import CoreMedia
import Photos
import SwiftUI
import UIKit

// MARK: - Modi

enum CaptureMode: String, CaseIterable, Identifiable {
    case photo, video, slowMotion
    var id: String { rawValue }

    var label: String {
        switch self {
        case .photo: return "Foto"
        case .video: return "Video"
        case .slowMotion: return "Zeitlupe"
        }
    }

    var symbol: String {
        switch self {
        case .photo: return "camera.fill"
        case .video: return "video.fill"
        case .slowMotion: return "slowmo"
        }
    }
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
    static let exposureDuration = 1.0 / 1000
    static let exposureISO = 50.0
    static let albumName = "HV-Capture"
    /// Sperrzeit nach einem Auslöser — ein Ereignis soll einmal gesichert
    /// werden, nicht zehnmal.
    static let triggerCooldown = 1.5
    /// Zeitlupe wird geschrieben, als wären es 30 fps.
    static let slowMotionPlaybackFPS = 30.0
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
    private(set) var bufferedSeconds: Double = 0
    private(set) var audioLevel: Double = 0
    private(set) var spectrum: [Double] = Array(repeating: 0, count: 16)
    private(set) var currentLuma: Double = 0
    private(set) var lastTrigger: TriggerSource?
    private(set) var isConfigured = false

    let session = AVCaptureSession()
    private let videoOutput = AVCaptureVideoDataOutput()
    private let audioOutput = AVCaptureAudioDataOutput()
    private let photoOutput = AVCapturePhotoOutput()
    private let queue = DispatchQueue(label: "dev.leonfrohlich.hvcapture.capture")

    private var device: AVCaptureDevice?
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var writeStart: CMTime?
    private var writeUntil: CMTime?
    private var outputURL: URL?

    private var ring: [(buffer: CMSampleBuffer, isVideo: Bool)] = []
    private var lumaAverage: Double?
    private var audioAverage: Double?
    private var lastTriggerAt: Date?
    private var lastWatts: Double?
    private var nominalFPS: Double = 30
    /// Streckfaktor der Zeitstempel: bei 240 fps wird der Clip achtfach
    /// gestreckt, sodass er direkt in Zeitlupe abspielt.
    private var slowMotionFactor: Double = 1

    private override init() { super.init() }

    // MARK: Einstellungen

    var mode: CaptureMode {
        get {
            CaptureMode(rawValue: UserDefaults.standard.string(forKey: "captureMode") ?? "")
                ?? .slowMotion
        }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: "captureMode") }
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

    func configure() async {
        guard !isConfigured else { return }

        let camOK = await AVCaptureDevice.requestAccess(for: .video)
        let micOK = await AVCaptureDevice.requestAccess(for: .audio)
        guard camOK else {
            permissionDenied = true
            lastError = "Ohne Kamerazugriff kann nicht aufgenommen werden."
            return
        }
        permissionDenied = false

        session.beginConfiguration()
        session.sessionPreset = .high

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

        if micOK, let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        videoOutput.alwaysDiscardsLateVideoFrames = false
        videoOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String:
                kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        ]
        videoOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        audioOutput.setSampleBufferDelegate(self, queue: queue)
        if session.canAddOutput(audioOutput) { session.addOutput(audioOutput) }

        if session.canAddOutput(photoOutput) { session.addOutput(photoOutput) }

        session.commitConfiguration()

        if mode == .slowMotion { applyHighFrameRate() }
        if (UserDefaults.standard.object(forKey: "manualExposure") as? Bool) ?? true {
            applyArcPreset()
        }
        isConfigured = true
    }

    func start() {
        guard isConfigured, !isRunning else { return }
        isRunning = true
        let s = session
        Task.detached { s.startRunning() }
    }

    func stop() {
        guard isRunning else { return }
        isRunning = false
        let s = session
        Task.detached { s.stopRunning() }
    }

    // MARK: Belichtung

    /// Kurze Zeit, niedriger ISO, Fokus und Weissabgleich fest. Die Werte
    /// werden auf das geklemmt, was das Gerät im aktiven Format wirklich kann —
    /// die reale Kamera hat andere Grenzen, als die Wunschwerte annehmen.
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
        guard isEnabled(source) else { return }
        let now = Date()
        if let last = lastTriggerAt, now.timeIntervalSince(last) < CaptureDefaults.triggerCooldown {
            return
        }
        lastTriggerAt = now
        lastTrigger = source
        Haptics.light()
        saveBuffered(preRoll: ringSeconds, postRoll: postRoll)
    }

    /// Wird vom Messwertstrom gefüttert; ein deutlicher Leistungssprung löst aus.
    func externalPowerSignal(watts: Double?) {
        guard let w = watts else { lastWatts = nil; return }
        defer { lastWatts = w }
        guard let previous = lastWatts, previous > 1 else { return }
        if w > previous * 1.6 { trigger(.current) }
    }

    // MARK: Aufnahme

    func capturePhoto() {
        guard isRunning else { return }
        photoOutput.capturePhoto(with: AVCapturePhotoSettings(), delegate: self)
    }

    func startRecording() {
        guard !isRecording else { return }
        saveBuffered(preRoll: ringSeconds, postRoll: .infinity)
    }

    func stopRecording() {
        finishWriting()
    }

    /// Sichert Vorlauf aus dem Ringpuffer plus die kommenden `postRoll`
    /// Sekunden. `postRoll == .infinity` läuft bis `stopRecording()`.
    func saveBuffered(preRoll: Double, postRoll: Double, tag: String = "arc") {
        guard isRunning, !isRecording else { return }
        isRecording = true
        beginWriting(preRoll: preRoll, postRoll: postRoll, tag: tag)
    }

    // MARK: Schreiben

    private func beginWriting(preRoll: Double, postRoll: Double, tag: String) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hv-\(tag)-\(Int(Date().timeIntervalSince1970)).mov")
        guard let w = try? AVAssetWriter(outputURL: url, fileType: .mov) else {
            lastError = "Aufnahme konnte nicht gestartet werden."
            isRecording = false
            return
        }

        let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 1920,
            AVVideoHeightKey: 1080,
        ])
        vIn.expectsMediaDataInRealTime = true
        if w.canAdd(vIn) { w.add(vIn) }

        let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: [
            AVFormatIDKey: kAudioFormatMPEG4AAC,
            AVNumberOfChannelsKey: 1,
            AVSampleRateKey: 44100,
        ])
        aIn.expectsMediaDataInRealTime = true
        if w.canAdd(aIn) { w.add(aIn) }

        slowMotionFactor = mode == .slowMotion
            ? Swift.max(1, nominalFPS / CaptureDefaults.slowMotionPlaybackFPS)
            : 1

        // Vorlauf: nur die Buffer aus dem Ringpuffer, die jung genug sind.
        let newest = ring.last.map { CMSampleBufferGetPresentationTimeStamp($0.buffer) }
        let preRollStart = newest.map { $0 - CMTime(seconds: preRoll, preferredTimescale: 600) }
        let preRollBuffers = ring.filter { entry in
            guard let s = preRollStart else { return false }
            return CMSampleBufferGetPresentationTimeStamp(entry.buffer) >= s
        }

        guard let first = preRollBuffers.first?.buffer ?? ring.last?.buffer else {
            isRecording = false
            return
        }
        let start = CMSampleBufferGetPresentationTimeStamp(first)
        w.startWriting()
        w.startSession(atSourceTime: start)

        writer = w
        videoInput = vIn
        audioInput = aIn
        outputURL = url
        writeStart = start
        writeUntil = postRoll.isInfinite
            ? nil
            : start + CMTime(seconds: preRoll + postRoll, preferredTimescale: 600)

        for entry in preRollBuffers { append(entry.buffer, isVideo: entry.isVideo) }
    }

    private func append(_ buffer: CMSampleBuffer, isVideo: Bool) {
        guard let w = writer, w.status == .writing, let start = writeStart else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(buffer)

        if let until = writeUntil, pts > until {
            finishWriting()
            return
        }

        // Zeitlupe: Ton weglassen — bei gestreckten Zeitstempeln wäre er unbrauchbar.
        if slowMotionFactor > 1, !isVideo { return }

        guard let input = isVideo ? videoInput : audioInput,
              input.isReadyForMoreMediaData else { return }

        guard slowMotionFactor > 1, isVideo else {
            input.append(buffer)
            return
        }

        let offset = CMTimeMultiplyByFloat64(pts - start, multiplier: slowMotionFactor)
        var timing = CMSampleTimingInfo(
            duration: CMTimeMultiplyByFloat64(CMSampleBufferGetDuration(buffer),
                                              multiplier: slowMotionFactor),
            presentationTimeStamp: start + offset,
            decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                                              sampleBuffer: buffer,
                                              sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing,
                                              sampleBufferOut: &retimed)
        if let retimed { input.append(retimed) }
    }

    private func finishWriting() {
        guard let w = writer, w.status == .writing else { return }
        videoInput?.markAsFinished()
        audioInput?.markAsFinished()
        let url = outputURL
        writer = nil
        videoInput = nil
        audioInput = nil
        writeStart = nil
        writeUntil = nil
        outputURL = nil

        w.finishWriting {
            Task { @MainActor [weak self] in
                self?.isRecording = false
                if let url { await self?.saveVideo(url) }
            }
        }
    }

    // MARK: Mediathek

    private func saveVideo(_ url: URL) async {
        guard await ensurePhotoAccess() else { return }
        do {
            let album = try await Self.album()
            try await PHPhotoLibrary.shared().performChanges {
                guard let req = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
                else { return }
                if let album, let placeholder = req.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            lastSavedName = url.lastPathComponent
            SessionRecorder.shared.addMedia(url.lastPathComponent)
        } catch {
            lastError = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func savePhoto(_ data: Data) async {
        guard await ensurePhotoAccess() else { return }
        do {
            let album = try await Self.album()
            try await PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: data, options: nil)
                if let album, let placeholder = req.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }
            }
            let name = "Foto \(Date().formatted(date: .omitted, time: .standard))"
            lastSavedName = name
            SessionRecorder.shared.addMedia(name)
        } catch {
            lastError = "Sichern fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    private func ensurePhotoAccess() async -> Bool {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else {
            lastError = "Ohne Zugriff auf die Fotomediathek kann nichts gesichert werden."
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

// MARK: - Datenströme

extension CaptureEngine: AVCaptureVideoDataOutputSampleBufferDelegate,
                         AVCaptureAudioDataOutputSampleBufferDelegate {
    nonisolated func captureOutput(_ output: AVCaptureOutput,
                                   didOutput sampleBuffer: CMSampleBuffer,
                                   from connection: AVCaptureConnection) {
        let isVideo = output is AVCaptureVideoDataOutput
        Task { @MainActor [weak self] in
            self?.ingest(sampleBuffer, isVideo: isVideo)
        }
    }

    private func ingest(_ buffer: CMSampleBuffer, isVideo: Bool) {
        ring.append((buffer, isVideo))
        let now = CMSampleBufferGetPresentationTimeStamp(buffer)
        let cutoff = now - CMTime(seconds: ringSeconds, preferredTimescale: 600)
        ring.removeAll { CMSampleBufferGetPresentationTimeStamp($0.buffer) < cutoff }
        if let first = ring.first?.buffer {
            bufferedSeconds = CMTimeGetSeconds(now - CMSampleBufferGetPresentationTimeStamp(first))
        }

        if writer != nil { append(buffer, isVideo: isVideo) }
        if isVideo { analyseLuma(buffer) } else { analyseAudio(buffer) }
    }

    /// Mittlere Helligkeit aus der Luma-Ebene, jede 8. Zeile und Spalte —
    /// jedes Pixel zu lesen kostet bei 240 fps mehr, als die Genauigkeit wert ist.
    private func analyseLuma(_ buffer: CMSampleBuffer) {
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
        currentLuma = luma

        guard let avg = lumaAverage else { lumaAverage = luma; return }
        let delta = UserDefaults.standard.object(forKey: "brightnessDelta") as? Double
            ?? CaptureDefaults.brightnessDelta
        if luma - avg > delta { trigger(.brightness) }
        lumaAverage = avg * 0.9 + luma * 0.1
    }

    private func analyseAudio(_ buffer: CMSampleBuffer) {
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
        audioLevel = Double(rms)

        // Grobes 16-Band-Spektrum: mittlerer Betrag je Block, reicht für die Anzeige.
        let bands = 16
        let per = Swift.max(1, count / bands)
        spectrum = (0..<bands).map { b in
            let lo = b * per, hi = Swift.min(lo + per, count)
            guard lo < hi else { return 0 }
            var m: Float = 0
            floats.withUnsafeBufferPointer { buf in
                vDSP_meamgv(buf.baseAddress! + lo, 1, &m, vDSP_Length(hi - lo))
            }
            return Swift.min(1, Double(m) * 8)
        }

        let level = Double(rms)
        guard let avg = audioAverage else { audioAverage = level; return }
        let delta = UserDefaults.standard.object(forKey: "audioDelta") as? Double
            ?? CaptureDefaults.audioDelta
        if level - avg > delta { trigger(.audio) }
        audioAverage = avg * 0.9 + level * 0.1
    }
}

extension CaptureEngine: AVCapturePhotoCaptureDelegate {
    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                 didFinishProcessingPhoto photo: AVCapturePhoto,
                                 error: Error?) {
        guard error == nil, let data = photo.fileDataRepresentation() else { return }
        Task { @MainActor [weak self] in await self?.savePhoto(data) }
    }
}

// MARK: - Sucher

struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    func makeUIView(context: Context) -> PreviewView {
        let v = PreviewView()
        v.previewLayer.session = session
        v.previewLayer.videoGravity = .resizeAspectFill
        return v
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }
}
