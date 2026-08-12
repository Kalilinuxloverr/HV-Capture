//
//  AppLock.swift — optionale Face-/Touch-ID-Sperre der App.
//
//  Sperrt die Bedienung, bis sich der Nutzer authentifiziert. Gedacht dagegen,
//  dass jemand anderes versehentlich einschaltet. Der Not-Aus-Weg (Watch, Siri)
//  läuft bewusst daran vorbei — abschalten muss immer sofort gehen.
//

import Foundation
import LocalAuthentication
import SwiftUI

@MainActor
@Observable
final class AppLock {
    static let shared = AppLock()

    /// Gesperrt = Inhalt verdeckt, bis authentifiziert. Startwert richtet sich
    /// danach, ob die Sperre überhaupt aktiv ist.
    private(set) var isLocked: Bool

    static var isEnabled: Bool {
        UserDefaults.standard.bool(forKey: "appLockEnabled")
    }

    private init() {
        isLocked = AppLock.isEnabled
    }

    /// Beim Zurückkehren aus dem Hintergrund wieder sperren.
    func lockIfEnabled() {
        if AppLock.isEnabled { isLocked = true }
    }

    func authenticate() {
        guard isLocked else { return }
        let context = LAContext()
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            // Kein Face ID / Code eingerichtet → Sperre kann nichts absichern,
            // also nicht aussperren.
            isLocked = false
            return
        }
        context.evaluatePolicy(.deviceOwnerAuthentication,
                               localizedReason: "HV-Capture entsperren") { success, _ in
            Task { @MainActor in
                if success { self.isLocked = false }
            }
        }
    }
}

/// Vollflächiger Sperrbildschirm mit Entsperr-Knopf.
struct LockScreenGate: View {
    @State private var lock = AppLock.shared

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "lock.fill")
                .font(.system(size: 44))
                .foregroundStyle(Palette.accent)
            Text("HV-Capture ist gesperrt")
                .font(.title3.weight(.semibold))
            Button {
                lock.authenticate()
            } label: {
                Label("Entsperren", systemImage: "faceid")
                    .frame(maxWidth: .infinity, minHeight: 50)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .padding(.horizontal, 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .appBackground()
        .onAppear { lock.authenticate() }
    }
}
