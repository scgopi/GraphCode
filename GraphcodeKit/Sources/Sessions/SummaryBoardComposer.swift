import Foundation

/// Draws the run — one model call per finished pass, over the summary the rail already
/// holds, producing the Mermaid that `SummaryBoard` carries and the rail renders natively.
///
/// **The counterpart to `SummaryModelWriter`, and priced the same way.** That one buys a
/// better sentence; this buys a picture, and neither is free, so both sit behind their own
/// switch and neither is allowed to cost more than the work it describes. Five things keep
/// this bounded:
///
/// 1. **A summary, not a transcript.** The prompt carries what `LoopSummary` already holds
///    — twelve short beats and six pass lines at the absolute most, bounded by
///    construction whatever the session's scrollback has grown to.
/// 2. **Once per finished pass.** Not per beat and not per poll. `SummaryBoard.pass`
///    records which pass a board describes, and `GraphStore.refreshBoards` will not spend a
///    second call on a pass it has already drawn. A loop that narrates forty beats inside
///    one pass costs exactly one call.
/// 3. **At most `maxPerTick` loops a tick.** A graph where ten loops finish a pass together
///    draws two of them now and the rest next tick, rather than holding the poll — the same
///    poll every state dot in the app rides on.
/// 4. **The fast tier**, and its own process, so nothing here lands on the loop's own
///    token count.
/// 5. **Nothing, quite often.** `NONE` is an answer the prompt asks for by name: most passes
///    are one sentence of work, and a rectangle around a sentence is not a diagram.
public enum SummaryBoardComposer {
  /// How long a composition may take before the pass goes undrawn.
  ///
  /// Longer than `SummaryModelWriter.timeout` because a diagram is more to write than a
  /// line, and still inside `ProjectRegistry.presencePollInterval`: this runs on the poll,
  /// and a call that outlives the tick it started in would delay the next one.
  static let timeout: Duration = .seconds(14)

  /// How many loops may be drawn in one tick — see the header. Two rather than one so a
  /// pair of loops finishing together are both current within a tick, and rather than four
  /// because these run concurrently and each holds a CLI process.
  public static let maxPerTick = 2

  /// The instruction, which is mostly a list of refusals.
  ///
  /// **The judgement is asked for before either format is shown, and that ordering was
  /// measured rather than reasoned.** The first version described the flowchart first, with
  /// the only worked example, and offered `NONE` third: against real summaries at the fast
  /// tier it produced a flowchart every single time — for a two-line version bump, and for
  /// four findings that were plainly a table. A model shown one vivid format and asked to
  /// choose will choose it, so the choice now happens above the formats, as three tests
  /// applied in order, with `NONE` named as the default and the close call.
  ///
  /// The line that does the most work is the one denying that a pass list is a flow. Every
  /// session has passes in order, so "the work had an order to it" is true of everything,
  /// and it was reading as a licence to draw a chain of boxes that said nothing the pass
  /// list above it had not already said. A flow now requires a branch, a retry or a fork —
  /// which real runs do have, and which the diagram is worth drawing for.
  ///
  /// The Mermaid subset asked for is exactly the one `MermaidBoardParser` reads. Asking for
  /// syntax the renderer cannot draw would show as an empty rail, which reads as the
  /// feature being broken rather than as the model being ambitious.
  public static func prompt(
    node: LoopNode, summary: LoopSummary, closing: String? = nil
  ) -> String {
    var lines = [
      "You are labelling one coding session for a small status panel. Decide which of",
      "three answers fits, then write it. Reply with the answer and nothing else — no",
      "preamble, no explanation, no closing remark.",
      "",
      "FIRST decide. Apply these tests in order and stop at the first that passes:",
      "",
      "- TABLE — do the facts repeat the same kind of item with the same kind of detail?",
      "  Four findings that each name a file and a number; five files each with a change;",
      "  options each with a trade-off; a before and an after. If yes, answer with a table.",
      "",
      "- FLOW — did the work itself branch, retry, fork or hand off? A decision that went",
      "  one way rather than another, a check that sent it back to be redone, a plan with",
      "  alternatives in it.",
      "  A list of passes in order is NOT a flow. Every session has passes in order, and",
      "  drawing them as a chain of boxes says nothing the pass list did not already say.",
      "  A sequence of steps with no branch and no return is NOT a flow either.",
      "  If the work genuinely branched, answer with a flowchart.",
      "",
      "- NONE — everything else, which is most sessions. \"Read some things, changed some",
      "  things, ran the tests\" is a sentence, and the panel above this one already prints",
      "  that sentence. Answer with the single word NONE.",
      "",
      "When the choice is close, answer NONE. A wrong diagram is worse than no diagram,",
      "because it is read as a claim about how the work was structured.",
      "",
      "THEN write it, in one of these two forms.",
      "",
      "A table — plain GitHub Markdown, header row, --- separator row, no fence:",
      "",
      "| Test | Lines | Limit |",
      "|---|---|---|",
      "| ThingTests | 438 | 400 |",
      "| OtherTests | 414 | 400 |",
      "",
      "A flowchart — a fenced mermaid block:",
      "",
      "```mermaid",
      "%% title: four words at most",
      "flowchart TD",
      "  A([Start]) --> B[Do the thing]",
      "  B --> C{Did it work?}",
      "  C -->|yes| D([Done])",
      "  C -->|no| B",
      "```",
      "",
      "Rules:",
      "- At most \(SummaryBoard.maxNodes) boxes, at most \(SummaryBoard.maxRows) rows, at",
      "  most \(SummaryBoard.maxColumns) columns.",
      "- Labels under six words. They render in a narrow panel and are cut, not wrapped.",
      "- Mermaid syntax allowed: flowchart TD or LR; shapes [] () {} ([]); links -->",
      "  --- -.-> ==>; edge labels as -->|yes|. Nothing else — no subgraphs, no classDef,",
      "  no styling, no other diagram type. Anything else will fail to render.",
      "- Quote any label containing a bracket, comma, colon or quote mark.",
      "- Use only the facts below. Invent no step, no file and no outcome.",
      "",
      "The session:",
      "- Loop: \(node.title)",
    ]
    if let goal = node.goal?.summary, !goal.isEmpty {
      lines.append("- Trying to: \(goal)")
    }
    if summary.currentPass > 0 {
      lines.append("- On pass \(summary.currentPass)")
    }
    if !summary.passes.isEmpty {
      lines.append("")
      lines.append("Passes it has finished:")
      for pass in summary.passes {
        let delta = pass.delta.map { " (\($0))" } ?? ""
        lines.append("- pass \(pass.pass): \(pass.text)\(delta)")
      }
    }
    if !summary.beats.isEmpty {
      lines.append("")
      lines.append("What it has done this pass, oldest first:")
      for beat in summary.beats {
        let evidence = beat.evidence.map { " [\($0)]" } ?? ""
        lines.append("- \(beat.kind.rawValue): \(beat.text)\(evidence)")
      }
    }
    // **The only part of this prompt that is the work rather than a sentence about it.**
    //
    // Everything above is `LoopSummary` — beats condensed to sixteen words each, which is
    // the right size for the rail and too small to draw anything from. A session whose
    // answer was a table of four findings narrates it as "Four files exceed their limits",
    // and a composer told to invent nothing then correctly refuses to draw the table it
    // cannot see. Measured, not supposed: the same run drew a table when handed the
    // findings and answered NONE when handed the beats.
    if let closing, !closing.isEmpty {
      lines.append("")
      lines.append("What it said when it finished, in full:")
      lines.append(closing)
    }
    return lines.joined(separator: "\n")
  }

