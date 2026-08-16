import Foundation

/// What a session is told about the graph it's running inside.
///
/// Until this existed, a loop's session was an ordinary agent in a folder with no idea it
/// was a node in anything — so "fan this out into one loop per issue" was impossible to
/// ask for, however the prompt was worded. The `graphcode` CLI could always create nodes;
/// nothing ever told the agent that.
///
/// **The briefing goes in a file, and only its path is passed on the command line.** The
/// first cut passed the prose itself as an argument, and it did not survive contact with
/// a terminal: `zmx` starts a session by *typing* the launch command into a shell, and a
/// tty in canonical mode drops everything past `MAX_CANON` — 1024 bytes on macOS
/// (`sys/syslimits.h`). A briefing of a thousand-odd characters pushed the line past that
/// limit, the tail was silently discarded mid-quote, and the shell sat forever at a `>`
/// continuation prompt waiting for a closing `'` that had been eaten. A path is ~60 bytes
/// and cannot do that.
///
/// It also means the text is free to be as long and as readable as it needs to be: a file
/// has no line-length limit and no quoting hazard.
public enum SessionBriefing {
  /// Where a drag-to-Applications install puts the CLI. Named explicitly because the
  /// daemon's launchd `PATH` is not a human's: a session that inherits it may not find
  /// `graphcode` by name, and "command not found" would read to the agent as "this
  /// machine has no graphcode" rather than "try the absolute path".
  public static let installedCLIPath = "~/.graphcode/bin/graphcode"

  /// Written briefings live here, one directory per project.
  public static var directory: URL {
    SupportDirectory.url.appendingPathComponent("briefings", isDirectory: true)
  }

  /// A project's own briefing directory. A directory rather than a bare file because
  /// Copilot discovers instructions by *searching a directory*, so the briefing has to sit
  /// inside one that contains nothing else.
  public static func directory(forProjectPath projectPath: String) -> URL {
    directory.appendingPathComponent(slug(for: projectPath), isDirectory: true)
  }

  /// The filename Copilot looks for when it searches a directory, and the file Claude Code
  /// is handed by path. One file, two delivery mechanisms, no duplication.
  public static let fileName = "AGENTS.md"

