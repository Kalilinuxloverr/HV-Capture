//
//  WatchBridge.swift — Gegenstelle der Uhr auf dem iPhone.
//
//  Die Uhr schaltet nicht selbst: sie schickt einen Befehl ans iPhone, und das
//  iPhone führt ihn über denselben Weg aus wie jeden anderen Not-Aus. So bleibt
//  es bei genau einer Stelle, die schaltet.
//
//  Nützlich ist das, weil das iPhone während einer Aufnahme am Stativ steht und
//  die Hände am Aufbau sind.
//

import Foundation
import WatchConnectivity

/// Schlüssel des Zustands-Kontexts zwischen iPhone und Uhr.
enum WatchKey {
    static let watts = "w"
    static let amps = "a"
    static let armed = "armed"
    static let remaining = "rest"
    static let command = "cmd"
    static let off = "off"
}

@MainActor
@Observable
final class WatchBridge: NSObject {
    static let shared = WatchBridge()

    private(set) var lastCommand: Date?

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Zustand an die Uhr spiegeln. Bewusst über `updateApplicationContext`:
    /// das überschreibt immer den letzten Stand, statt eine Warteschlange
    /// aufzubauen, die bei wiederkehrender Verbindung veraltete Werte nachliefert.
    func push(watts: Double?, amps: Double?, armed: Bool, remaining: Int?) {
        guard WCSession.isSupported(),
              WCSession.default.activationState == .activated else { return }
        var payload: [String: Any] = [WatchKey.armed: armed]
        if let watts { payload[WatchKey.watts] = watts }
        if let amps { payload[WatchKey.amps] = amps }
        if let remaining { payload[WatchKey.remaining] = remaining }
        try? WCSession.default.updateApplicationContext(payload)
    }
}

extension WatchBridge: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {}

    nonisolated func sessionDidBecomeInactive(_ session: WCSession) {}

    nonisolated func sessionDidDeactivate(_ session: WCSession) {
        session.activate()
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        guard message[WatchKey.command] as? String == WatchKey.off else { return }
        Task { @MainActor in
            WatchBridge.shared.lastCommand = Date()
            await ArcController.shared.emergencyOff()
        }
    }
}
