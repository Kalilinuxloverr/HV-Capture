//
//  TripNotifier.swift — lokale Mitteilung bei einer Sicherheitsabschaltung.
//
//  Meldet aufs iPhone (und die verbundene Watch), sobald der Wächter auslöst —
//  auch wenn die App im Hintergrund ist. Rein lokal, kein Server.
//

import Foundation
import UserNotifications

enum TripNotifier {
    private static var enabled: Bool {
        UserDefaults.standard.object(forKey: "tripNotificationsEnabled") as? Bool ?? true
    }

    /// Berechtigung erfragen — bei App-Start und im Onboarding aufgerufen.
    static func request() async {
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound])
    }

    /// Mitteilung zu einer Abschaltung. Nur Trips, die auf einen echten Vorfall
    /// hindeuten (quittierungspflichtig) — geplantes Aus per Timer meldet nichts.
    static func fire(reason: TripReason, detail: String?) {
        guard enabled, reason.requiresAcknowledgement else { return }
        let content = UNMutableNotificationContent()
        content.title = "HV-Capture hat abgeschaltet"
        content.body = detail.map { "\(reason.label) — \($0)" } ?? reason.label
        content.sound = .defaultCritical
        content.interruptionLevel = .timeSensitive
        let request = UNNotificationRequest(identifier: UUID().uuidString,
                                            content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
}
