//
//  AlarmSound.swift — lauter Alarmton bei einer Sicherheitsabschaltung.
//
//  Der Ton wird im Speicher als WAV synthetisiert (kein Asset nötig) und über
//  eine Playback-Audiosession abgespielt — die klingt bewusst auch, wenn der
//  Stummschalter an ist: eine Abschaltung soll man aus Distanz hören.
//

import AVFoundation
import Foundation

@MainActor
enum AlarmSound {
    private static var player: AVAudioPlayer?

    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "alarmSoundEnabled") as? Bool ?? true
    }

    /// Kurze Sirene, dreimal — überschreibt den Stummschalter (Sicherheit vor
    /// Höflichkeit). Läuft ins Leere, wenn der Nutzer den Ton abgeschaltet hat.
    static func play() {
        guard enabled else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, options: [.duckOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: sirenWAV())
            p.numberOfLoops = 2
            p.volume = 1
            p.prepareToPlay()
            p.play()
            player = p
        } catch {
            // Ton ist Komfort — scheitert er, bleibt Haptik und Banner.
        }
    }

    static func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// Ein-Sekunden-Sirene: Ton, der zwischen zwei Frequenzen hin- und herwandert.
    /// 16-bit-PCM, mono, 22 050 Hz — als komplettes WAV mit Header.
    private static func sirenWAV() -> Data {
        let rate = 22_050
        let seconds = 1.0
        let frames = Int(Double(rate) * seconds)
        var samples = [Int16](repeating: 0, count: frames)
        for i in 0..<frames {
            let t = Double(i) / Double(rate)
            // Frequenz pendelt 3× pro Sekunde zwischen 660 und 1320 Hz.
            let freq = 990 + 330 * sin(2 * .pi * 3 * t)
            let phase = 2 * .pi * freq * t
            let envelope = 0.6   // konstant laut, keine Ausblendung
            samples[i] = Int16(sin(phase) * envelope * Double(Int16.max))
        }
        return wav(samples, sampleRate: rate)
    }

    private static func wav(_ samples: [Int16], sampleRate: Int) -> Data {
        let bytesPerSample = 2
        let dataSize = samples.count * bytesPerSample
        var d = Data()
        func str(_ s: String) { d.append(contentsOf: s.utf8) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        str("RIFF"); u32(UInt32(36 + dataSize)); str("WAVE")
        str("fmt "); u32(16); u16(1); u16(1)                    // PCM, mono
        u32(UInt32(sampleRate))
        u32(UInt32(sampleRate * bytesPerSample))                // byte rate
        u16(UInt16(bytesPerSample)); u16(16)                    // block align, bits
        str("data"); u32(UInt32(dataSize))
        for s in samples { var x = s.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        return d
    }
}
