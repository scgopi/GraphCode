import Foundation

/// The optional second pass: a small model rewrites the current beat into the sentence the
/// design asks for, when a human has said they are happy to pay for that.
///
/// **The derived beat comes first and is never replaced by nothing.** `SummaryBeatBuilder`
/// reads the agent's own narration off disk for free, and that is what the rail shows.
/// This runs *over* that beat — its own sentence and its one line of evidence, nothing
/// else — and if it fails, times out, or answers with something unusable, the beat stands.
/// A rail that empties itself because a subprocess was slow would be worse than one that
/// never called a model at all.
///
/// Five things keep it from costing more than the work it describes:
///
/// 1. **One beat, not a transcript.** The prompt carries the beat's own sentence and its
///    one line of evidence — a hundred tokens or so, bounded by construction, whatever the
///    session's scrollback has grown to.
/// 2. **Only when the beat changes.** `LoopSummary.beats` carries stable ids, so a beat
///    already rewritten is never sent twice — see `GraphStore.refreshSummary`.
/// 3. **Only for working loops.** The same guard `refreshActivity` uses.
/// 4. **The fast tier.** `--model haiku` and its equivalents, not whatever the loop runs on.
/// 5. **Out of the loop's budget line.** This is its own process, not the loop's session,
///    and `usage` is read from the session's own label store — so nothing here can land on
///    the loop's token count.
public enum SummaryModelWriter {
  /// How long a rewrite may take before the derived beat stands. Deliberately short: this
  /// is a caption on a panel, and a poll that blocks on it stops reporting presence.
  static let timeout: Duration = .seconds(20)

  /// The instruction, which is mostly a list of refusals.
  ///
  /// Every rule in it is one the design puts on the daemon, and the last is the one that
  /// matters most: a model asked to summarise will happily narrate something plausible
  /// from a thin beat, and a confident wrong summary is worse than the scrollback it
  /// replaced.
  static func prompt(beat: SummaryBeat) -> String {
    var lines = [
      "Rewrite one line for a status panel. Reply with the line and nothing else.",
      "",
      "Rules:",
      "- Under ten words. It renders in 188 points; anything longer is cut.",
      "- Plain past or present tense, no headings, no bullets, no quotes, no trailing stop.",
      "- Say what the agent is trying to do, not which tools it used.",
      "- Use only the facts below. Invent nothing. If they are too thin to improve on,",
      "  reply with the agent's own line unchanged.",
      "",
      "The agent's own line: \(beat.text)",
    ]
    if let evidence = beat.evidence {
      lines.append("What it touched: \(evidence)")
    }
    return lines.joined(separator: "\n")
  }

  /// The non-interactive invocation for a backend, at the fast tier.
  ///
  /// Every flag here was checked against the installed CLI's own `--help` rather than
  /// assumed — `claude -p`, `copilot -p/--prompt`, `codex exec`, and `--model`/`-m` on all
  /// three. `BackendCapabilities.isSpiked` exists because a capability claimed on a hunch
  /// is how a feature ships broken.
  ///
  /// The prompt is an argv element, never a shell string: it carries the agent's own
  /// sentence, which is arbitrary text from a model.
  public static func invocation(
    forBackend backend: CLISessionBackendKind, prompt: String, tier: ModelTier = .fast
  ) -> [String] {
    let model = tier.modelAlias.map { ["--model", $0] } ?? []
    switch backend {
    case .claudeCode:
      return ["claude", "-p", prompt] + model
    case .copilotCLI:
      // No `--allow-all`: this asks for a sentence, and a summariser that can run tools is
      // a summariser that can change the repository it is describing.
      return ["copilot", "-p", prompt] + model
    case .codex:
      let codexModel = tier.modelAlias.map { ["-m", $0] } ?? []
      return ["codex", "exec", prompt] + codexModel
    }
  }

  /// What a model's answer is allowed to become.
  ///
  /// A CLI in print mode still prefixes banners, wraps things in quotes, and occasionally
  /// answers in three paragraphs. Anything that isn't one short line is refused outright
  /// rather than trimmed into shape — `nil` means the derived beat stands, which is a good
  /// outcome, not a failure.
  static func accepted(_ raw: String) -> String? {
    let lines =
      raw
      .split(separator: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    // The last non-empty line: banners and warnings come first, the answer comes last.
    guard var text = lines.last else { return nil }
    if text.hasPrefix("\""), text.hasSuffix("\""), text.count > 2 {
      text = String(text.dropFirst().dropLast())
    }
    guard !text.isEmpty, text.count <= 90, !text.contains("```"),
      text.split(separator: " ").count <= 14
    else { return nil }
    return SummaryBeatBuilder.condense(text)
  }

  /// The beat, rewritten — or the beat unchanged, which is every failure path.
  public static func rewrite(
    _ beat: SummaryBeat, backend: CLISessionBackendKind, workingDirectory: String?
  ) async -> SummaryBeat {
    let invocation = invocation(forBackend: backend, prompt: prompt(beat: beat))
    guard
      let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst()),
        workingDirectory: workingDirectory)
    else { return beat }
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
    guard let outcome, outcome.0, let text = accepted(outcome.1) else { return beat }
    return SummaryBeat(
      id: beat.id, at: beat.at, pass: beat.pass, kind: beat.kind, text: text,
      evidence: beat.evidence)
  }

  /// The reading a backend just took, with its newest beat rewritten if the human has
  /// asked for that and the beat is one graphcode has not already spent a call on.
  ///
  /// **Only the newest beat.** The receding rows and the pass summaries are already on
  /// screen in the words they were first written in, and rewriting them would spend a call
  /// per poll to change text a person may be mid-way through reading.
  ///
  /// The dedupe needs no state of its own: `node.summary` is what the store already holds,
  /// so a beat whose id is already the current one has been through here.
  public static func applied(
    to reading: SummaryReading, node: LoopNode, projectPath: String?,
    settings: GraphcodeSettings = GraphcodeSettingsStore.load()
  ) async -> SummaryReading {
    guard settings.summarisesLoops, settings.summaryUsesModel,
      let newest = reading.beats.last, newest.id != node.summary?.current?.id
    else { return reading }
    let rewritten = await rewrite(
      newest, backend: node.backend,
      workingDirectory: ZmxSessionLauncher.workingDirectory(
        forNode: node, projectPath: projectPath))
    var beats = reading.beats
    beats[beats.count - 1] = rewritten
    return SummaryReading(beats: beats, finishedPasses: reading.finishedPasses)
  }
}
