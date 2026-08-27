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
  /// How long a rewrite may take before the derived beat stands.
  ///
  /// Under `ProjectRegistry.presencePollInterval`, deliberately: a caption that takes
  /// longer to write than the gap between polls is one the rail will never show in time,
  /// and the tick it is holding up is the one every state dot in the app rides on.
  static let timeout: Duration = .seconds(10)

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
      "- Under sixteen words. It renders in 188 points; anything longer is cut.",
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
  /// assumed — `claude -p`, `copilot -p/--prompt`, `codex exec`.
  /// `BackendCapabilities.isSpiked` exists because a capability claimed on a hunch is how a
  /// feature ships broken.
  ///
  /// **The model argument comes from the backend, not from the tier.** `ModelTier`'s alias
  /// is Claude Code's spelling — `haiku` — and this passed it to all three, which is the
  /// exact mistake `BackendCommand.modelArguments(for:)` was written to prevent: Copilot's
  /// `--model` takes explicit versioned ids (`claude-haiku-4.5`) and Codex's valid ids
  /// aren't visible from its `--help` at all, so it is given none and its own default
  /// applies. A wrong id fails at launch, which for this path means every rewrite quietly
  /// failing and the agent's own sentence standing — the feature would look switched off.
  ///
  /// The prompt is an argv element, never a shell string: it carries the agent's own
  /// sentence, which is arbitrary text from a model.
  public static func invocation(
    forBackend backend: CLISessionBackendKind, prompt: String, tier: ModelTier = .fast
  ) -> [String] {
    let model = backend.modelArguments(for: tier)
    switch backend {
    case .claudeCode:
      return ["claude", "-p", prompt] + model
    case .copilotCLI:
      // No `--allow-all`: this asks for a sentence, and a summariser that can run tools is
      // a summariser that can change the repository it is describing.
      return ["copilot", "-p", prompt] + model
    case .codex:
      return ["codex", "exec", prompt] + model
    case .openCode:
      return ["opencode", "run", prompt] + model
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
    // Through the launcher's login shell, not `Process`'s own launch. `Process` resolves
    // `executableURL` as a path and never searches `PATH`, so the bare `claude` above named
    // a file in the working directory: every rewrite on every backend threw at launch, and
    // a failed rewrite is silent by design — exactly the "feature looks switched off"
    // outcome `invocation` was written to prevent. It also leaked the PTY each throw had
    // already opened, which is what exhausted `graphcoded`'s share of `kern.tty.ptmx_max`.
    let launch = ZmxSessionLauncher.loginShellInvocation(
      of: invocation[0], arguments: Array(invocation.dropFirst()))
    guard
      let session = try? PTYProcessSession(
        executable: launch[0], arguments: Array(launch.dropFirst()),
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
    // Cancelling the task that was *waiting* does nothing to the process it was waiting
    // on. A backend that hangs would otherwise leave a `claude -p` per poll per loop
    // alive on its own PTY, spending tokens on a caption nobody is going to see — the
    // one cost this feature promises to keep bounded. A no-op once it has exited.
    session.terminate()
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
    return reading.replacingNewestBeat(with: rewritten)
  }
}
