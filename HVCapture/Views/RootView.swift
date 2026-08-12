//
//  RootView.swift — Startanimation, Sicherheits-Gate, Tab-Gerüst.
//
//  Das Gate steht bewusst VOR der Bedienung und verfällt bei jedem App-Start
//  neu. Es gibt kein „nicht mehr anzeigen" — die Checkliste ist der einzige
//  Punkt, an dem die App auf den physischen Schutz besteht, den sie selbst
//  nicht liefern kann.
//

import SwiftUI

struct RootView: View {
    @State private var showBoot = BootAnimation.isEnabled
    @State private var gatePassed = false
    @State private var lock = AppLock.shared
    @State private var store = SessionStore.shared
    @State private var milestones = MilestoneTracker.shared
    @AppStorage("onboarded") private var onboarded = false

    var body: some View {
        ZStack {
            if showBoot {
                BootAnimationView { withAnimation(.easeOut(duration: 0.35)) { showBoot = false } }
                    .transition(.opacity)
            } else if !onboarded {
                OnboardingView { withAnimation(.easeOut(duration: 0.3)) { onboarded = true } }
                    .transition(.opacity)
            } else if !gatePassed {
                SafetyGateView { withAnimation(.easeOut(duration: 0.3)) { gatePassed = true } }
                    .transition(.opacity)
            } else {
                MainTabs()
                    .transition(.opacity)
            }

            // Sperre liegt über allem — auch über der Checkliste, damit ein
            // fremder Blick nichts sieht, bis Face ID bestätigt hat.
            if lock.isLocked {
                LockScreenGate()
                    .transition(.opacity)
                    .zIndex(1)
            }
        }
        // Nach jeder gespeicherten Session: Meilensteine prüfen, Toast zeigen.
        .onChange(of: store.sessions.count) {
            milestones.evaluate(Records.from(store.sessions))
        }
        .overlay(alignment: .top) {
            if let m = milestones.justUnlocked {
                MilestoneToast(milestone: m)
                    .zIndex(2)
            }
        }
        .animation(.snappy, value: milestones.justUnlocked)
        .task(id: milestones.justUnlocked?.id) {
            guard milestones.justUnlocked != nil else { return }
            try? await Task.sleep(for: .seconds(4))
            milestones.clearToast()
        }
    }
}

// MARK: - Tabs

struct MainTabs: View {
    @State private var selection = 0

    var body: some View {
        TabView(selection: $selection) {
            NavigationStack { ControlView() }
                .tabItem { Label("Steuerung", systemImage: "bolt.fill") }
                .tag(0)
            NavigationStack { CameraView() }
                .tabItem { Label("Kamera", systemImage: "camera.fill") }
                .tag(1)
            NavigationStack { SessionsView() }
                .tabItem { Label("Verlauf", systemImage: "chart.xyaxis.line") }
                .tag(2)
            NavigationStack { SettingsView() }
                .tabItem { Label("Einstellungen", systemImage: "gearshape.fill") }
                .tag(3)
        }
    }
}

// MARK: - Sicherheits-Gate

/// Ein Punkt der Checkliste.
struct SafetyItem: Identifiable, Equatable {
    let id: String
    let title: String
    let detail: String
    let symbol: String

