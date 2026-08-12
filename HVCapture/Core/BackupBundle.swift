//
//  BackupBundle.swift — vollständige Sicherung aller Sessions und Einstellungen
//  in einer Datei, und deren Wiederherstellung.
//
//  Eine Datei, die man teilen, in die Cloud legen oder auf ein neues iPhone
//  ziehen kann. Bewusst eine flache JSON-Datei statt eines Archivs: lesbar,
//  ohne Spezialwerkzeug importierbar, versioniert.
//

import Foundation

/// Ein Einstellungswert im Backup — nur die Typen, die in UserDefaults als
/// Skalare liegen. Reicht für alle Schlüssel dieser App.
enum BackupValue: Codable, Equatable {
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)

    var any: Any {
        switch self {
        case .bool(let v): return v
        case .int(let v): return v
        case .double(let v): return v
        case .string(let v): return v
        }
    }

    init?(any: Any) {
        // Reihenfolge zählt: Bool ist in ObjC ein NSNumber, deshalb zuerst.
        switch any {
        case let v as Bool where any is Bool: self = .bool(v)
        case let v as Int: self = .int(v)
        case let v as Double: self = .double(v)
        case let v as String: self = .string(v)
        default: return nil
        }
    }
}

struct BackupBundle: Codable {
    var version = 1
    var exportedAt: Date
    var sessions: [Session]
    var settings: [String: BackupValue]

    /// Diese Schlüssel werden gesichert und wiederhergestellt — die Konfiguration
    /// der App, nicht Wegwerf-Zustand wie der letzte Aufnahme-Modus.
    static let settingsKeys = [
        "plugIP", "pollIntervalMs", "watchdogWindow",
        "accentColor", "themeChoice", "liveThemeEnabled", "liveThemeMaxWatts",
        "guardConfig", "currentJumpFactor",
        "timerSeconds", "pulseOn", "pulseOff", "pulseRepeats",
        "strompreisCt", "electrodeName",
        "rigMotCount", "rigTopology", "rigEmiBoard", "rigBallast",
        "tripNotificationsEnabled", "alarmSoundEnabled", "appLockEnabled",
        "preRollSeconds", "videoQuality",
        "appLanguage", "geigerEnabled", "burstCount", "photosExportEnabled",
        "captureMode", "ringBufferSeconds", "postRollSeconds", "hudBurnIn",
        "triggerAuto", "triggerBrightness", "triggerCurrent", "triggerAudio",
    ]
}

extension SessionStore {
    /// Alles in eine Backup-Datei schreiben und deren URL zurückgeben.
    func exportBackup() throws -> URL {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]

        var settings: [String: BackupValue] = [:]
        for key in BackupBundle.settingsKeys {
            // guardConfig liegt als Data (JSON) — als String sichern, damit es
            // durch die skalare Backup-Form passt.
            if let data = UserDefaults.standard.data(forKey: key) {
                settings[key] = .string(data.base64EncodedString())
            } else if let value = UserDefaults.standard.object(forKey: key),
                      let wrapped = BackupValue(any: value) {
                settings[key] = wrapped
            }
        }

        let bundle = BackupBundle(exportedAt: Date(), sessions: sessions, settings: settings)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("HV-Capture-Backup-\(Self.stamp(Date())).json")
        try encoder.encode(bundle).write(to: url, options: .atomic)
        return url
    }

    /// Backup einlesen: Sessions ergänzen (nach id, vorhandene bleiben) und die
    /// gesicherten Einstellungen zurückschreiben. Gibt die Anzahl neuer Sessions.
    @discardableResult
    func importBackup(from url: URL) throws -> Int {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        // Zugriff auf eine per Dateiauswahl gelieferte URL erfordert die
        // Security-Scope-Klammer, sonst schlägt das Lesen fehl.
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }

        let bundle = try decoder.decode(BackupBundle.self, from: Data(contentsOf: url))

        for (key, value) in bundle.settings {
            if key == "guardConfig", case .string(let b64) = value,
               let data = Data(base64Encoded: b64) {
                UserDefaults.standard.set(data, forKey: key)
            } else {
                UserDefaults.standard.set(value.any, forKey: key)
            }
        }

        let existing = Set(sessions.map(\.id))
        var added = 0
        for session in bundle.sessions where !existing.contains(session.id) {
            save(session)
            added += 1
        }
        return added
    }
}
