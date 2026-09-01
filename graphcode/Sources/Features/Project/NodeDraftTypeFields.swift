import ComposableArchitecture
import GraphcodeKit
import SwiftUI

/// A sketch's one field — the shortest form in the app. `⏎` on an untouched dialog is
/// a valid, complete action; that is the point of the type. No done check, no cadence,
/// no name field: the loop names itself from the first exchange, and the starting note
/// seeds that name when there is one.
struct SketchDraftFields: View {
  @Bindable var store: StoreOf<ProjectFeature>

  var body: some View {
    DraftField(
      label: "Starting note", qualifier: "optional — leave it blank and it opens quiet",
      help: "No done check, no cadence — it works with you until you promote it or close it.",
      fromTemplate: store.templateSetFields.contains(.brief)
    ) {
      DraftProseField(
        placeholder: "e.g. where does the usage cap get read from?",
        text: $store.draftSketchNote, takesFocusRequest: store.templateFocus(.brief),
        onTokenJump: store.tokenJump)
    }
  }
}

/// A goal loop's fields: what done looks like, optionally how to check it, optionally
/// how to score it.
///
/// The metric is collapsed behind a dashed row because it is off the path for the common
/// case — a command field sitting open invites people to fill it in because it is there,
/// and a metric nobody meant costs a subprocess per pass forever.
struct GoalDraftFields: View {
  @Bindable var store: StoreOf<ProjectFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DraftField(
        label: "What does done look like?",
        help: "In your own words. The loop is told this, and works toward it.",
        fromTemplate: store.templateSetFields.contains(.brief)
      ) {
        DraftProseField(
          placeholder: "the crash rate is back under 1%", text: $store.draftGoal,
          takesFocusRequest: store.templateFocus(.brief), onTokenJump: store.tokenJump)
      }

      DraftField(
        label: "Done check", qualifier: "optional",
        help: "Runs periodically while the loop works. Exit 0 means done.",
        fromTemplate: store.templateSetFields.contains(.doneCheck)
      ) {
        HStack(spacing: 8) {
          DraftTextField(
            placeholder: "swift test 2>/dev/null", text: $store.draftPredicate, isMono: true,
            takesFocusRequest: store.templateFocus(.doneCheck), onTokenJump: store.tokenJump)
          testButton
        }
      }

      if store.isMetricExpanded {
        metricFields
      }
      if store.isBudgetExpanded {
        budgetFields
      }
      if !store.isMetricExpanded || !store.isBudgetExpanded {
        HStack(spacing: 8) {
          if !store.isMetricExpanded {
            expander("+ Track a progress metric") { store.isMetricExpanded = true }
          }
          if !store.isBudgetExpanded {
            expander("+ Cap its token spend") { store.isBudgetExpanded = true }
          }
        }
      }

      DraftField(label: "Name", qualifier: "optional") {
        DraftTextField(
          placeholder: "the loop names itself once it starts", text: $store.draftTitle)
      }
    }
  }

  private func expander(_ title: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      Text(title)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.6))
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 8)
        .padding(.horizontal, 9)
        .overlay {
          RoundedRectangle(cornerRadius: 8)
            .stroke(
              .white.opacity(0.14), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        }
    }
    .buttonStyle(.plain)
  }

  private var metricFields: some View {
    VStack(alignment: .leading, spacing: 10) {
      DraftField(
        label: "Measured by",
        help: "A command printing one number. Sampled once per pass, not per poll.",
        fromTemplate: store.templateSetFields.contains(.metric)
      ) {
        DraftTextField(
          placeholder: "./scripts/score.sh", text: $store.draftMetric, isMono: true,
          takesFocusRequest: store.templateFocus(.metric), onTokenJump: store.tokenJump)
      }
      Picker("", selection: $store.draftMetricDirection) {
        Text("Higher is better").tag(MetricDirection.maximize)
        Text("Lower is better").tag(MetricDirection.minimize)
      }
      .pickerStyle(.segmented)
      .labelsHidden()
    }
  }

  private var budgetFields: some View {
    DraftField(
      label: "Token budget", qualifier: "optional",
      help: "Stopped once its backend reports this many tokens spent (input + output). "
        + "Reported, never estimated — a backend that reports nothing is never stopped."
    ) {
      DraftTextField(placeholder: "200000", text: $store.draftBudget, isMono: true)
    }
  }

  /// Runs the check exactly the way `graphcoded` will — same shell, same directory. A
  /// Test that ran it differently would be worse than no Test at all.
  private var testButton: some View {
    HStack(spacing: 8) {
      Button(store.isTestingDoneCheck ? "Testing…" : "Test") {
        store.send(.doneCheckTestTapped)
      }
      .buttonStyle(.plain)
      .font(.system(size: 11.5, weight: .semibold))
      .foregroundStyle(.white.opacity(0.8))
      .padding(.horizontal, 11)
      .frame(height: 34)
      .background(.white.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
      .overlay {
        RoundedRectangle(cornerRadius: 8).stroke(.white.opacity(0.12), lineWidth: 1)
      }
      .disabled(
        store.draftPredicate.trimmingCharacters(in: .whitespaces).isEmpty
          || store.isTestingDoneCheck)

      if let outcome = store.doneCheckOutcome {
        Text(outcome.summary)
          .font(.system(size: 11, design: .monospaced))
          .foregroundStyle(outcome.passed ? Self.passInk : Self.failInk)
          .padding(.horizontal, 8)
          .frame(height: 34)
          .background(
            (outcome.passed ? Self.passInk : Self.failInk).opacity(0.14),
            in: RoundedRectangle(cornerRadius: 8)
          )
          .fixedSize()
      }
    }
  }

  private static let passInk = Color(red: 0.494, green: 0.894, blue: 0.608)
  private static let failInk = Color(red: 1.0, green: 0.541, blue: 0.502)
}

