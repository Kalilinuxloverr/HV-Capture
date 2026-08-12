//
//  ArcIntents.swift — Not-Aus per Siri/Shortcuts und Live-Activity-Steuerung.
//  Gehört nur zum App-Target.
//

import ActivityKit
import AppIntents

// MARK: - Not-Aus

struct EmergencyOffIntent: AppIntent {
    static var title: LocalizedStringResource = "Strom aus"
    static var description = IntentDescription(
        "Schaltet die Steckdose sofort ab — Not-Aus, ohne Rückfrage.")
    /// Muss auch bei gesperrtem Gerät funktionieren, deshalb keine UI.
    static var openAppWhenRun = false

    @MainActor
    func perform() async throws -> some IntentResult & ProvidesDialog {
        await ArcController.shared.emergencyOff()
        return .result(dialog: "Abgeschaltet.")
    }
}

// MARK: - Siri-Phrasen

struct HVShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: EmergencyOffIntent(),
            phrases: [
                "Not-Aus in \(.applicationName)",
                "\(.applicationName) Strom aus",
                "Alles aus in \(.applicationName)",
                "Schalte \(.applicationName) ab",
            ],
            shortTitle: "Strom aus",
            systemImageName: "bolt.slash.fill"
        )
    }
}

// MARK: - Live Activity

@MainActor
enum LiveActivityController {
    private static var activity: Activity<HVActivityAttributes>?
    private static var lastUpdate = Date.distantPast
    private(set) static var lastError: String?

    static func start(modeLabel: String) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }

        // Eine liegengebliebene Activity nicht daneben stehen lassen.
        if let old = activity {
            Task { await old.end(nil, dismissalPolicy: .immediate) }
        }

        let state = HVActivityAttributes.ContentState(
            watts: nil, amps: nil, volts: nil, secondsRemaining: nil,
            armed: true, arcBurning: false, tripLabel: nil)
        do {
            activity = try Activity.request(
                attributes: HVActivityAttributes(modeLabel: modeLabel, startedAt: Date()),
                content: .init(state: state, staleDate: nil))
            lastError = nil
        } catch {
            lastError = error.localizedDescription
        }
    }

    static func update(watts: Double?, amps: Double?, volts: Double?,
                       secondsRemaining: Int?, armed: Bool,
                       arcBurning: Bool, tripLabel: String?,
                       recentWatts: [Double] = []) {
        guard let activity else { return }

        // Höchstens ~1 Update/s — häufigere Updates drosselt das System ohnehin.
        // Eine Abschaltung (tripLabel) geht immer sofort durch.
        let now = Date()
        guard tripLabel != nil || now.timeIntervalSince(lastUpdate) >= 1 else { return }
        lastUpdate = now

        let state = HVActivityAttributes.ContentState(
            watts: watts, amps: amps, volts: volts,
            secondsRemaining: secondsRemaining, armed: armed,
            arcBurning: arcBurning, tripLabel: tripLabel,
            recentWatts: recentWatts)
        Task { await activity.update(.init(state: state, staleDate: nil)) }
    }

    /// Beendet die Activity; der letzte Zustand bleibt noch ~30 s sichtbar.
    static func end(tripLabel: String?) {
        guard let activity else { return }
        Self.activity = nil

        var state = activity.content.state
        state.armed = false
        state.arcBurning = false
        state.tripLabel = tripLabel
        Task {
            await activity.end(.init(state: state, staleDate: nil),
                               dismissalPolicy: .after(Date().addingTimeInterval(30)))
        }
    }
}
