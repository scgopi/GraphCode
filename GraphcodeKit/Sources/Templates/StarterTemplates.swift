import Foundation

/// The templates a fresh install starts with.
///
/// A brand-new library is empty, and an empty ⌘T picker teaches nothing: the person
/// who most needs to know what a Goal loop is for is exactly the person who has never
/// written one. So the app ships ten briefs, and they are chosen to teach the
/// taxonomy rather than merely to be useful.
///
/// `MAIN_LOOP.md` orders the five types by **how much you have to decide before the
/// loop can start**, and the onboarding tour subtitles them by **what makes them
/// stop**. The starter set makes that axis concrete by *being* it — the lesson is in
/// each template's settings, not in its prose:
///
/// | Type | What its starters demonstrate |
/// | --- | --- |
/// | Main | No done check and no cadence, because "I understood it" is not checkable. |
/// | Goal | Exit 0 means done; the check is optional; a metric draws progress. |
/// | Timed | A brief worth *repeating*, and the two that follow their file. |
/// | Turn | The two pause rhythms, side by side. |
/// | Composite | Work handed along edges, carried inside one shareable file. |
///
/// **One fill, at the top.** Each starter has at most one `{token}`, and it is the
/// first line — `Goal: {goal}` — with everything below it fixed text that refers back
/// ("it", "that branch"). Filling a template is typing over one thing, not hunting
/// the same word through four paragraphs; and the body is short enough to read in
/// the picker before choosing it. A starter's settings never carry a token either:
/// a hole in a done check is a second place to look.
///
/// They are seeded as **real markdown files** rather than held as constants, which
/// teaches the format too: open one and the front matter is right there. Seeding runs
/// once (see `TemplateStorage.seedStartersIfNeeded`), so a starter you delete stays
/// deleted.
public enum StarterTemplates {
  /// Ids are fixed rather than freshly generated so that a loop following a starter
  /// keeps following it across a reinstall, and so a starter is recognisable as the
  /// same template on two machines.
  private static func id(_ suffix: String) -> UUID {
    UUID(uuidString: "5747A57E-0000-4000-8000-\(suffix)") ?? UUID()
  }

  /// In **priority order**, which is the order the ⌘T picker shows them — not
  /// alphabetical, because the list is a ladder and alphabetical scrambles it:
  ///
  /// 1. the one that leads a team, since that is what most work becomes;
  /// 2. Goal, the workhorse;
  /// 3. Timed;
  /// 4. everything else — Main's two pokes, the two Turn rhythms, the composite.
  public static var all: [PromptTemplate] {
    [
      leadATeam,
      getTheBuildGreen, reviewTheDiff, raiseTestCoverage,
      watchMyInbox, watchTheBuild,
      whereDoesThisLive, whyDidThisBreak,
      changeFileByFile, pairOnThis,
      reviewFixVerify,
    ]
  }

  /// Where a starter sits in the ladder — what the picker sorts the Starters group
  /// by. A starter the app no longer ships (a hand-marked file, an old build's) goes
  /// last rather than nowhere.
  public static func priority(of id: UUID) -> Int {
    all.firstIndex { $0.id == id } ?? all.count
  }

  /// The starters 0.1.58-beta2 and beta3 shipped, whose seed marker predates ids
  /// being recorded. Every starter in this list is treated as already seeded on such
  /// an install; anything added since — `leadATeam` first — still arrives. Append
  /// here only if a starter shipped in one of those two builds, which nothing more
  /// will.
  public static var seededBeforeIDsWereRecorded: Set<UUID> {
    Set(all.filter { $0.id != leadATeam.id }.map(\.id))
  }

  /// The three offered on an empty canvas — one from each of the first three rungs of
  /// the commitment ladder, so the pick itself shows the axis. The timed pick is the
  /// one about the repository: an inbox watcher is a fine starter and an odd first
  /// thing to offer on a code project's empty canvas. Deliberately not five:
  /// a row of every type is a taxonomy lesson, and this is a "get started" row.
  public static var firstLaunchPicks: [PromptTemplate] {
    [whereDoesThisLive, getTheBuildGreen, watchTheBuild]
  }

  // MARK: - Leading

