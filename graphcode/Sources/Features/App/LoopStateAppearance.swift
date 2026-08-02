import GraphcodeKit
import SwiftUI

/// The full vocabulary for a `LoopState` — a word, an indicator style, and whether it
/// wants a human — as opposed to `LoopStatePresence`'s single dot colour, which stays
/// where it is because `LoopTabBarView` and the sidebar still draw exactly that.
///
/// **Why a word and a shape at all.** Eight states map onto five hues, so colour alone
/// collapses two pairs: `awaitingInput`/`blocked` are both orange and `idle`/`stopped`
/// are both grey. Orange is worse still, because attention borrows it too — the same
/// hue meant "asking", "stuck", and "look here". Every state therefore carries three
/// channels: the hue, a solid-or-hollow indicator, and a word. Kill the colour entirely
/// — greyscale display, 40% zoom, a protanope — and the pairs stay apart, which is the
/// property `LoopStateAppearanceTests` guards.
extension LoopState {
  /// The pill's word. Takes the kind rather than reading it off a colour, because
  /// `idle` is the one state whose meaning depends on it: a time-based loop sitting at
  /// `idle` is between ticks and will run again on its own, and anything else at `idle`
  /// hasn't started or has stopped working for the moment.
  ///
  /// That second case reads IDLE and not STOPPED: nobody stopped it, and a state pill
  /// that reports a decision no human made is the kind of small lie this redesign is
  /// removing. The two stay apart on the indicator anyway — `idle` is solid, `stopped`
  /// hollow.
  ///
  /// Feed this `LoopNode.displayState` rather than `state`. The two differ for exactly
  /// one node — a `.running` one whose session has gone quiet — and that node is the
  /// reason this doc's "hasn't started" gained an "or has stopped working": a goal loop
  /// is `.running` from creation to resolution, so `state` alone had it pulsing RUNNING
  /// long after its agent answered and stopped.
  func displayWord(for loopType: LoopType) -> String {
    switch self {
    case .running: "RUNNING"
    case .awaitingInput: "NEEDS YOU"
    case .blocked: "BLOCKED"
    case .succeeded: "DONE"
    case .failed: "FAILED"
    case .stalled: "STALLED"
    case .idle: loopType == .timeBased ? "SCHEDULED" : "IDLE"
    case .stopped: "STOPPED"
    }
  }

  /// A 1.5pt ring instead of a filled disc. The second non-colour channel, and it is
  /// spent on exactly the two pairs that share a hue: hollow reads as "here but not
  /// producing anything" — waiting on something else (`blocked`) or switched off
  /// (`stopped`) — against the solid dot of a state that is its own author.
  var indicatorIsHollow: Bool {
    switch self {
    case .blocked, .stopped: true
    case .idle, .running, .awaitingInput, .succeeded, .failed, .stalled: false
    }
  }

  /// Nothing will move here until a person does something. Drives the card's inline
  /// action in place of a progress bar: a loop that is waiting has no progress to show,
  /// and offering a bar that cannot advance is worse than offering the button that can.
  ///
  /// Deliberately narrower than the attention rollup, which also raises `failed` and
  /// `stalled`. Those are worth reporting but are already over — the work is finished
  /// and wrong. These two are mid-flight and stalled on the human specifically.
  var wantsHuman: Bool {
    switch self {
    case .awaitingInput, .blocked: true
    case .idle, .running, .succeeded, .failed, .stalled, .stopped: false
    }
  }

  /// The indicator's hue at the exact value the design specifies, which is why this
  /// isn't `presenceColor`: that one is semantic (`.blue`, `.orange`) and shifts with
  /// the system's accent, and a pill whose dot and ink are mixed from two different
  /// oranges reads as a rendering bug.
  var indicatorTint: Color {
    switch self {
    case .running: StateTint.running
    case .awaitingInput, .blocked: StateTint.attention
    case .succeeded: StateTint.success
    case .failed: StateTint.failure
    case .stalled: StateTint.stalled
    case .idle, .stopped: StateTint.neutral
    }
  }

  /// The pill's background. `blocked` sits lower than `awaitingInput` on purpose — the
  /// one that is asking you a question should be the louder of the two oranges — and
  /// takes `pillStroke` to make up the weight it loses.
  var pillFill: Color {
    switch self {
    case .running: StateTint.running.opacity(0.16)
    case .awaitingInput: StateTint.attention.opacity(0.22)
    case .blocked: StateTint.attention.opacity(0.14)
    case .succeeded: StateTint.success.opacity(0.16)
    case .failed: StateTint.failure.opacity(0.16)
    case .stalled: StateTint.stalled.opacity(0.16)
    case .idle, .stopped: Color.white.opacity(0.07)
    }
  }

  /// A border only where the fill alone would be too quiet to find.
  var pillStroke: Color? {
    self == .blocked ? StateTint.attention.opacity(0.4) : nil
  }

  /// The label's ink: each hue lifted into a tint that clears contrast against the
  /// pill's own fill on this app's dark surfaces. Never the indicator colour — at 10pt
  /// the saturated hues are text you have to lean in for.
  var pillInk: Color {
    switch self {
    case .running: StateTint.runningInk
    case .awaitingInput, .blocked: StateTint.attentionInk
    case .succeeded: StateTint.successInk
    case .failed: StateTint.failureInk
    case .stalled: StateTint.stalledInk
    case .idle, .stopped: Color.white.opacity(0.5)
    }
  }

}

/// The state hues at their specified values, kept in one place so the pill, the
/// indicator, and anything Phase 2 adds mix from the same paint.
private enum StateTint {
  static let running = Color(red: 0.039, green: 0.518, blue: 1.000)  // #0a84ff
  static let attention = Color(red: 1.000, green: 0.624, blue: 0.039)  // #ff9f0a
  static let success = Color(red: 0.188, green: 0.820, blue: 0.345)  // #30d158
  static let failure = Color(red: 1.000, green: 0.271, blue: 0.227)  // #ff453a
  static let stalled = Color(red: 0.749, green: 0.353, blue: 0.949)  // #bf5af2
  static let neutral = Color.white.opacity(0.35)

  static let runningInk = Color(red: 0.549, green: 0.773, blue: 1.000)  // #8cc5ff
  static let attentionInk = Color(red: 1.000, green: 0.804, blue: 0.478)  // #ffcd7a
  static let successInk = Color(red: 0.494, green: 0.894, blue: 0.608)  // #7ee49b
  static let failureInk = Color(red: 1.000, green: 0.541, blue: 0.502)  // #ff8a80
  static let stalledInk = Color(red: 0.851, green: 0.635, blue: 0.969)  // #d9a2f7
}
