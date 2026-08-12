//
//  MilestonesView.swift — Abzeichen-Wand und der Freischalt-Toast.
//

import SwiftUI

struct MilestonesView: View {
    @State private var tracker = MilestoneTracker.shared
    @State private var store = SessionStore.shared

    private var unlockedCount: Int {
        Milestones.all.filter { tracker.isUnlocked($0) }.count
    }

    var body: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                ForEach(Milestones.all) { m in
                    badge(m, unlocked: tracker.isUnlocked(m))
                }
            }
            .padding()
        }
        .appBackground()
        .navigationTitle("Meilensteine")
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Text("\(unlockedCount) / \(Milestones.all.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("\(unlockedCount) von \(Milestones.all.count) freigeschaltet")
            }
        }
        .onAppear { tracker.evaluate(Records.from(store.sessions)) }
    }

    private func badge(_ m: Milestone, unlocked: Bool) -> some View {
        VStack(spacing: 8) {
            ZStack {
                Circle()
                    .fill(unlocked ? AnyShapeStyle(Palette.accentGradient)
                                   : AnyShapeStyle(.quaternary))
                    .frame(width: 52, height: 52)
                Image(systemName: unlocked ? m.symbol : "lock.fill")
                    .font(.title3.weight(.bold))
                    .foregroundStyle(unlocked ? .white : .secondary)
            }
            Text(m.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(unlocked ? .primary : .secondary)
            Text(m.detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity)
        .card()
        .opacity(unlocked ? 1 : 0.75)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(m.title)
        .accessibilityValue(unlocked ? "freigeschaltet — \(m.detail)" : "noch gesperrt")
    }
}

// MARK: - Toast

/// Kurzer Banner oben, wenn ein Meilenstein frisch freigeschaltet wurde.
struct MilestoneToast: View {
    let milestone: Milestone

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: milestone.symbol)
                .font(.title3.weight(.bold))
                .foregroundStyle(Palette.accentGradient)
            VStack(alignment: .leading, spacing: 1) {
                Text("Meilenstein: \(milestone.title)")
                    .font(.subheadline.weight(.bold))
                Text(milestone.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Meilenstein freigeschaltet: \(milestone.title). \(milestone.detail)")
    }
}

#Preview {
    NavigationStack { MilestonesView() }
}