  /// The starter at the top of the list, because this is what most work turns into:
  /// one loop that understands the goal, splits it, and stays to put the pieces back
  /// together. A **Main** loop on purpose — `MAIN_LOOP.md` names this as the
  /// orchestration path — that cuts no worktree, since a coordinator reads and steers
  /// while its children write. The Mailroom appears as the team's inbox, and the
  /// topic is the loop's to choose from the goal, so there is one thing to fill.
  public static var leadATeam: PromptTemplate {
    starter(
      id("000000000001"), "Lead a team toward a goal",
      """
      Goal: {goal}

      Lead this rather than doing it all yourself. Work out what done looks like and \
      where the work splits; give each independent piece its own goal loop, and \
      anything that needs watching rather than finishing a timed loop. Keep the \
      integration for yourself.

      The Mailroom is the team's inbox. Post your plan there under one topic named \
      for this goal, have every child post its result there, watch that topic, and \
      sync whenever you come back. Finish by checking the assembled result against \
      the goal and posting a closing note.
      """)
  }

  // MARK: - Main
  // One line to fill, and both end when you close them, which is the whole type. Both
  // are shaped like the team lead above, at a smaller scale: do the first pass
  // yourself, split only when the work actually splits, one Mailroom topic per
  // job, and the main loop is the only voice the human hears.

  public static var whereDoesThisLive: PromptTemplate {
    starter(
      id("100000000001"), "Where does this live?",
      """
      Symbol: {symbol}

      Map it before I touch it: where it's defined, everything that reads it, \
      everything that writes it. Do the first pass yourself. If it reaches into more \
      than a few areas, give each area its own goal loop to trace in depth and report \
      to the Mailroom under this symbol's name, and fold their reports into one \
      map. Change nothing — the map is the deliverable.
      """)
  }

  public static var whyDidThisBreak: PromptTemplate {
    starter(
      id("100000000002"), "Why did this break?",
      """
      Symptom: {symptom}

      Reproduce it first. Then list the plausible causes, and if there is more than \
      one, give each its own goal loop in its own worktree to confirm or rule it out, \
      reporting to the Mailroom under this symptom. Only you talk to me; the \
      children report to you. Stop when you can tell me the cause with the evidence — \
      I'll decide what to do about it.
      """)
  }

  // MARK: - Goal
  // Three, because Goal is the workhorse. None carries a done check with a hole in it:
  // the command a project uses is the one thing a template cannot know, so the brief
  // asks for it up top and the loop runs it.

  public static var getTheBuildGreen: PromptTemplate {
    starter(
      id("200000000001"), "Get the build green",
      """
      Build command: {build_command}

      It's failing. Run it, read the first real error, and fix the cause — the smallest \
      change that works, no refactoring you weren't asked for. Run it again after every \
      change, and stop when it exits 0.
      """,
      shape: .goalBased)
  }

  public static var reviewTheDiff: PromptTemplate {
    starter(
      id("200000000002"), "Review the diff on this branch",
      """
      Branch: {branch}

      Review every file it changed against the conventions already in this codebase. \
      List what must change before merge, most important first, with file:line. \
      Don't fix anything — the list is the deliverable.
      """,
      shape: .goalBased)
  }

  public static var raiseTestCoverage: PromptTemplate {
    starter(
      id("200000000003"), "Raise test coverage",
      """
      Area: {area}

      Bring its test coverage to 80%. Measure it first and say where it stands. Add \
      tests for the behaviour that would actually break, not the lines that are \
      cheapest to hit, and keep every existing test passing. Re-measure after each \
      batch, and stop when the area reads 80% or above — report the number before and \
      after.
      """,
      shape: .goalBased)
  }

  // MARK: - Timed
  // Both also demonstrate following: edit either file and the next run picks the
  // change up.

  /// The one timed starter that is not about the repository: mail access is the
  /// session's own (a connector, an MCP, a local CLI), so the brief names none and
  /// asks the loop to say so when it has none. It drafts and asks rather than sends —
  /// the human's answer is the input, and it rides into the next check as memory.
  public static var watchMyInbox: PromptTemplate {
    starter(
      id("300000000001"), "Watch my inbox",
      """
      Priorities: {priorities}

      Check the inbox with whatever mail access this session has. Pick out only what \
      needs attention — a question waiting on me, a deadline, anything touching the \
      priorities above — and say for each why it matters and what a reply would need. \
      Draft the reply where one is obvious, but send nothing: ask me, and carry what I \
      tell you into the next check. "Nothing needs you" is a valid report.
      """,
      shape: .timeBased,
      settings: TemplateSettings(cadence: "1h"))
  }