/// A timed loop's fields. GraphCode composes the `/loop` directive; the human writes the
/// work. The old form's single free-text field required knowing that the cadence lives
/// *inside* the prompt, and what the syntax was.
struct TimedDraftFields: View {
  @Bindable var store: StoreOf<ProjectFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DraftField(
        label: "How often?",
        help: store.draftRequiresDaemonHeartbeat
          ? "GraphCode's daemon holds the timer for this backend."
          : "GraphCode writes the /loop directive for you — you don't have to know "
            + "the syntax.",
        fromTemplate: store.templateSetFields.contains(.cadence)
      ) {
        VStack(alignment: .leading, spacing: 8) {
          Picker("", selection: $store.draftInterval) {
            ForEach(ProjectFeature.IntervalChoice.allCases, id: \.self) { choice in
              Text(choice.displayName).tag(choice)
            }
          }
          .pickerStyle(.segmented)
          .labelsHidden()
          if store.draftInterval == .custom {
            DraftTextField(
              placeholder: "30m, 2h, 3d…", text: $store.draftCustomInterval, isMono: true)
          }
        }
      }

      DraftField(
        label: "What to do each time",
        fromTemplate: store.templateSetFields.contains(.brief)
      ) {
        DraftProseField(
          placeholder: "Check for new crash reports and triage anything new",
          text: $store.draftTimedTask, takesFocusRequest: store.templateFocus(.brief),
          onTokenJump: store.tokenJump)
      }

      if store.draftRequiresDaemonHeartbeat {
        DraftField(
          label: "Driven by",
          help: "This backend cannot schedule its own session, so GraphCode delivers "
            + "each pass on the selected interval."
        ) {
          Text("Daemon heartbeat")
            .font(.system(size: 11.5, weight: .medium))
            .foregroundStyle(.white.opacity(0.78))
        }
      } else if SettingsModel.shared.settings.daemonHeartbeatEnabled {
        DraftField(
          label: "Driven by", qualifier: "experimental",
          help: "Heartbeat (the default while the experiment is on): the daemon wakes "
            + "the loop each interval and holds the timer; stopping the loop stops the "
            + "timer. Pick /loop to have the loop schedule itself instead."
        ) {
          Picker("", selection: $store.draftUsesHeartbeat) {
            Text("Itself, with /loop").tag(false)
            Text("Daemon heartbeat").tag(true)
          }
          .pickerStyle(.segmented)
          .labelsHidden()
        }
      }

