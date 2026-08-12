//
//  GeigerClick.swift — hörbare Leistung: je mehr Watt, desto schneller klickt es.
//
//  Beim Bogenziehen schaut man auf den Bogen, nicht aufs Display. Das Klicken
//  macht die Momentanleistung nebenbei hörbar — wie ein Geigerzähler. Läuft
//  nur, solange scharfgeschaltet ist, und mischt sich leise unter andere Audio-
//  quellen statt sie zu verdrängen.
//

import AVFoundation
import Foundation

@MainActor
final class GeigerClick {
    static let shared = GeigerClick()

    private var player: AVAudioPlayer?
    private var task: Task<Void, Never>?
    private var watts: Double = 0

    private var enabled: Bool { UserDefaults.standard.bool(forKey: "geigerEnabled") }

    /// Volle Klickrate bei derselben Marke wie die volle Glut des Live-Themes —
    /// eine Skala für Auge und Ohr.
    private var maxWatts: Double {
        Swift.max(UserDefaults.standard.object(forKey: "liveThemeMaxWatts") as? Double ?? 2000, 100)
    }

    private init() {}

    /// Wird vom Messwertstrom gefüttert (nur solange scharf).
    func feed(watts w: Double?) {
        guard enabled else { stop(); return }
        watts = w ?? 0
        guard task == nil else { return }
        ensurePlayer()
        task = Task { [weak self] in
            while let self, !Task.isCancelled {
                let w = self.watts
                // 1…25 Klicks pro Sekunde; unterhalb der Ruhelast bleibt es still.
                let rate = 1 + Swift.min(w, self.maxWatts) / self.maxWatts * 24
                if w > 5 { self.click() }
                try? await Task.sleep(for: .milliseconds(Int(1000 / rate)))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        watts = 0
    }

    private func click() {
        guard let player else { return }
        player.currentTime = 0
        player.play()
    }

    private func ensurePlayer() {
        guard player == nil else { return }
        do {
            // mixWithOthers: das Klicken soll Musik oder Video nicht wegducken.
            try AVAudioSession.sharedInstance()
                .setCategory(.playback, options: [.mixWithOthers])
            try AVAudioSession.sharedInstance().setActive(true)
            let p = try AVAudioPlayer(data: Self.clickWAV())
            p.volume = 0.6
            p.prepareToPlay()
            player = p
        } catch {
            // Ton ist Komfort — ohne ihn bleibt die Anzeige.
        }
    }

    /// Sehr kurzer Knack: ein paar Millisekunden abklingendes Rauschen.
    private static func clickWAV() -> Data {
        let rate = 22_050
        let frames = rate / 100                        // 10 ms
        var seed: UInt64 = 0x9E3779B97F4A7C15
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            let noise = Double(Int64(bitPattern: seed) % 1000) / 1000
            let envelope = 1 - Double(i) / Double(frames)   // linear ausklingen
            samples[i] = Int16(noise * envelope * 0.8 * Double(Int16.max))
        }
        return AlarmSound.wav(samples, sampleRate: rate)
    }
}
