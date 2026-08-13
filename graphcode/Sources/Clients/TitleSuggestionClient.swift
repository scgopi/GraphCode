import Dependencies
import Foundation
import GraphcodeKit

/// Asks a loop's own backend for a one-or-two-word title when the human left the form's
/// title blank — `claude -p` / `copilot -p` / `codex exec`, the headless print-mode
/// shape of each CLI, so nothing here opens a session or touches the loop's actual work.
///
/// Fire-and-forget by design: the node is already created as "New Loop" by the time this
/// runs, and a `renameNode` follows only if an answer arrives. A backend that is slow,
/// missing, or confused costs nothing but the fallback name staying.
struct TitleSuggestionClient: Sendable {
  /// A short title for `prompt` that is not in `taken` — every node name the app knows
  /// across every open project (`LoopTitleDirectory`) — or `nil` when the backend can't
  /// produce one.
  var suggest:
    @Sendable (_ backend: CLISessionBackendKind, _ prompt: String, _ taken: Set<String>)
      async -> String?
}

extension TitleSuggestionClient: DependencyKey {
  /// How long a naming request may take before the fallback name simply stays. Print
  /// mode usually answers in a few seconds; a hung CLI should not pin a subprocess
  /// forever for a nicety.
  private static let timeout: Duration = .seconds(60)

  /// Carries the instruction into the shell as a variable rather than interpolated into
  /// the command string, the same guard `GhosttyTerminalView.promptVariable` applies: a
  /// prompt containing quotes, `$`, or backticks can't break out of the command.
  private static let promptVariable = "GRAPHCODE_TITLE_PROMPT"

  static let liveValue = TitleSuggestionClient { backend, prompt, taken in
    guard let invocation = invocation(for: backend) else { return nil }
    let output = await run(
      invocation, environment: [promptVariable: instruction(for: prompt, taken: taken)])
    return output.flatMap { accept($0, taken: taken) }
  }

  /// Reducer tests have no CLI to call and should not discover that by hanging.
  static let testValue = TitleSuggestionClient { _, _, _ in nil }

  /// Bounds how many taken names ride into the instruction. Any graph that outgrows it
  /// still gets the hard guarantee from `accept`; the instruction just stops naming
  /// every single one.
  private static let takenNamesListed = 100

  /// As precise as possible, preferring two words — a single word is allowed when it
  /// alone names the task, never more than two — and none of the names any canvas
  /// already shows. The model is told, and `accept` enforces what telling cannot
  /// guarantee.
  static func instruction(for prompt: String, taken: Set<String>) -> String {
    var instruction = """
      Reply with the most precise name you can for this task. Prefer two words; use \
      a single word only when it alone names the task precisely. Never more than two \
      words, no punctuation, no quotes — and nothing else.
      """
    let listed = taken.sorted().prefix(takenNamesListed)
    if !listed.isEmpty {
      instruction += " These names are already taken; do not reuse any of them: "
      instruction += listed.joined(separator: ", ") + "."
    }
    return instruction + " The task: \(prompt)"
  }

  /// `sanitize`, then the guarantee the instruction alone cannot make: a name some
  /// canvas already shows is refused outright — case-insensitively, since two loops
  /// named "Deploy" and "deploy" are the same collision to a human — and the fallback
  /// name stays.
  static func accept(_ output: String, taken: Set<String>) -> String? {
    guard let name = sanitize(output) else { return nil }
    let collides = taken.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    return collides ? nil : name
  }

  /// The headless print-mode invocation for each backend — the shape that answers on
  /// stdout and exits, as opposed to the interactive sessions loops actually run in
  /// (see `BackendCapabilities` for where each was read off the real `--help`).
  ///
  /// `-i` as well as `-l` for the reason every other launch site gives (see
  /// `GhosttyTerminalView.agentCommand`): the agent's `PATH` usually comes from
  /// `~/.zshrc`, which zsh reads only when interactive.
  private static func invocation(for backend: CLISessionBackendKind) -> [String]? {
    let command: String
    switch backend {
    case .claudeCode: command = "exec claude -p \"$\(promptVariable)\""
    case .copilotCLI: command = "exec copilot -p \"$\(promptVariable)\""
    case .codex: command = "exec codex exec \"$\(promptVariable)\""
    }
    return ["/bin/zsh", "-i", "-l", "-c", command]
  }

  /// Runs the invocation to completion off a plain pipe — not a PTY, because the answer
  /// is the process's stdout and print mode needs no terminal. Returns `nil` on any
  /// failure or on timeout, after which the process is killed rather than orphaned.
  private static func run(
    _ invocation: [String], environment extra: [String: String]
  ) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: invocation[0])
    process.arguments = Array(invocation.dropFirst())
    var environment = ProcessInfo.processInfo.environment
    for (key, value) in extra { environment[key] = value }
    process.environment = environment
    let stdout = Pipe()
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice

    let finished = AsyncStream<Bool> { continuation in
      process.terminationHandler = { process in
        continuation.yield(process.terminationStatus == 0)
        continuation.finish()
      }
      do {
        try process.run()
      } catch {
        continuation.yield(false)
        continuation.finish()
      }
    }

    let succeeded = await withTaskGroup(of: Bool.self) { group in
      group.addTask { await finished.first { _ in true } ?? false }
      group.addTask {
        try? await Task.sleep(for: timeout)
        return false
      }
      let first = await group.next() ?? false
      group.cancelAll()
      return first
    }
    guard succeeded else {
      if process.isRunning { process.terminate() }
      return nil
    }
    let data = stdout.fileHandleForReading.readDataToEndOfFile()
    return String(data: data, encoding: .utf8)
  }

  /// One clean name — at most two words — out of whatever the model printed. `codex
  /// exec` wraps its answer in log lines, and any model can get chatty — the *last*
  /// non-empty line is the answer far more reliably than the first, and two tokens of
  /// it are all that was asked for.
  static func sanitize(_ output: String) -> String? {
    let lastLine =
      output
      .components(separatedBy: .newlines)
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .last { !$0.isEmpty }
    let words = (lastLine ?? "").split(separator: " ").prefix(2)
      .map { $0.trimmingCharacters(in: CharacterSet.alphanumerics.inverted) }
      .filter { !$0.isEmpty }
    guard !words.isEmpty else { return nil }
    let name = words.joined(separator: " ")
    guard name.count <= 30 else { return nil }
    return name
  }
}

extension DependencyValues {
  var titleSuggestionClient: TitleSuggestionClient {
    get { self[TitleSuggestionClient.self] }
    set { self[TitleSuggestionClient.self] = newValue }
  }
}
