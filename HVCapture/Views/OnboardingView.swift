//
//  OnboardingView.swift — Einrichtungs-Assistent beim ersten Start.
//
//  Führt einmalig durch das Nötigste: was die App ist (und was nicht), die
//  IP der Steckdose mit Verbindungstest, Mitteilungen, und der Hinweis auf die
//  Kalibrierfahrt. Danach setzt sie `onboarded` und erscheint nicht mehr.
//

import SwiftUI

struct OnboardingView: View {
    let onDone: () -> Void

    @State private var step = 0
    @AppStorage("plugIP") private var plugIP = ""
    @State private var plug = PlugLink.shared

    private let lastStep = 3

    var body: some View {
        VStack(spacing: 0) {
            TabView(selection: $step) {
                welcome.tag(0)
                plugSetup.tag(1)
                notifications.tag(2)
                ready.tag(3)
            }
            .tabViewStyle(.page(indexDisplayMode: .always))
            .animation(.easeInOut, value: step)

            Button {
                Haptics.tap()
                if step < lastStep {
                    withAnimation { step += 1 }
                } else {
                    onDone()
                }
            } label: {
                Text(step < lastStep ? "Weiter" : "Los geht's")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 52)
            }
            .buttonStyle(.borderedProminent)
            .tint(Palette.accent)
            .padding()
        }
        .appBackground()
    }

    // MARK: Schritte

    private func page<Content: View>(_ symbol: String, _ title: String,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(spacing: 18) {
            Spacer()
            Image(systemName: symbol)
                .font(.system(size: 60))
                .foregroundStyle(Palette.accentGradient)
            Text(title)
                .font(.title.weight(.bold))
                .multilineTextAlignment(.center)
            content()
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 28)
            Spacer()
            Spacer()
        }
        .padding()
    }

    private var welcome: some View {
        page("bolt.shield.fill", "Willkommen bei HV-Capture") {
            Text("Die App misst, protokolliert und filmt deinen Hochspannungsaufbau — und schaltet ihn über mehrere unabhängige Wege selbstständig ab. Sie ersetzt keinen physischen Schutz: Vorlast, Sicherung und ein erreichbarer Not-Aus bleiben Pflicht.")
        }
    }

    private var plugSetup: some View {
        page("poweroutlet.type.f.fill", "Steckdose verbinden") {
            VStack(spacing: 14) {
                Text("Trag die IP-Adresse deiner WLAN-Messsteckdose ein. Findest du sie später jederzeit in den Einstellungen.")
                TextField("z. B. 192.168.1.50", text: $plugIP)
                    .textFieldStyle(.roundedBorder)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 260)
                HStack(spacing: 8) {
                    Circle()
                        .fill(plug.reachable ? Palette.ok : Palette.danger)
                        .frame(width: 10, height: 10)
                    Text(plug.reachable ? "Erreichbar" : "Noch keine Verbindung")
                        .font(.footnote)
                }
            }
        }
    }

    private var notifications: some View {
        page("bell.badge.fill", "Bei Abschaltung benachrichtigen") {
            VStack(spacing: 14) {
                Text("HV-Capture kann dir eine Mitteilung schicken und einen Alarmton spielen, sobald der Wächter auslöst — auch wenn du gerade nicht auf den Bildschirm schaust.")
                Button("Mitteilungen erlauben") {
                    Task { await TripNotifier.request() }
                    Haptics.light()
                }
                .buttonStyle(.bordered)
                .tint(Palette.accent)
            }
        }
    }

    private var ready: some View {
        page("checkmark.seal.fill", "Fast fertig") {
            Text("Ein Tipp: Fahr vor dem ersten scharfen Einsatz die Kalibrierung (Einstellungen → Wächter). Damit lernt die App die echten Ströme deines Aufbaus und schlägt passende Grenzwerte vor — statt mit geratenen Zahlen zu arbeiten.")
        }
    }
}