    static let all: [SafetyItem] = [
        SafetyItem(id: "ballast",
                   title: "Vorschaltlast in Serie",
                   detail: "Heizlüfter, Halogenstrahler oder ähnliche ohmsche Last in Serie zur Primärseite. Begrenzt den Strom im Kurzschlussfall — die wirksamste einzelne Massnahme, und die einzige, die auch das Relais der Dose schützt.",
                   symbol: "flame.fill"),
        SafetyItem(id: "fuse",
                   title: "Eigene träge Sicherung",
                   detail: "Sicherungshalter direkt vor dem Aufbau. Die Haussicherung ist zu träge und zu hoch, um hier noch etwas zu retten.",
                   symbol: "shield.lefthalf.filled"),
        SafetyItem(id: "estop",
                   title: "Physischer Not-Aus in Reichweite",
                   detail: "Schaltbare Steckdosenleiste oder Schalter, den du erreichst, ohne dem Aufbau näher zu kommen. Diese App ersetzt ihn nicht: WLAN kann ausfallen, das iPhone kann abstürzen.",
                   symbol: "poweroutlet.type.f.fill"),
        SafetyItem(id: "alone",
                   title: "Niemand sonst im Raum",
                   detail: "Keine weiteren Personen, keine Tiere, keine Kinder — auch nicht als Zuschauer hinter dir.",
                   symbol: "person.slash.fill"),
        SafetyItem(id: "dry",
                   title: "Trockener Boden, isolierte Schuhe",
                   detail: "Kein feuchter Untergrund, keine leitfähige Fläche, auf der du stehst.",
                   symbol: "shoeprints.fill"),
        SafetyItem(id: "onehand",
                   title: "Eine Hand in der Tasche",
                   detail: "Nur eine Hand am Aufbau. Der gefährliche Weg führt von Hand zu Hand über das Herz.",
                   symbol: "hand.raised.fill"),
        SafetyItem(id: "eyes",
                   title: "Augenschutz auf",
                   detail: "Der Bogen strahlt hell im UV. Ohne Schutz endet das wie Schweisserblitz.",
                   symbol: "eyeglasses"),
        SafetyItem(id: "extinguisher",
                   title: "Feuerlöscher griffbereit",
                   detail: "CO₂ oder Pulver, und nichts Brennbares im Umkreis.",
                   symbol: "flame.circle.fill"),
        SafetyItem(id: "clear",
                   title: "Nüchtern und ausgeruht",
                   detail: "Kein Alkohol, keine Müdigkeit. Der Aufbau verzeiht keinen Sekundenschlaf.",
                   symbol: "brain.head.profile"),
    ]
}

struct SafetyGateView: View {
    let onPass: () -> Void
    @State private var checked: Set<String> = []
    /// Wird über die 10 Tipps auf die Version in den Einstellungen gesetzt.
    @AppStorage("devModeUnlocked") private var devUnlocked = false

    private var allChecked: Bool { checked.count == SafetyItem.all.count }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                ForEach(SafetyItem.all) { item in
                    Button {
                        Haptics.light()
                        if checked.contains(item.id) { checked.remove(item.id) }
                        else { checked.insert(item.id) }
                    } label: {
                        row(item)
                    }
                    .buttonStyle(.plain)
                }

                Button {
                    Haptics.success()
                    onPass()
                } label: {
                    Text(allChecked ? "Verstanden — weiter" : "\(SafetyItem.all.count - checked.count) offen")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 52)
                }
                .buttonStyle(.borderedProminent)
                .tint(allChecked ? Palette.ok : Palette.warn)
                .disabled(!allChecked)
                .padding(.top, 4)

                Text("Diese Liste erscheint bei jedem Start neu. Das ist Absicht.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, devUnlocked ? 4 : 24)

                // Nur im freigeschalteten Entwicklermodus: die Liste überspringen,
                // wenn man ohne Aufbau bloss etwas in der App testet.
                if devUnlocked {
                    Button {
                        Haptics.warning()
                        onPass()
                    } label: {
                        Label("Überspringen — nur App testen, kein Aufbau", systemImage: "wrench.and.screwdriver")
                            .font(.footnote)
                    }
                    .buttonStyle(.bordered)
                    .tint(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, 24)
                    .accessibilityLabel("Checkliste überspringen, Entwicklermodus")
                }
            }
            .padding()
        }
        .appBackground()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Vor dem Einschalten", systemImage: "exclamationmark.triangle.fill")
                .font(.title2.weight(.bold))
                .foregroundStyle(Palette.warn)
            Text("Diese App misst, protokolliert und filmt. Sie schützt dich nicht. Der Schutz steht in dieser Liste — bestätige jeden Punkt einzeln.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.bottom, 4)
    }

    private func row(_ item: SafetyItem) -> some View {
        let on = checked.contains(item.id)
        return HStack(alignment: .top, spacing: 12) {
            Image(systemName: on ? "checkmark.circle.fill" : "circle")
                .font(.title3)
                .foregroundStyle(on ? Palette.ok : .secondary)
                .padding(.top, 2)
            VStack(alignment: .leading, spacing: 3) {
                Label(item.title, systemImage: item.symbol)
                    .font(.subheadline.weight(.semibold))
                Text(item.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(on ? "bestätigt" : "offen")
    }
}
