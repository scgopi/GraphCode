import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// The one-field form a sketch's "Promote to…" opens — never a re-brief.
///
/// The dialog asks for exactly what the target type needs and a sketch never did:
/// a done check for Goal, where to pause for Turn, a cadence for Timed. Everything
/// else the loop already is — its session, its transcript, its edges — travels
/// untouched, which is the sentence the header says.
struct SketchPromotionForm: View {
  @Bindable var store: StoreOf<ProjectFeature>

  private var node: LoopNode? {
    store.nodePendingPromotion.flatMap { store.graph.nodes[id: $0] }
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      header
      field
      NodeDraftRecap(draft: recapDraft, worktree: .none)
      footer
    }
    .padding(.horizontal, 22)
    .padding(.top, 20)
    .padding(.bottom, 18)
    .frame(minWidth: 460, maxWidth: .infinity)
    .background(Theme.sheet)
  }

  private var header: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack(spacing: 8) {
        RoundedRectangle(cornerRadius: 2.5)
          .fill(store.promotionTarget.accent)
          .frame(width: 9, height: 9)
        Text("Promote to \(store.promotionTarget.displayName)")
          .font(.system(size: 16, weight: .semibold))
      }
      Text(
        "Keep the session, add a shape — \(node?.title ?? "this loop") stays "
          + "exactly where it is."
      )
      .font(.system(size: 12))
      .foregroundStyle(.white.opacity(0.45))
    }
  }

  @ViewBuilder
  private var field: some View {
    switch store.promotionTarget {
    case .goalBased:
      DraftField(
        label: "What does done look like?",
        help: "The loop is told this, and works toward it with everything the session "
          + "already knows."
      ) {
        DraftProseField(
          placeholder: "the flake is reproduced and fixed", text: $store.promotionGoal)
      }
    case .turnBased:
      DraftField(label: "Where should it pause?") {
        VStack(alignment: .leading, spacing: 6) {
          pauseChoice(
            "After every turn", isOn: !store.promotionPausesBeforeWritesOnly
          ) { store.promotionPausesBeforeWritesOnly = false }
          pauseChoice(
            "Only before it writes files", isOn: store.promotionPausesBeforeWritesOnly
          ) { store.promotionPausesBeforeWritesOnly = true }
        }
      }
    case .timeBased:
      DraftField(
        label: "How often?",
        help: "The work it repeats is what the session is already doing."
      ) {
        VStack(alignment: .leading, spacing: 8) {
          Picker("", selection: $store.promotionInterval) {
            ForEach(ProjectFeature.IntervalChoice.allCases, id: \.self) { choice in
              Text(choice.displayName).tag(choice)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          if store.promotionInterval == .custom {
            DraftTextField(
              placeholder: "30m, 2h, 3d…", text: $store.promotionCustomInterval, isMono: true)
          }
          if !store.promotionTriggerPreview.isEmpty {
            Text(store.promotionTriggerPreview)
              .font(.system(size: 11, design: .monospaced))
              .foregroundStyle(.white.opacity(0.7))
              .lineLimit(2)
          }
        }
      }
    case .sketch, .composite:
      // Unreachable: the menu only offers the three committed session types.
      EmptyView()
    }
  }

  private var footer: some View {
    HStack(spacing: 12) {
      Button("Cancel") { store.send(.promotionCancelled) }
        .buttonStyle(.plain)
        .font(.system(size: 12.5))
        .foregroundStyle(.white.opacity(0.7))
      Spacer(minLength: 8)
      if store.promotion == nil, store.promotionTarget == .goalBased {
        Text("Say what done looks like to continue")
          .font(.system(size: 11.5))
          .foregroundStyle(.white.opacity(0.62))
          .lineLimit(1)
      }
      promoteButton
    }
  }

  private var promoteButton: some View {
    let isValid = store.promotion != nil
    return Button {
      store.send(.promotionConfirmed)
    } label: {
      HStack(spacing: 6) {
        Text("Promote")
          .font(.system(size: 13, weight: .semibold))
        Text("⏎").font(.system(size: 11, design: .monospaced)).opacity(0.7)
      }
      .foregroundStyle(isValid ? .white : .white.opacity(0.42))
      .padding(.horizontal, 14)
      .frame(height: 32)
      .background(
        Theme.paneFocusTint.opacity(isValid ? 1 : 0.28),
        in: RoundedRectangle(cornerRadius: 7))
    }
    .buttonStyle(.plain)
    .keyboardShortcut(.defaultAction)
    .disabled(!isValid)
  }

  /// What Promote will do, in `NodeDraftRecap`'s own voice — the same strip the
  /// creation dialog shows, built from a draft shaped like the promoted loop.
  private var recapDraft: NodeDraft {
    NodeDraft(
      title: node?.title ?? "",
      loopType: store.promotionTarget,
      triggerPrompt: store.promotionTriggerPreview.isEmpty ? nil : store.promotionTriggerPreview,
      pausesBeforeWritesOnly: store.promotionPausesBeforeWritesOnly,
      goal: store.promotionGoal.isEmpty ? nil : GoalSpec(summary: store.promotionGoal))
  }

  private func pauseChoice(
    _ title: String, isOn: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 13))
          .foregroundStyle(isOn ? Theme.paneFocusTint : .white.opacity(0.35))
        Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}
