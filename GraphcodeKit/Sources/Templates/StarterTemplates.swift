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

  public static var all: [PromptTemplate] {
    [
      whereDoesThisLive, whyDidThisBreak,
      getTheBuildGreen, reviewTheDiff, raiseTestCoverage,
      nightlyDependencyReview, watchTheBuild,
      portWithReview, pairOnThis,
      reviewFixVerify,
    ]
  }

  /// The three offered on an empty canvas — one from each of the first three rungs of
  /// the commitment ladder, so the pick itself shows the axis. Deliberately not five:
  /// a row of every type is a taxonomy lesson, and this is a "get started" row.
  public static var firstLaunchPicks: [PromptTemplate] {
    [whereDoesThisLive, getTheBuildGreen, nightlyDependencyReview]
  }

  // MARK: - Main
  // Nothing to fill in, nothing to decide. Both of these end when you close them,
  // which is the whole type.

  static var whereDoesThisLive: PromptTemplate {
    starter(
      id("100000000001"), "Where does this live?",
      """
      Trace {symbol} through this codebase. Show me where it's defined, everything \
      that reads it, and everything that writes it. Don't change anything — I'm \
      trying to understand the shape before I touch it.
      """)
  }

  static var whyDidThisBreak: PromptTemplate {
    starter(
      id("100000000002"), "Why did this break?",
      """
      Reproduce {symptom} and explain what causes it. Work from the failure back to \
      the line responsible. Stop when you can tell me the cause — I'll decide what to \
      do about it.
      """)
  }

  // MARK: - Goal
  // Three, because Goal is the workhorse, and because its three lessons are separate:
  // a check that decides, no check at all, and a metric.

  static var getTheBuildGreen: PromptTemplate {
    starter(
      id("200000000001"), "Get the build green",
      """
      The build is failing. Find out why and fix it — the smallest change that works. \
      Don't refactor anything you weren't asked to.
      """,
      shape: .goalBased,
      // The token sits in the *done check*, not the brief: filling it is what teaches
      // that a Goal loop stops itself when a command says so, and that ⇥ walks every
      // field a template left a hole in.
      settings: TemplateSettings(doneCheck: "{test_command}"))
  }

  static var reviewTheDiff: PromptTemplate {
    starter(
      id("200000000002"), "Review the diff on this branch",
      """
      Review every file changed on {branch} against the conventions already in this \
      codebase. List what must change before merge, most important first, with \
      file:line. Don't fix anything — the list is the deliverable.
      """,
      // No done check on purpose: "a good review exists" is not a shell command, and
      // a Goal loop without one resolves when it has finished the work. The pair of
      // this and `getTheBuildGreen` is the lesson.
      shape: .goalBased)
  }

  static var raiseTestCoverage: PromptTemplate {
    starter(
      id("200000000003"), "Raise test coverage",
      """
      Add tests for the least-covered code in {area}. Cover the behaviour that would \
      actually break, not the lines that are cheapest to hit. Keep every existing \
      test passing.
      """,
      shape: .goalBased,
      settings: TemplateSettings(metric: "{coverage_command}"))
  }

  // MARK: - Timed
  // Both of these also demonstrate following: edit either file and the next run picks
  // the change up, which is the half of the design a card has to state.

  static var nightlyDependencyReview: PromptTemplate {
    starter(
      id("300000000001"), "Nightly dependency review",
      """
      Check for dependency updates worth taking. For each one: what changed, what it \
      would break here, and whether it's worth doing now. Say "nothing worth taking" \
      if that's the answer — a quiet night is a valid report.
      """,
      shape: .timeBased,
      settings: TemplateSettings(cadence: "daily"))
  }

  static var watchTheBuild: PromptTemplate {
    starter(
      id("300000000002"), "Watch the build",
      """
      Check whether the build on {branch} is passing. If it broke since last time, \
      find the commit responsible and say what it changed. If it's still green, say \
      so in one line and stop.
      """,
      shape: .timeBased,
      settings: TemplateSettings(cadence: "1h"))
  }

  // MARK: - Turn
  // The two pause rhythms, side by side — which is the only way the difference reads.

  static var portWithReview: PromptTemplate {
    starter(
      id("400000000001"), "Port {area} to {target}",
      """
      Port {area} to {target}. Work file by file. Before each file you change, tell me \
      what you're about to do and why.
      """,
      shape: .turnBased,
      settings: TemplateSettings(pausesBeforeWritesOnly: true))
  }

  static var pairOnThis: PromptTemplate {
    starter(
      id("400000000002"), "Pair on this",
      """
      Work through {task} with me one step at a time. After each step, stop and tell \
      me what you did and what you think comes next. I'll steer.
      """,
      shape: .turnBased,
      settings: TemplateSettings(pausesBeforeWritesOnly: false))
  }

  // MARK: - Composite

  /// Three loops and the two hand-offs between them, carried inside one file. This is
  /// the template that shows what a composite template is *for*: an orchestration
  /// somebody else can start from without drawing the graph.
  static var reviewFixVerify: PromptTemplate {
    let reviewer = LoopNode(
      title: "Reviewer", loopType: .goalBased,
      goal: GoalSpec(
        summary: """
          Review every file changed on {branch} and list what must change, most \
          important first, with file:line.
          """))
    let fixer = LoopNode(
      title: "Fixer", loopType: .goalBased,
      goal: GoalSpec(
        summary: """
          Work through the findings you were handed, most important first. Make the \
          smallest change that resolves each one.
          """))
    let verifier = LoopNode(
      title: "Verifier", loopType: .goalBased,
      goal: GoalSpec(
        summary: "Confirm nothing the fixer changed broke anything else.",
        predicate: "{test_command}"))
    var graph = LoopGraph(
      project: ProjectRef(path: "review-fix-verify", name: "Review, fix, verify"),
      nodes: [reviewer, fixer, verifier])
    graph.edges = [
      LoopEdge(from: reviewer.id, to: fixer.id, spec: EdgeSpec()),
      LoopEdge(from: fixer.id, to: verifier.id, spec: EdgeSpec()),
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