      if !store.triggerPreview.isEmpty {
        HStack(spacing: 8) {
          Text("will run")
            .font(.system(size: 10.5))
            .foregroundStyle(.white.opacity(0.45))
          Text(store.triggerPreview)
            .font(.system(size: 11, design: .monospaced))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(2)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
        .background(Theme.draftField, in: RoundedRectangle(cornerRadius: 8))
      }

      if !store.effectiveDraftUsesHeartbeat {
        DraftField(
          label: "Stop after", qualifier: "optional",
          help: "Left empty, it keeps running until you stop it."
        ) {
          DraftTextField(placeholder: "20 runs, or 3 days", text: $store.draftStopAfter)
        }
      }

      DraftField(label: "Name", qualifier: "optional") {
        DraftTextField(
          placeholder: "the loop names itself once it starts", text: $store.draftTitle)
      }
    }
  }
}

/// A turn-based loop's fields — including the one that did not exist before: what the
/// session should actually do. Without it the session opened knowing it should pause and
/// what it would be judged on, but never what to start.
struct TurnDraftFields: View {
  @Bindable var store: StoreOf<ProjectFeature>

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      DraftField(
        label: "First instruction",
        fromTemplate: store.templateSetFields.contains(.brief)
      ) {
        DraftProseField(
          placeholder: "Port the settings screen to the new design system",
          text: $store.draftFirstInstruction,
          takesFocusRequest: store.templateFocus(.brief), onTokenJump: store.tokenJump)
      }

      DraftField(
        label: "Pause", fromTemplate: store.templateSetFields.contains(.pausesBeforeWritesOnly)
      ) {
        VStack(alignment: .leading, spacing: 6) {
          radio(
            "After every turn", isOn: !store.draftPausesBeforeWritesOnly,
            detail: nil
          ) { store.draftPausesBeforeWritesOnly = false }
          radio(
            "Only before it writes files", isOn: store.draftPausesBeforeWritesOnly,
            detail: "reads and searches run through"
          ) { store.draftPausesBeforeWritesOnly = true }
        }
      }

      DraftField(
        label: "What you're checking for", qualifier: "optional",
        help: "Shown to you at each pause, and to the loop as the bar it's aiming for."
      ) {
        DraftTextField(
          placeholder: "tests pass and the diff stays small", text: $store.draftCheck)
      }

      DraftField(label: "Name", qualifier: "optional") {
        DraftTextField(
          placeholder: "the loop names itself once it starts", text: $store.draftTitle)
      }
    }
  }

  private func radio(
    _ title: String, isOn: Bool, detail: String?, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      HStack(spacing: 8) {
        Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
          .font(.system(size: 13))
          .foregroundStyle(isOn ? Theme.paneFocusTint : .white.opacity(0.35))
        Text(title).font(.system(size: 12.5)).foregroundStyle(.white.opacity(0.85))
        if let detail {
          Text("— \(detail)")
            .font(.system(size: 11.5))
            .foregroundStyle(.white.opacity(0.5))
        }
        Spacer(minLength: 0)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

/// A composite's fields. It used to be one sentence and no fields at all — a dialog that
/// creates something you can't decide anything about.
struct CompositeDraftFields: View {
  @Bindable var store: StoreOf<ProjectFeature>

  private static let steps = [
    ("now", "Name it"), ("next", "Add loops inside"), ("then", "Pilot once"),
    ("finally", "Arm it"),
  ]

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      stepStrip
      Text("Nothing runs when you press Create.")
        .font(.system(size: 11))
        .foregroundStyle(.white.opacity(0.6))

      DraftField(label: "Name", fromTemplate: store.templateSetFields.contains(.title)) {
        DraftTextField(
          placeholder: "Nightly sweep", text: $store.draftTitle,
          takesFocusRequest: store.templateFocus(.brief), onTokenJump: store.tokenJump)
      }

      if let carried = store.draftSubGraph {
        // A template brought its children: the fifth block, not a detour into the
        // graph editor — the loops land inside on Create (PROMPT_TEMPLATES.md).
        DraftField(label: "Carried loops", qualifier: "from the template") {
          VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(carried.nodes.prefix(4).enumerated()), id: \.element.id) {
              index, node in
              HStack(spacing: 6) {
                RoundedRectangle(cornerRadius: 1.5)
                  .fill(node.loopType.accent)
                  .frame(width: 6, height: 6)
                Text(node.title)
                  .font(.system(size: 11.5))
                  .foregroundStyle(.white.opacity(0.75))
                  .lineLimit(1)
              }
            }
            if carried.nodes.count > 4 {
              Text("and \(carried.nodes.count - 4) more")
                .font(.system(size: 10.5))
                .foregroundStyle(.white.opacity(0.45))
            }
          }
        }
      }

      DraftField(
        label: "Intended schedule",
        help: "Local time, on the machine running the daemon. Nothing is scheduled "
          + "until you pilot and arm it."
      ) {
        HStack(spacing: 8) {
          Picker("", selection: $store.draftSchedule) {
            ForEach(ProjectFeature.CompositeSchedule.allCases, id: \.self) { schedule in
              Text(schedule.displayName).tag(schedule)
            }
          }
          .labelsHidden()
          if store.draftSchedule != .onATrigger {
            DraftTextField(
              placeholder: "09:00", text: $store.draftScheduleTime, isMono: true
            )
            .frame(width: 90)
          }
        }
      }
    }
  }

  /// The four steps, with the one you are on lit. A composite is the only type whose
  /// creation is the *first* of several deliberate acts, and the dialog said none of
  /// that — so people armed nothing and assumed it was broken.
  private var stepStrip: some View {
    HStack(spacing: 6) {
      ForEach(Array(Self.steps.enumerated()), id: \.offset) { index, step in
        VStack(alignment: .leading, spacing: 2) {
          Text(step.0)
            .font(.system(size: 9.5, weight: .bold))
            .foregroundStyle(.white.opacity(index == 0 ? 0.7 : 0.35))
          Text(step.1)
            .font(.system(size: 11.5, weight: index == 0 ? .semibold : .regular))
            .foregroundStyle(.white.opacity(index == 0 ? 0.9 : 0.5))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 7)
        .padding(.horizontal, 9)
        .background(
          index == 0 ? LoopType.composite.accent.opacity(0.14) : Color.white.opacity(0.035),
          in: RoundedRectangle(cornerRadius: 8)
        )
        .overlay {
          if index == 0 {
            RoundedRectangle(cornerRadius: 8)
              .stroke(LoopType.composite.accent.opacity(0.45), lineWidth: 1)
          }
        }
      }
    }
  }
}

