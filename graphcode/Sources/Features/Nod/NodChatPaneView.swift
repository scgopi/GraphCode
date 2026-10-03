import AppKit
import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// Nod's chat, in the slot a CLI loop's terminal takes (design 1a, with 1b's folded Work
/// block and queued row): the goal pinned on top, one reading column, failure banners and
/// the composer at the bottom. The graph layer draws into `NodGraphSlots`.
struct NodChatPaneView: View {
  @Bindable var store: StoreOf<NodChatFeature>
  /// For the permission card's "Always in <project>".
  var projectName: String

  @Environment(\.nodGraphSlots) private var slots

  var body: some View {
    VStack(spacing: 0) {
      if store.goal != nil {
        goalHeader
      }
      slots.contextStrip?()
      transcript
      bottom
    }
    .background(NodStyle.paneBackground)
    .task { await store.send(.task).finish() }
  }

  // MARK: Goal header

  private var goalTint: Color { store.loopType.accent }

  private var goalHeader: some View {
    let verdict = NodChatPresentation.goalVerdict(for: store.transcript)
    return VStack(alignment: .leading, spacing: 0) {
      Button {
        store.send(.goalHeaderToggled)
      } label: {
        HStack(spacing: 10) {
          RoundedRectangle(cornerRadius: 2).fill(goalTint).frame(width: 8, height: 8)
          Text(store.goal ?? "")
            .font(.system(size: 12))
            .foregroundStyle(Color.white.opacity(0.85))
            .lineLimit(store.isGoalExpanded ? nil : 1)
            .multilineTextAlignment(.leading)
          Spacer(minLength: 8)
          Text(NodChatPresentation.verdictLabel(verdict))
            .font(.system(size: 11))
            .foregroundStyle(Self.verdictColor(verdict))
          Text(store.isGoalExpanded ? "▴" : "▾")
            .font(.system(size: 11))
            .foregroundStyle(NodStyle.muted)
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)

      if store.isGoalExpanded, let check = store.transcript.lastGoalCheck {
        NodGoalClauseList(clauses: check.clauses)
          .padding(.horizontal, 36)
          .padding(.bottom, 10)
      }
    }
    .background(goalTint.opacity(0.08))
    .overlay(alignment: .bottom) { Rectangle().fill(goalTint.opacity(0.25)).frame(height: 1) }
  }

  static func verdictColor(_ verdict: NodChatPresentation.GoalVerdict) -> Color {
    switch verdict {
    case .unchecked: return NodStyle.muted
    case .notYet: return NodStyle.attentionInk.opacity(0.9)
    case .holds: return NodStyle.met
    }
  }

  // MARK: Transcript

  private var visibleTurns: [NodTranscript.Turn] {
    store.isCompactedExpanded
      ? store.transcript.turns : store.transcript.turns.filter { !$0.isCompacted }
  }

  private var compactedCount: Int { store.transcript.turns.filter(\.isCompacted).count }

  private var transcript: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        if compactedCount > 0 {
          compactedDivider
        }
        ForEach(visibleTurns) { turn in
          turnView(turn)
          if let slot = slots.afterTurn?(turn.number) {
            slot
          }
        }
        ForEach(store.transcript.queued, id: \.id) { message in
          queuedRow(message)
        }
        if store.transcript.turns.isEmpty && store.transcript.queued.isEmpty {
          emptyState
        }
      }
      .frame(maxWidth: NodStyle.columnWidth, alignment: .leading)
      .padding(.horizontal, 24)
      .padding(.top, 22)
      .padding(.bottom, 12)
      .frame(maxWidth: .infinity)
    }
    .defaultScrollAnchor(.bottom)
  }

  private var compactedDivider: some View {
    Button {
      store.send(.compactedToggled)
    } label: {
      HStack(spacing: 10) {
        Rectangle().fill(NodStyle.hairline).frame(height: 1)
        Text(
          store.isCompactedExpanded
            ? "Compacted \(compactedCount) turns · hide originals"
            : "Compacted \(compactedCount) turns · show originals"
        )
        .font(.system(size: 11))
        .foregroundStyle(NodStyle.muted)
        .fixedSize()
        Rectangle().fill(NodStyle.hairline).frame(height: 1)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private var emptyState: some View {
    Text(store.transcript.session == nil ? "Waiting for Nod to start…" : "Nod is ready.")
      .font(.system(size: 12.5))
      .foregroundStyle(NodStyle.muted)
      .frame(maxWidth: .infinity)
      .padding(.top, 40)
  }

  @ViewBuilder
  private func turnView(_ turn: NodTranscript.Turn) -> some View {
    VStack(alignment: .leading, spacing: 10) {
      if let prompt = turn.prompt, let inbound = slots.inboundMessage?(prompt, turn.origin) {
        inbound
      } else if let prompt = turn.prompt {
        promptBubble(prompt, origin: turn.origin)
      } else if turn.origin == .timer || turn.origin == .goalCheck {
        Text(turn.origin == .timer ? "Timed run · turn \(turn.number)" : "Goal check")
          .font(.system(size: 11))
          .foregroundStyle(NodStyle.muted)
      }
      ForEach(NodChatPresentation.blocks(for: turn)) { block in
        blockView(block)
      }
      if turn.isRunning, let activity = store.transcript.activity,
        turn.number == store.transcript.currentTurn?.number,
        !turn.items.contains(where: Self.isRunningTool)
      {
        HStack(spacing: 8) {
          NodSpinner()
          Text(activity).font(.system(size: 12)).foregroundStyle(Color.white.opacity(0.7))
        }
        .padding(.vertical, 4)
      }
      if let ended = turn.ended, ended.filesChanged > 0 {
        Text(
          "\(ended.filesChanged) file\(ended.filesChanged == 1 ? "" : "s") · +\(ended.added) −\(ended.removed)"
        )
        .font(.system(size: 11))
        .foregroundStyle(NodStyle.muted)
        .frame(maxWidth: .infinity, alignment: .trailing)
      } else if turn.wasInterrupted {
        Text("Stopped").font(.system(size: 11)).foregroundStyle(NodStyle.muted)
      }
    }
    .opacity(turn.isCompacted ? 0.6 : 1)
  }

  /// A running tool card already says what the activity line would.
  static func isRunningTool(_ item: NodTranscript.Item) -> Bool {
    if case .tool(let card) = item { return card.status == .running }
    return false
  }

  private func promptBubble(_ message: NodEvent.UserMessage, origin: NodTurnOrigin) -> some View {
    VStack(alignment: .trailing, spacing: 4) {
      if origin == .handoff || origin == .mail {
        Text(origin == .handoff ? "Handoff" : "Mail")
          .font(.system(size: 10.5, weight: .semibold))
          .foregroundStyle(NodStyle.muted)
      }
      if !message.attachments.isEmpty {
        HStack(spacing: 6) {
          ForEach(Array(message.attachments.enumerated()), id: \.offset) { _, attachment in
            NodChip {
              Text(
                "\(NodComposerView.glyph(attachment.kind)) \(NodComposerView.label(attachment))")
            }
          }
        }
      }
      Text(message.text)
        .font(.system(size: 13.5))
        .lineSpacing(3)
        .foregroundStyle(NodStyle.ink)
        .textSelection(.enabled)
        .padding(.horizontal, 13)
        .padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(NodStyle.bubble))
        .frame(maxWidth: 520, alignment: .trailing)
    }
    .frame(maxWidth: .infinity, alignment: .trailing)
  }

  @ViewBuilder
  private func blockView(_ block: NodTurnBlock) -> some View {
    switch block {
    case .work(let summary):
      NodWorkBlockView(
        summary: summary,
        isExpanded: store.expandedWork.contains(summary.turn),
        onToggle: { store.send(.workToggled(turn: summary.turn)) },
        toolCard: toolCard)
    case .item(let item):
      itemView(item)
    }
  }

  @ViewBuilder
  private func itemView(_ item: NodTranscript.Item) -> some View {
    switch item {
    case .text(let message):
      assistantText(message)
    case .steer(let message):
      steerRow(message)
    case .tool(let card):
      toolCard(card)
    case .hunk(let card):
      NodHunkCardView(
        card: card,
        isCommenting: store.commentingHunkID == card.staged.hunkID,
        comment: $store.hunkComment.sending(\.hunkCommentChanged),
        onDecide: { store.send(.hunkDecided(hunkID: card.staged.hunkID, $0)) },
        onSubmitComment: { store.send(.hunkCommentSubmitted) },
        onCancelComment: { store.send(.hunkCommentCancelled) })
    case .permission(let card):
      NodPermissionCardView(card: card, projectName: projectName) {
        store.send(.permissionDecided(askID: card.ask.askID, $0))
      }
    case .goalCheck(let check):
      NodGoalCheckCardView(
        check: check, goalTint: goalTint,
        onMarkDone: { store.send(.markGoalDoneTapped) },
        onEditGoal: { store.send(.editGoalTapped) })
      if let offer = slots.afterGoalCheck?(check) {
        offer
      }
    case .plan(let plan):
      if let slot = slots.plan {
        slot(plan)
      } else {
        NodPlanCardView(plan: plan, canRun: !store.unavailableCommands.contains("runPlan")) {
          store.send(.runPlanTapped(planID: plan.planID, mode: $0))
        }
      }
    case .mailDraft(let draft):
      if let slot = slots.mailDraft {
        slot(draft)
      } else {
        NodMailDraftCardView(
          draft: draft, canSend: !store.unavailableCommands.contains("sendDraft")
        ) {
          store.send(.sendDraftTapped(draftID: draft.draftID, text: draft.text))
        }
      }
    }
  }

  private func toolCard(_ card: NodTranscript.ToolCard) -> NodToolCardView {
    NodToolCardView(
      card: card,
      isExpanded: store.state.isToolExpanded(card),
      onToggle: { store.send(.toolToggled(callID: card.call.callID)) },
      onOpenInShell: { store.send(.openInShellTabTapped(command: $0)) })
  }

  private func assistantText(_ message: NodTranscript.Message) -> some View {
    NodAssistantMessageView(
      message: message, isForkMenuOpen: store.forkMenuMessageID == message.id,
      canBranch: !store.unavailableCommands.contains("fork"),
      onFork: { store.send(.forkMenuToggled(messageID: message.id)) },
      onBranch: { store.send(.forkChosen(messageID: message.id, asSibling: false)) },
      onSibling: { store.send(.forkChosen(messageID: message.id, asSibling: true)) })
  }

  private func steerRow(_ message: NodEvent.UserMessage) -> some View {
    HStack(spacing: 8) {
      Text("Steered")
        .font(.system(size: 10.5, weight: .bold))
        .textCase(.uppercase)
        .foregroundStyle(NodStyle.actionInk)
      Text("“\(message.text)”").font(.system(size: 12.5)).foregroundStyle(NodStyle.secondary)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 7)
    .background(RoundedRectangle(cornerRadius: 9).fill(NodStyle.action.opacity(0.08)))
  }

  /// Design 1b's queued row: what will start the next turn, with the way to send it now.
  private func queuedRow(_ message: NodEvent.UserMessage) -> some View {
    HStack(spacing: 8) {
      Text("Queued")
        .font(.system(size: 10.5, weight: .bold))
        .textCase(.uppercase)
        .foregroundStyle(Color.white.opacity(0.5))
      Text("“\(message.text)”")
        .font(.system(size: 12.5))
        .foregroundStyle(NodStyle.secondary)
        .lineLimit(2)
      Spacer(minLength: 8)
      if let turn = store.transcript.currentTurn?.number {
        Text("sends after turn \(turn)").font(.system(size: 11)).foregroundStyle(NodStyle.muted)
      }
    }
    .padding(.horizontal, 11)
    .padding(.vertical, 8)
    .overlay(
      RoundedRectangle(cornerRadius: 9)
        .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        .foregroundStyle(Color.white.opacity(0.18)))
  }

  // MARK: Bottom

  private var bottom: some View {
    VStack(spacing: 8) {
      slots.aboveComposer?()
      if let banner = NodChatPresentation.banner(for: store.transcript) {
        NodBannerView(
          banner: banner,
          onSignIn: { store.send(.signInTapped) },
          onCompact: { store.send(.compactNowTapped) },
          onRaiseCap: { store.send(.raiseCapTapped) })
      }
      if store.isStartingRuntime {
        HStack(spacing: 8) {
          ProgressView().controlSize(.small)
          Text("Starting Nod…").font(.system(size: 11.5)).foregroundStyle(.secondary)
          Spacer()
        }
      }
      if let error = store.sendError {
        HStack(spacing: 8) {
          Text(error).font(.system(size: 11.5)).foregroundStyle(NodStyle.failed)
          Spacer()
          Button("Dismiss") { store.send(.errorDismissed) }.buttonStyle(NodLinkButtonStyle())
        }
      }
      NodComposerView(store: store)
    }
    .frame(maxWidth: NodStyle.columnWidth)
    .padding(.horizontal, 24)
    .padding(.top, 12)
    .padding(.bottom, 16)
    .frame(maxWidth: .infinity)
  }
}

/// Design section 8: what a CLI hides in its scrollback, as one line above the composer.
struct NodBannerView: View {
  let banner: NodChatPresentation.Banner
  let onSignIn: () -> Void
  let onCompact: () -> Void
  let onRaiseCap: () -> Void

  var body: some View {
    HStack(spacing: 10) {
      Circle().fill(tint).frame(width: 7, height: 7)
      Text(message)
        .font(.system(size: 12))
        .foregroundStyle(NodStyle.ink)
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 8)
      action
    }
    .padding(.horizontal, 12)
    .padding(.vertical, 9)
    .background(RoundedRectangle(cornerRadius: 10).fill(tint.opacity(0.09)))
    .overlay(RoundedRectangle(cornerRadius: 10).stroke(tint.opacity(0.4), lineWidth: 1))
  }

  private var tint: Color {
    switch banner {
    case .contextNearlyFull: return NodStyle.actionInk
    case .signInExpired, .spendCap: return NodStyle.attention
    case .other: return NodStyle.failed
    }
  }

  private var message: String {
    switch banner {
    case .signInExpired(let text), .spendCap(let text), .other(let text): return text
    case .contextNearlyFull(let percent): return "\(percent)% of context used"
    }
  }

  @ViewBuilder
  private var action: some View {
    switch banner {
    case .signInExpired:
      Button("Sign in", action: onSignIn).buttonStyle(NodButtonStyle(weight: .primary))
    case .contextNearlyFull:
      Button("Compact now", action: onCompact).buttonStyle(NodButtonStyle(weight: .secondary))
    case .spendCap:
      Button("Raise cap", action: onRaiseCap).buttonStyle(NodButtonStyle(weight: .primary))
    case .other:
      EmptyView()
    }
  }
}