  public static var watchTheBuild: PromptTemplate {
    starter(
      id("300000000002"), "Watch the build",
      """
      Branch: {branch}

      Check whether its build is passing. If it broke since last time, find the commit \
      responsible and say what changed. If it's green, say so in one line and stop.
      """,
      shape: .timeBased,
      settings: TemplateSettings(cadence: "1h"))
  }

  // MARK: - Turn
  // The two pause rhythms, side by side — which is the only way the difference reads.

  public static var changeFileByFile: PromptTemplate {
    starter(
      id("400000000001"), "Make a change, one file at a time",
      """
      Task: {task}

      Work file by file. Before each file you change, tell me what you're about to do \
      and why.
      """,
      shape: .turnBased,
      settings: TemplateSettings(pausesBeforeWritesOnly: true))
  }

  public static var pairOnThis: PromptTemplate {
    starter(
      id("400000000002"), "Pair on this",
      """
      Task: {task}

      Work through it with me one step at a time. After each step, stop and tell me \
      what you did and what you think comes next. I'll steer.
      """,
      shape: .turnBased,
      settings: TemplateSettings(pausesBeforeWritesOnly: false))
  }

  // MARK: - Composite

  /// Three loops and the two hand-offs between them, carried inside one file. The
  /// children carry no tokens: a hole inside a carried graph is nowhere the dialog can
  /// show, so it would reach the child as literal text.
  public static var reviewFixVerify: PromptTemplate {
    // Every id and date here is fixed. The carried graph is re-identified when it is
    // applied, so these never reach a real loop — but they do reach the *file*, and
    // the seeder decides whether a starter is still the one it wrote by hashing the
    // file. Fresh UUIDs on every access would make the composite look edited by us
    // at every launch and rewrite it each time.
    let epoch = Date(timeIntervalSinceReferenceDate: 0)
    let reviewer = LoopNode(
      id: id("500000000101"), title: "Reviewer", loopType: .goalBased,
      goal: GoalSpec(
        summary: """
          Review every file changed on this branch and list what must change, most \
          important first, with file:line.
          """),
      createdAt: epoch)
    let fixer = LoopNode(
      id: id("500000000102"), title: "Fixer", loopType: .goalBased,
      goal: GoalSpec(
        summary: """
          Work through the findings you were handed, most important first. Make the \
          smallest change that resolves each one.
          """),
      createdAt: epoch)
    let verifier = LoopNode(
      id: id("500000000103"), title: "Verifier", loopType: .goalBased,
      goal: GoalSpec(
        summary:
          "Run the project's tests and confirm nothing the fixer changed broke anything else."),
      createdAt: epoch)
    var graph = LoopGraph(
      id: id("500000000100"),
      project: ProjectRef(
        path: "review-fix-verify", name: "Review, fix, verify", lastOpenedAt: epoch),
      nodes: [reviewer, fixer, verifier])
    graph.edges = [
      LoopEdge(id: id("500000000111"), from: reviewer.id, to: fixer.id, spec: EdgeSpec()),
      LoopEdge(id: id("500000000112"), from: fixer.id, to: verifier.id, spec: EdgeSpec()),
    ]
    return starter(
      id("500000000001"), "Review, fix, verify",
      """
      A reviewer hands its findings to a fixer, which hands the build to a verifier. \
      Nothing runs until you pilot it once.
      """,
      shape: .composite,
      settings: TemplateSettings(graphJSON: TemplateSettings.graphJSON(for: graph)))
  }

  // MARK: - Building

  private static func starter(
    _ id: UUID, _ name: String, _ body: String,
    shape: LoopType? = nil, settings: TemplateSettings? = nil
  ) -> PromptTemplate {
    var template = PromptTemplate(
      id: id, name: name, body: body, shape: shape, settings: settings, origin: .home)
    template.isStarter = true
    return template
  }
}