  /// The agent's own diagram, when its answer contains one this build can draw.
  ///
  /// Deliberately strict about `isDrawable`: a single box, or a one-row table, is not worth
  /// the rail's space and falls through to the composer, which may still find a shape in
  /// the pass as a whole.
  static func drawnByTheAgent(_ closing: String?, pass: Int, now: Date) -> SummaryBoard? {
    guard let closing, !closing.isEmpty else { return nil }
    guard let board = MermaidBoardParser.board(fromReply: closing, pass: pass, now: now),
      board.isDrawable
    else { return nil }
    return board
  }

  /// Whether the reply is the composer declining. Checked before parsing rather than left
  /// to it: a bare `NONE` parses to nothing anyway, but a model that answers
  /// "NONE — this pass was a single edit" would otherwise be read as a malformed diagram
  /// and logged as one.
  static func isDeclined(_ reply: String) -> Bool {
    let head =
      reply
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? ""
    return head.uppercased().hasPrefix("NONE")
  }

  /// The board for this pass, or nothing — which is the common answer and not a failure.
  ///
  /// Every path that isn't a drawable diagram returns `nil`, and `nil` leaves whatever the
  /// node already carries untouched: a pass that could not be drawn must not blank the
  /// board drawn for the pass before it.
  public static func compose(
    node: LoopNode, summary: LoopSummary, closing: String? = nil, projectPath: String?,
    now: Date = Date()
  ) async -> SummaryBoard? {
    // **The free path, tried first.** When the agent has already written a Mermaid block or
    // a Markdown table, that *is* the board: rendering it costs nothing, takes no time, and
    // is exactly what the session said rather than a model's restatement of it. Handing it
    // to a model to be written again spends a call to introduce drift.
    //
    // The same split the rest of this feature makes — the free reading first, the paid call
    // only for what the free one cannot answer.
    if let drawn = drawnByTheAgent(closing, pass: summary.currentPass, now: now) {
      return drawn
    }
    let invocation = SummaryModelWriter.invocation(
      forBackend: node.backend,
      prompt: prompt(node: node, summary: summary, closing: closing))
    // Through the launcher's login shell, for the reason `SummaryModelWriter.rewrite`
    // records: `Process` never searches `PATH`, so a bare `claude` throws at launch and
    // leaks the PTY it had already opened.
    let launch = ZmxSessionLauncher.loginShellInvocation(
      of: invocation[0], arguments: Array(invocation.dropFirst()))
    guard
      let session = try? PTYProcessSession(
        executable: launch[0], arguments: Array(launch.dropFirst()),
        workingDirectory: ZmxSessionLauncher.workingDirectory(
          forNode: node, projectPath: projectPath))
    else { return nil }
    let outcome = await withTaskGroup(of: (Bool, String)?.self) { group in
      group.addTask { await session.waitCollectingOutput() }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return nil
      }
      let first = await group.next() ?? nil
      group.cancelAll()
      return first
    }
    // Cancelling the task that was *waiting* does nothing to the process it was waiting on.
    // A no-op once it has exited.
    session.terminate()
    guard let outcome, outcome.0, !isDeclined(outcome.1) else { return nil }
    return MermaidBoardParser.board(
      fromReply: outcome.1, pass: summary.currentPass, now: now)
  }
}