  /// The briefing for a node in `projectPath`'s graph, or `nil` when there's no path to
  /// tell it about — every command the briefing describes takes one, so a briefing
  /// without it would describe commands the session can't run.
  public static func text(projectPath: String?) -> String? {
    guard let projectPath, !projectPath.isEmpty else { return nil }
    return """
      # You are a loop in a graphcode graph

      This session is one node in a graph of agentic coding sessions for the project at
      \(projectPath). A human can open, steer, and stop you from graphcode's sidebar.

      ## Fanning work out into more loops

      If the work you have been given genuinely splits into independent pieces that should
      each run as their own session — one per GitHub issue, one per failing test, one per
      package to migrate — create a loop for each instead of working through them yourself
      in sequence:

      ```sh
      graphcode node create \(projectPath) --title <title> --type goal --goal <what done looks like>
      ```

      A **node is a loop** — the cards on graphcode's canvas are loops, and the CLI calls
      them nodes. A request to create a "child node", "child loop", "sub-loop", "subagent
      loop", or a "node" of any kind is a request for this command, whatever the word.
      Run from inside your session, the CLI already attributes the new loop to you as its
      creator, so making a child needs nothing beyond the create itself.

      ## Choosing the loop type

      Choose by **what decides the loop is finished**. This matters more than it looks:
      two of the three types start running the moment you create them, and one does not.

      - `--type goal --goal <what done looks like>` — **the default, and what you almost
        always want.** The loop starts immediately and resolves when its own session
        finishes the goal. Add `--predicate <shell command>` only when a command can
        actually decide it (exit 0 means met, e.g. a test run); without one, finishing the
        work is what resolves it.
      - `--type time --prompt <prompt carrying its own cadence>` — for work that never
        finishes because it repeats: watching, polling, monitoring, anything phrased as
        "every hour", "keep checking", "each morning". Also starts immediately.
        **The cadence goes inside the prompt**, as a directive the session runs on itself
        (`/loop 1h Check for new reports`, `/schedule …`) — graphcode holds no timer of its
        own, so a time-based loop whose prompt carries no cadence just runs once and stops.
        Do not reach for this for one-off work: "check the build" is a goal, "check the
        build every hour" is time-based.
      - `--type turn --check <what a human verifies>` — for work a **human** must review
        each turn before it continues. **A turn-based loop does not start on its own**:
        nothing runs until a person opens its terminal. Create one only when a human really
        is the thing standing between turns; otherwise you will have made a loop that sits
        in the sidebar doing nothing.

      Worked examples, since the wording of the request is the whole signal:

      | What you were asked | Type | Why |
      |---|---|---|
      | "spin up five loops and have each say hello" | `goal` ×5 | Nobody needs to approve a greeting, and it ends when it has been said. Turn-based ones would never even run. |
      | "fix each of these five issues" | `goal` ×5, `--predicate` if a test proves it | The work decides when it is done. |
      | "fix these five, I want to review each fix" | `turn` ×5 | You have been told a human stands between turns. |
      | "watch for new issues every hour and triage them" | `time` ×1 | It recurs; the cadence goes in the prompt. One watcher that fans out beats five identical watchers. |

      `graphcode status \(projectPath)` lists the loops that already exist. Check it before
      creating any, so you extend the graph rather than duplicating it.

      ## Talking to another loop

      ```sh
      graphcode node send \(projectPath) <node-id> <message…>
      ```

      Types your message directly into that loop's live session, attributed to you —
      use it when a peer should know something *now*, mid-run: "the API changed under
      you", "stop, I already fixed that file". `graphcode status \(projectPath)` shows
      every loop's id. A target that isn't live gets the message staged into its
      memory instead — it reads it at its next wake, and the command tells you which
      happened. Add `--follow-up` (first word after the id) when the message can wait:
      the target is not interrupted mid-turn — it hears it when it next goes idle,
      from its memory otherwise. If you were created by another loop, your memory log's first entry is
      the exact command for reporting results back to it. For recurring communication,
      an edge is still the right tool: a `message` edge fires automatically when you
      finish, a `handoff` sequences the other loop after you. This command is the
      one-off.

      ## Remembering across passes

      Loops that run in cycles get relaunched, and a relaunched session starts fresh.
      Each loop has a memory log for exactly this; when yours has one, your opening
      prompt points at it — read it before working. Record anything a future pass must
      know the moment you learn it:

      ```sh
      graphcode node memo \(projectPath) <your-node-id> <note>
      ```

      Record decisions, dead ends, and constraints ("approach X fails because Y") — not
      a transcript, and nothing the code or git history already says. Your node id is
      the suffix of `$ZMX_SESSION` after `graphcode-`.

      Memos record what happened; your **playbook** records how to do this job. It rides
      into every wake ahead of the history, so when a pass teaches you a better method —
      an order of operations, a check worth running first, a tool that works here —
      rewrite it (whole document, small evidence-backed changes):

      ```sh
      graphcode node refine \(projectPath) <your-node-id> <playbook text>
      ```

      `--file <path>` sends a multi-line document; `--rollback` restores the previous
      version (the old one is always snapshotted). Refine your method freely — your
      goal, predicate, and budget stay out of reach regardless.

      ## Project skills

      Your playbook is yours; a **skill** is for every loop in this project. Check the
      project's skill library before working something out from scratch (Claude Code
      loads `.claude/skills/` automatically). When your work produces a method another
      loop could reuse — a build recipe, a verification sequence, a workaround with a
      why — distill it into a skill in your backend's native format: for Claude Code,
      `.claude/skills/<name>/SKILL.md`, a short markdown recipe with a one-line
      description. When a goal loop resolves with its session still live, graphcode
      asks it this once; one-off work should not become a skill.

      ## The rest of the CLI

      Rarer verbs, one line each — like everything above, they take the project path:

      - `graphcode node stop \(projectPath) <node-id>` pauses a loop reversibly.
        `node delete` also erases its edges, session, and memory — irreversible, so
        reach for stop unless deletion is exactly what was asked for.
      - `graphcode node update \(projectPath) <node-id> --goal|--prompt|--check|--model …`
        edits a loop in place; a loop may not change its own `--predicate` or
        `--budget`. For a composite loop, `node pilot` dry-runs it and `node arm` arms
        it afterwards.
      - `graphcode edge create \(projectPath) <from-id> <to-id> --kind handoff|message|spawn`
        wires loops: `handoff` sequences the target after you finish, `message` sends it
        your result, `spawn` has your finish create it.
      - `graphcode node export \(projectPath) <node-id> --output <file.zip>` packages a
        loop and its descendants for sharing, and `graphcode node import \(projectPath)
        <file.zip> [--as-child-of <node-id>]` splices a bundle in with fresh identities.
        Both stay off until "Export and import loops" is enabled in the app's Settings —
        the command says so when it is not.
      - `graphcode projects` lists every project, `graphcode usage \(projectPath)` totals
        a graph's token spend, and the reserved path `graphcode://global` addresses the
        app-wide global graph wherever a project path is accepted.

      If `graphcode` is not on your `PATH`, it is at `\(installedCLIPath)`.

      Give each loop a title that says what it is for and a goal that says what done looks
      like — they are what a human sees in the sidebar.

      ## When not to

      Do not create loops for ordinary subtasks you can simply carry out, for steps that
      must happen in order, or to parallelise something small. A graph full of loops nobody
      asked for is worse than one loop that did the work.

      Never create a loop whose job is to create more loops.
      """
  }