/// One plain sentence naming what Create will actually do.
///
/// The dialog's fields say what the loop *is*; none of them say what pressing the button
/// does next, and for two of the four types the answer is surprising — a goal loop starts
/// working immediately, a composite doesn't run at all.
struct NodeDraftRecap: View {
  let draft: NodeDraft
  let worktree: ProjectFeature.WorktreeSelection

  var body: some View {
    HStack(alignment: .top, spacing: 9) {
      RoundedRectangle(cornerRadius: 1.5)
        .fill(draft.loopType.accent)
        .frame(width: 3)
      Text(sentence)
        .font(.system(size: 11.5))
        .foregroundStyle(.white.opacity(0.72))
        .fixedSize(horizontal: false, vertical: true)
      Spacer(minLength: 0)
    }
    .padding(9)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(draft.loopType.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .stroke(draft.loopType.accent.opacity(0.24), lineWidth: 1)
    }
  }

  private var sentence: String {
    switch draft.loopType {
    case .sketch:
      return
        "Opens a session\(location) and waits for you. Nothing is scheduled and nothing "
        + "resolves on its own — it works with you until you promote it or close it."
    case .goalBased:
      let check =
        draft.goal?.effectivePredicate == nil
        ? "resolves when its session finishes"
        : "resolves itself when the done check passes"
      let cap = draft.goal?.tokenBudget.map { " Stops if it spends more than \($0) tokens." } ?? ""
      return "Starts now\(location), works toward the goal, and \(check).\(cap)"
    case .timeBased:
      if draft.heartbeatIntervalSeconds != nil {
        return "Starts now\(location); the daemon wakes it each interval until you "
          + "stop it — stopping also stops the timer."
      }
      return "Starts now\(location) and runs again on its own until you stop it."
    case .turnBased:
      return
        "Waits until you open it, then works in turns — pausing "
        + (draft.pausesBeforeWritesOnly ? "before it writes anything" : "after each one")
        + " for your review."
    case .composite:
      return
        "Creates an empty group called “\(draft.resolvedTitle)” and opens it so you can "
        + "add loops. It won't run — and can't be armed — until you pilot it once."
    }
  }

  /// Where the work will happen, when that isn't just "here".
  private var location: String {
    switch worktree {
    case .none: return ""
    case .newBranch: return " in a new worktree"
    case .existing(let ref): return " in the \(ref.branch) worktree"
    }
  }
}
