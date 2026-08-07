//
//  WatchApp.swift — Not-Aus am Handgelenk.
//
//  Bewusst minimal: ein grosser Aus-Knopf und die aktuelle Leistung. Die Uhr
//  schaltet nicht selbst, sie schickt den Befehl ans iPhone — das führt ihn über
//  denselben Weg aus wie jeden anderen Not-Aus.
//
//  Der Knopf ist auch dann bedienbar, wenn keine Werte ankommen. Ein Befehl, der
//  ins Leere geht, ist harmlos; ein Knopf, der sich sperrt, weil gerade keine
//  Verbindung steht, wäre es nicht.
//

import SwiftUI
import WatchConnectivity
import WatchKit

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
final class WatchState: NSObject {
    static let shared = WatchState()

    private(set) var watts: Double?
    private(set) var amps: Double?
    private(set) var armed = false
    private(set) var remaining: Int?
    private(set) var lastUpdate: Date?
    private(set) var sentAt: Date?

    private override init() { super.init() }

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    /// Not-Aus senden. Mehrfach, weil ein einzelnes verlorenes Paket den Befehl
    /// nicht scheitern lassen darf.
    func sendOff() {
        sentAt = Date()
        guard WCSession.isSupported() else { return }
        for _ in 0..<3 {
            WCSession.default.sendMessage([WatchKey.command: WatchKey.off],
                                          replyHandler: nil, errorHandler: nil)
        }
    }

    /// Kommen seit über zehn Sekunden keine Werte, ist die Anzeige nicht mehr
    /// vertrauenswürdig — dann lieber „—" zeigen als eine veraltete Zahl.
    var isFresh: Bool {
        guard let lastUpdate else { return false }
        return Date().timeIntervalSince(lastUpdate) < 10
    }

    fileprivate func apply(_ context: [String: Any]) {
        watts = context[WatchKey.watts] as? Double
        amps = context[WatchKey.amps] as? Double
        armed = context[WatchKey.armed] as? Bool ?? false
        remaining = context[WatchKey.remaining] as? Int
        lastUpdate = Date()
    }
}

extension WatchState: WCSessionDelegate {
    nonisolated func session(_ session: WCSession,
                             activationDidCompleteWith state: WCSessionActivationState,
                             error: Error?) {
        let context = session.receivedApplicationContext
        Task { @MainActor in WatchState.shared.apply(context) }
    }

    nonisolated func session(_ session: WCSession,
                             didReceiveApplicationContext context: [String: Any]) {
        Task { @MainActor in WatchState.shared.apply(context) }
    }
}

struct WatchRootView: View {
    @State private var state = WatchState.shared

    var body: some View {
        VStack(spacing: 10) {
            header

            Button {
                WKInterfaceDevice.current().play(.failure)
                state.sendOff()
            } label: {
                VStack(spacing: 2) {
                    Image(systemName: "exclamationmark.octagon.fill")
                        .font(.title2)
                    Text("NOT-AUS")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, minHeight: 76)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .accessibilityLabel("Not-Aus, schaltet sofort ab")

            if let sent = state.sentAt {
                Text("Gesendet \(sent.formatted(date: .omitted, time: .standard))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 6)
        .onAppear { state.activate() }
    }

    private var header: some View {
        VStack(spacing: 2) {
            Text(state.isFresh ? valueText(state.watts, "W", 0) : "—")
                .font(.system(size: 30, weight: .bold))
                .monospacedDigit()
                .foregroundStyle(state.armed ? .orange : .secondary)
            HStack(spacing: 8) {
                Text(state.isFresh ? valueText(state.amps, "A", 2) : "—")
                if let r = state.remaining, state.isFresh {
                    Text(r >= 0 ? "\(r) s" : "Pause")
                }
            }
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.secondary)
            Text(state.armed ? "EINGESCHALTET" : "aus")
                .font(.caption2.weight(.bold))
                .foregroundStyle(state.armed ? .orange : .secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private func valueText(_ value: Double?, _ unit: String, _ digits: Int) -> String {
        guard let v = value else { return "— \(unit)" }
        return String(format: "%.\(digits)f %@", v, unit)
    }
}

@main
struct HVCaptureWatchApp: App {
    var body: some Scene {
        WindowGroup {
            WatchRootView()
        }
    }
}