  /// How Copilot CLI is told about the briefing: a one-line preamble on the prompt, and
  /// `--add-dir` so the session is allowed to read the file it names.
  ///
  /// **`COPILOT_CUSTOM_INSTRUCTIONS_DIRS` does not work.** `copilot help environment`
  /// documents it as "additional directories to search for custom instructions files", and
  /// it was the obvious right answer — a real system-level instruction, nothing in the
  /// prompt, nothing written into anyone's repository. Measured against 1.0.75 it is simply
  /// ignored: an `AGENTS.md` in a directory named by that variable has no effect, in either
  /// the `AGENTS.md` or `.github/copilot-instructions.md` layout, while the identical file
  /// in the working directory is picked up every time. Shipping on the documentation cost
  /// a release where Copilot loops silently never fanned out (issue #2).
  ///
  /// `--add-dir` is the half that is easy to miss. Copilot verifies file paths, so a
  /// session told to read `~/.graphcode/briefings/…` cannot reach it — the pointer alone
  /// looks like the agent ignoring an instruction when it is actually being denied.
  /// Deliberately ASCII-only, with plain words on both sides of the path. This string
  /// travels through more layers than any other prose graphcode emits — argv, zmx's
  /// typed command line, a canonical-mode tty, sometimes ssh — and an em dash sitting
  /// right after the path came out the far end as `AGENTS. it explains`, the `.md`
  /// eaten with the dash, on a machine where every ASCII character survived. The agent
  /// then tried to read a file that doesn't exist.
  public static func pointer(toBriefingAt path: String) -> String {
    "Before anything else, read the briefing file at \(path) and follow it. It explains "
      + "the graph you are running inside and how to create additional loops when the "
      + "work calls for it."
  }

  /// Writes the briefing for `projectPath` and returns where it landed, or `nil` if there
  /// is nothing to write or writing failed.
  ///
  /// Rewritten on every launch rather than cached: it costs one small write per session
  /// start, and it means a briefing never goes stale against a graphcode that has been
  /// upgraded underneath it.
  public static func write(projectPath: String?) -> URL? {
    guard let projectPath, let text = text(projectPath: projectPath) else { return nil }
    let directory = directory(forProjectPath: projectPath)
    let url = directory.appendingPathComponent(fileName)
    do {
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: true)
      try text.write(to: url, atomically: true, encoding: .utf8)
      return url
    } catch {
      // A session with no briefing is the pre-briefing behaviour, which works. Failing the
      // launch over this would trade a missing capability for a missing loop.
      return nil
    }
  }

  /// A project path flattened into one filename-safe component. Not a hash: the point of
  /// keeping it readable is that someone looking in `~/.graphcode/briefings` can tell
  /// which project a file belongs to.
  static func slug(for projectPath: String) -> String {
    let flattened = projectPath.map { character -> Character in
      character.isLetter || character.isNumber || character == "-" ? character : "-"
    }
    return String(flattened).trimmingCharacters(in: CharacterSet(charactersIn: "-"))
  }

  /// Whether a string is safe to pass through `zmx`'s type-it-into-a-shell launch — see
  /// this type's doc comment for both hazards.
  public static func isSafeToType(_ text: String) -> Bool {
    !text.contains("\n") && !text.contains("\r") && text.utf8.count <= safeArgumentBudget
  }

  /// How much of `MAX_CANON`'s 1024 bytes any one argument may claim. The rest is for the
  /// shell wrapper, the session name, the model flag, and the human's own prompt.
  public static let safeArgumentBudget = 256
}