/// One message of Nod's prose. Copy and Fork from here show while the pointer is on it
/// (design 3e), and stay while the fork menu it opened is up.
struct NodAssistantMessageView: View {
  let message: NodTranscript.Message
  let isForkMenuOpen: Bool
  let canBranch: Bool
  let onFork: () -> Void
  let onBranch: () -> Void
  let onSibling: () -> Void

  @State private var isHovering = false

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      Text(Self.markdown(message.text))
        .font(.system(size: 13.5))
        .lineSpacing(4)
        .foregroundStyle(NodStyle.body)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
      if message.isFinal {
        HStack(spacing: 14) {
          Button("Copy") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(message.text, forType: .string)
          }
          Button("Fork from here", action: onFork)
          Spacer()
        }
        .buttonStyle(NodLinkButtonStyle())
        .font(.system(size: 11))
        .opacity(isHovering || isForkMenuOpen ? 1 : 0)
        if isForkMenuOpen {
          NodForkMenuView(canBranch: canBranch, onBranch: onBranch, onSibling: onSibling)
        }
      }
    }
    .onHover { isHovering = $0 }
  }

  /// Inline code and emphasis from the model's markdown; block structure stays plain text
  /// so a half-streamed fence never reflows the column.
  static func markdown(_ text: String) -> AttributedString {
    (try? AttributedString(
      markdown: text,
      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
      ?? AttributedString(text)
  }
}
