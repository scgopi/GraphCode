import Foundation
import GraphcodeKit

// graphcode — the CLI half of docs/03-architecture.md#cli-graphcode.
//
// It talks to `graphcoded`, never to the app. That's the whole point: `graphcode node
// create …` has to behave identically whether or not a window happens to be open, which
// only holds if the socket target is the process that outlives the app.
//
// Parsing and rendering live in `GraphcodeKit.GraphcodeCommand` so they're unit-testable
// without spawning this binary; what's left here is the socket round-trip and exit codes.

/// Exit codes, so a caller can tell "you typed it wrong" from "graphcoded wasn't there"
/// from "it may well have been applied" — the distinction that decides whether retrying is
/// safe. Usage and daemon-reported errors stay on 1: that is what every existing caller
/// already treats as failure, and moving it would break them to say nothing new.
enum ExitCode {
  static let usage: Int32 = 1
  /// `EX_UNAVAILABLE`. graphcoded could not be reached and nothing was written, so
  /// retrying the whole command is safe.
  static let unavailable: Int32 = 69
  /// `EX_TEMPFAIL`. The command went out but its outcome never came back. It may have been
  /// applied — `node create`, `node send` and `node memo` are not idempotent, so this is
  /// the one case a wrapper must not blindly retry.
  static let ambiguous: Int32 = 75
}

func fail(_ message: String, code: Int32 = ExitCode.usage) -> Never {
  FileHandle.standardError.write(Data("graphcode: \(message)\n".utf8))
  exit(code)
}

let command: GraphcodeCommand
do {
  command = try GraphcodeCommand.parse(Array(CommandLine.arguments.dropFirst()))
} catch let error as GraphcodeCommand.ParseError {
  fail(GraphcodeCommand.describe(error))
} catch {
  fail("\(error)")
}

if case .help = command {
  print(GraphcodeCommand.helpText)
  exit(0)
}

// Also before the daemon: reap reads graphs from disk and talks to zmx directly, and
// the machine that needs it most — out of PTYs, daemon flailing — may not have a
// daemon to dial.
if case .reap(let dryRun) = command {
  final class Box: @unchecked Sendable { var report = OrphanedSessionReaper.Report() }
  let box = Box()
  let semaphore = DispatchSemaphore(value: 0)
  Task {
    box.report = await OrphanedSessionReaper.reap(dryRun: dryRun)
    semaphore.signal()
  }
  semaphore.wait()
  let report = box.report
  if let aborted = report.aborted { fail(aborted) }
  if report.orphans.isEmpty {
    print("no orphaned sessions")
  } else if dryRun {
    for orphan in report.orphans { print("orphan\t\(orphan)") }
    print("\(report.orphans.count) orphaned session(s) — run `graphcode reap` to kill them")
  } else {
    for name in report.reaped { print("reaped\t\(name)") }
    for name in report.survived { print("survived\t\(name) — kill it by hand: zmx kill \(name)") }
    print("freed \(report.reaped.count) of \(report.orphans.count) orphaned session(s)")
  }
  exit(report.survived.isEmpty ? 0 : 1)
}

let client: DaemonSocketClient
do {
  // Trigger synchronization deliberately restarts a graph-owned Goobers daemon after
  // replacing its config; its bounded stop + readiness window can exceed the original
  // ten-second CLI budget. This only changes how long the CLI waits for graphcoded's
  // acknowledgement — it does not retry a possibly-applied mutation.
  client = try DaemonSocketClient(timeout: 30)
} catch DaemonSocketClient.ClientError.daemonNotRunning {
  fail("graphcoded isn't running. Start it with `make daemon-install`.", code: ExitCode.unavailable)
} catch {
  fail("couldn't reach graphcoded: \(error)", code: ExitCode.unavailable)
}
defer { client.closeConnection() }

/// The calling loop's identity, when this CLI ran inside one — the `status` graph
/// render uses it for the board's "unread for you" line, the same attribution every
/// artifactory verb derives from `ZMX_SESSION`.
let artifactoryReader = SurfaceRef.nodeID(
  fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")

/// Joins the project every verb addresses, and stops here when the daemon refuses it.
///
/// A refusal — a path that names no folder, a remote project graphcode has never been
/// told about, a spelling of one it has — used to arrive as an event nobody was reading:
/// the wait for `.graphChanged` ran to the socket timeout and then reported the command
/// as *possibly applied*, when in fact nothing past the open had been sent. Reading the
/// error is what turns that into one line saying which path was wrong.
@discardableResult
func openProject(_ projectPath: String) throws -> LoopGraph? {
  try client.send(.openProject(path: projectPath))
  let opened = try client.waitForEvent {
    switch $0 {
    case .graphChanged, .errorOccurred: return true
    case .recentProjectsListed: return false
    }
  }
  if case .errorOccurred(let message) = opened { fail(message) }
  if case .graphChanged(let graph) = opened { return graph }
  return nil
}

/// Every mutating verb waits for the `.graphChanged` broadcast its own command caused,
/// then prints the resulting graph. That's the daemon's only acknowledgement — it has no
/// request/response correlation — and it doubles as useful output.
///
/// A read-only verb (`status`, which passes no commands) has to stop after the snapshot
/// `.openProject` already replied with: nothing further was sent, so nothing further will
/// be broadcast, and waiting for a second event blocks forever. That hang used to hide on
/// a busy project, where an unrelated broadcast — a presence or usage update from some
/// other loop — would arrive and be mistaken for the acknowledgement, so `status`
/// appeared to work and hung only on quiet projects.
func runAndPrintGraph(projectPath: String, _ commands: [DaemonCommand]) throws {
  let opened = try openProject(projectPath)

  guard !commands.isEmpty else {
    if let opened {
      print(GraphcodeCommand.render(opened, artifactoryReader: artifactoryReader))
    }
    return
  }

  for command in commands {
    try client.send(command)
  }
  let event = try client.waitForEvent {
    if case .graphChanged = $0 { return true } else { return false }
  }
  if case .graphChanged(let graph) = event {
    print(GraphcodeCommand.render(graph, artifactoryReader: artifactoryReader))
  }
}

do {
  switch command {
  case .help:
    break

  case .listProjects:
    try client.send(.listRecentProjects)
    let event = try client.waitForEvent {
      if case .recentProjectsListed = $0 { return true } else { return false }
    }
    if case .recentProjectsListed(let projects) = event {
      print(GraphcodeCommand.render(projects))
    }

  case .status(let projectPath):
    try runAndPrintGraph(projectPath: projectPath, [])

  case .createNode(let projectPath, let draft, let into):
    // A loop that fans work out into more loops is the origin of them, and the graph
    // should show that rather than five entry points that appeared from nowhere. `zmx`
    // injects `ZMX_SESSION` into every session it starts and graphcode names sessions
    // after the node id, so when this command is run *from inside a loop* we can work out
    // which loop without the agent having to pass anything. Run from a human's shell there
    // is no such variable, and the node is correctly parentless.
    var attributed = draft
    attributed.createdBy =
      SurfaceRef.nodeID(
        fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    // On stderr so stdout stays the rendered graph a script may be parsing.
    for warning in GraphcodeCommand.createWarnings(for: attributed) {
      FileHandle.standardError.write(Data("\(warning)\n".utf8))
    }
    // Named a composite, and the very same command is addressed at its sub-graph
    // instead — which is what makes the CLI able to build one at all. Without this
    // there was no surface anywhere that could put a loop inside a composite, so the
    // type could be created and never filled.
    let create = GraphCommand.createNode(attributed)
    try runAndPrintGraph(
      projectPath: projectPath,
      [
        .graphCommand(
          projectPath: projectPath,
          command: into.map { .subGraphCommand(nodeID: $0, command: create) } ?? create)
      ])

  case .createEdge(let projectPath, let from, let to, let spec):
    try runAndPrintGraph(
      projectPath: projectPath,
      [
        .graphCommand(
          projectPath: projectPath, command: .createEdge(from: from, to: to, spec: spec))
      ]
    )

  case .stopNode(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .stopNode(nodeID))])

  case .restartNode(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .restartNode(nodeID))])

  case .restartSessions(let projectPath):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .restartSessions)])

  case .setGraphExecutionMode(let projectPath, let mode):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .setExecutionMode(mode))])

  case .runGoobersGraph(let projectPath):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .runGoobers)])

  case .addGraphSchedule(let projectPath, let expression):
    try runAndPrintGraph(
      projectPath: projectPath,
      [
        .graphCommand(
          projectPath: projectPath,
          command: .addGoobersTrigger(.schedule(expression)))
      ])

  case .addGraphWebhook(let projectPath, let events):
    try runAndPrintGraph(
      projectPath: projectPath,
      [
        .graphCommand(
          projectPath: projectPath,
          command: .addGoobersTrigger(.webhook(events: events)))
      ])

  case .clearGraphTriggers(let projectPath):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .clearGoobersTriggers)])

  case .deleteNode(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .deleteNode(nodeID))])

  case .sendMessage(let projectPath, let nodeID, let text, let followUp):
    // Attributed the same way `node create` attributes `createdBy`: run from inside a
    // loop, ZMX_SESSION names the sender, and the target sees who's talking.
    let sender = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath,
        command: .messageNode(nodeID, text: text, from: sender, followUp: followUp)))
    // Delivery is judged and attempted before the daemon broadcasts, so the first event
    // back is the verdict: an error means it did not land, the graph means it did.
    let verdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = verdict { fail(message) }
    // A follow-up to a busy loop is accepted, not typed: it's in the loop's memory now
    // and its session hears it when it next goes idle — "delivered" would overclaim.
    print(followUp ? "accepted — typed in when the loop next goes idle" : "delivered")

  case .updateNode(let projectPath, let nodeID, let update):
    // Attributed like `node create`/`node send`: run from inside a loop, ZMX_SESSION
    // names the author — which is also what lets the daemon refuse a loop loosening
    // its own stop condition.
    var attributed = update
    attributed.updatedBy = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    let opened = try openProject(projectPath)
    // The same advice `node create` prints — turning the flag on from `update` is the
    // same surprise. Best-effort: the node must be visible at the top level.
    if let graph = opened {
      for warning in GraphcodeCommand.updateWarnings(
        for: attributed, currentNode: graph.nodes.first(where: { $0.id == nodeID }))
      {
        FileHandle.standardError.write(Data("\(warning)\n".utf8))
      }
    }
    try client.send(
      .graphCommand(
        projectPath: projectPath, command: .updateNode(nodeID, update: attributed)))
    // A refusal arrives as an error, an applied update as the changed graph — wait for
    // whichever comes first so `update` can't print a graph that ignored it.
    let updateVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = updateVerdict { fail(message) }
    if case .graphChanged(let graph) = updateVerdict {
      print(GraphcodeCommand.render(graph, artifactoryReader: artifactoryReader))
    }

  case .promoteNode(let projectPath, let nodeID, let promotion):
    // Attributed like `node update` attributes `updatedBy` — which is also what lets
    // the daemon refuse a loop handing itself a stop condition through promotion.
    let promoter = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath,
        command: .promoteNode(nodeID, promotion: promotion, promotedBy: promoter)))
    // Same verdict pattern as `update`: a refusal arrives as an error, an applied
    // promotion as the changed graph.
    let promoteVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = promoteVerdict { fail(message) }
    if case .graphChanged(let graph) = promoteVerdict {
      print(GraphcodeCommand.render(graph, artifactoryReader: artifactoryReader))
    }

  case .memoNode(let projectPath, let nodeID, let text):
    let author = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath, command: .memoNode(nodeID, text: text, from: author)))
    let memoVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = memoVerdict { fail(message) }
    print("noted")

  case .refineNode(let projectPath, let nodeID, let text):
    let refiner = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath, command: .refineNode(nodeID, text: text, from: refiner)))
    let refineVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = refineVerdict { fail(message) }
    print("refined — the next wake works from the new playbook")

  case .rollbackRefinement(let projectPath, let nodeID):
    let requester = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath, command: .rollbackRefinement(nodeID, from: requester)))
    let rollbackVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = rollbackVerdict { fail(message) }
    print("rolled back to the previous playbook")

  case .pilotComposite(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .pilotComposite(nodeID))])

  case .armComposite(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .armComposite(nodeID))])

  case .artifactoryPost(let projectPath, let topic, let text):
    // Attributed like `node send`: run from inside a loop, ZMX_SESSION names the
    // sender and readers see who posted; from a human's shell there is no variable
    // and the note reads as from "a human" — which is exactly the human's voice on
    // the board.
    let author = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath,
        command: .artifactoryPost(text: text, topic: topic, from: author)))
    let postVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = postVerdict { fail(message) }
    if case .graphChanged(let graph) = postVerdict {
      print(GraphcodeCommand.renderPosted(graph))
    }

  case .artifactorySync(let projectPath, let headlines, let mark, let json, let full):
    // Attributed like `node send` — and required, the one place an artifactory verb
    // refuses a human shell up front: the cursor is the calling loop's, so with no
    // ZMX_SESSION there is nobody to advance it for, and the daemon's refusal would
    // arrive only after the round trip. Reading without a cursor is `artifactory list`.
    let reader = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    guard let reader else {
      fail(
        "artifactory sync needs a loop identity — run it from inside a loop's session "
          + "($ZMX_SESSION); a human reading the board wants `graphcode artifactory list`")
    }
    let opened = try openProject(projectPath)
    try client.send(
      .graphCommand(projectPath: projectPath, command: .artifactorySync(from: reader)))
    let syncVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = syncVerdict { fail(message) }
    // Unread is computed from the snapshot `openProject` already delivered: sync only
    // moves the cursor, so the posts it covers are exactly those above the cursor
    // there. Known race, accepted: a post landing between that snapshot and the
    // daemon advancing the cursor is marked read without ever having been printed.
    // The window is one round-trip wide and a watcher would have heard the post live
    // anyway; fixing it properly means syncing to the highest *printed* id rather
    // than to latest, which nothing so far has needed.
    if let graph = opened {
      if json {
        print(GraphcodeCommand.renderArtifactoryJSON(graph, unreadFor: reader))
      } else if mark {
        // The quiet sync: the backlog is not the loop's problem any more, and the
        // one line says the cursor actually moved — a silent success would read,
        // to the loop that sent it, like a command nobody applied.
        if let latest = graph.artifactory.last?.id, latest > 0 {
          print("marked read up to #\(latest)")
        } else {
          print("marked read — the board is empty")
        }
      } else {
        // `autoTriage` unless the caller said which way they want it: a loop cannot
        // know how much mail it has before reading it, and the first sync of a loop
        // born after a busy week is the whole board.
        print(
          GraphcodeCommand.renderArtifactory(
            graph, unreadFor: reader, headlines: headlines,
            autoTriage: !headlines && !full))
      }
    }

  case .artifactoryRead(let projectPath, let postID):
    // Read-only: the post rides the snapshot, no command is sent, no cursor moves —
    // the deep-read half of `sync --headlines` triage, priced at one line of context
    // per post a loop actually decides to care about.
    if let graph = try openProject(projectPath) {
      guard let post = graph.artifactory.first(where: { $0.id == postID }) else {
        fail(
          "no post #\(postID) on this board — `graphcode artifactory list \(projectPath)` "
            + "shows the ids that exist")
      }
      print(GraphcodeCommand.render(post))
    }

  case .artifactoryList(let projectPath, let search, let json):
    // Read-only: no command is sent, so — the `status` rule — nothing past the
    // snapshot is waited for, and no cursor moves. This is the human's window onto
    // the board; `sync` is the loop's. `--search` filters what is shown, never what
    // is remembered.
    if let graph = try openProject(projectPath) {
      if json {
        print(GraphcodeCommand.renderArtifactoryJSON(graph, search: search))
      } else {
        print(GraphcodeCommand.renderArtifactory(graph, search: search))
      }
    }

  case .artifactoryWatch(let projectPath, let on, let topic):
    // Attributed like `node send` — and required like `sync`: the subscription is
    // the calling loop's, because the mail is delivered to a session, not a shell.
    let watcher = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    guard let watcher else {
      fail(
        "artifactory watch needs a loop identity — run it from inside a loop's session "
          + "($ZMX_SESSION); the mail is delivered to the loop that watches")
    }
    try openProject(projectPath)
    try client.send(
      .graphCommand(
        projectPath: projectPath,
        command: .artifactoryWatch(on: on, topic: topic, from: watcher)))
    let watchVerdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = watchVerdict { fail(message) }
    if on {
      print(
        topic.map { "watching '\($0)' — matching posts are typed in when the loop goes idle" }
          ?? "watching all posts — they are typed in when the loop goes idle")
    } else {
      print("stopped watching")
    }

  case .reap:
    break  // handled before the daemon dial above

  case .usage(let projectPath):
    // Refresh first: usage is pulled on demand rather than polled, so printing without
    // asking would show whatever was last read, which could be nothing at all.
    try openProject(projectPath)
    try client.send(.graphCommand(projectPath: projectPath, command: .refreshUsage))
    let event = try client.waitForEvent {
      if case .graphChanged = $0 { return true } else { return false }
    }
    if case .graphChanged(let graph) = event {
      print(GraphcodeCommand.renderUsage(graph))
    }

  case .exportNode(let projectPath, let nodeID, let output, let includeChildren):
    guard let graph = try openProject(projectPath) else { fail("Could not load graph") }

    let persistence = ProjectPersistence(baseDirectory: SupportDirectory.url)
    guard
      let bundle = persistence.createExportBundle(
        for: [nodeID],
        from: graph,
        projectPath: projectPath,
        includeChildren: includeChildren,
        createdBy: ProcessInfo.processInfo.environment["USER"]
      )
    else { fail("Could not create export bundle") }

    guard let zipPath = bundle.writeToZip(at: output) else {
      fail("Could not write ZIP file to \(output)")
    }

    print("Exported to \(zipPath)")
    print("Nodes: \(bundle.manifest.contents.nodeIDs.count)")
    print("Memory logs: \(bundle.memoryByNodeID.count)")

  case .exportGraph(let projectPath, let output):
    guard let graph = try openProject(projectPath) else { fail("Could not load graph") }

    let persistence = ProjectPersistence(baseDirectory: SupportDirectory.url)
    let bundle = persistence.createFullGraphExportBundle(
      for: graph,
      projectPath: projectPath,
      createdBy: ProcessInfo.processInfo.environment["USER"]
    )

    guard let zipPath = bundle.writeToZip(at: output) else {
      fail("Could not write ZIP file to \(output)")
    }

    print("Exported full graph to \(zipPath)")
    print("Nodes: \(bundle.manifest.contents.nodeIDs.count)")
    print("Edges: \(graph.edges.count)")
    print("Memory logs: \(bundle.memoryByNodeID.count)")

  case .importNodes(let projectPath, let fromZip, let asChildOf):
    guard let bundle = GraphExportBundle.readFromZip(at: fromZip) else {
      fail("couldn't read an export bundle from \(fromZip)")
    }

    // Re-identified here so any carried sessions install under the fresh ids before
    // the request goes out; the daemon still performs the graph merge — it owns the
    // live graph, and a client that wrote the graph file itself had its import
    // clobbered by the daemon's next save. Same verdict pattern as `node send`: an
    // error event means refused, the changed graph means it landed. Async behind a
    // semaphore, the `reap` pattern: a remote target's sessions are delivered over
    // ssh, and the delivery has to finish before the daemon can ensure the loops.
    final class PreparedBox: @unchecked Sendable {
      var value: (request: GraphImportRequest, resumingSessions: Int)?
    }
    let box = PreparedBox()
    let prepared = DispatchSemaphore(value: 0)
    Task {
      box.value = await bundle.preparedImportRequest(
        asChildOf: asChildOf, projectPath: projectPath)
      prepared.signal()
    }
    prepared.wait()
    guard let (request, resumingSessions) = box.value else {
      fail("the bundle contains no loops")
    }
    try openProject(projectPath)
    try client.send(
      .graphCommand(projectPath: projectPath, command: .importNodes(request)))
    let verdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = verdict { fail(message) }
    if case .graphChanged(let graph) = verdict {
      // The count of sessions actually installed — on this machine or, for a remote
      // target, delivered to the host over ssh — not of sessions the bundle carried.
      print(
        "imported \(bundle.graphSnapshot.nodes.count) loop(s) "
          + "and \(bundle.graphSnapshot.edges.count) edge(s) with fresh identities"
          + (resumingSessions == 0
            ? "" : "; \(resumingSessions) will resume their exported conversations"))
      print(GraphcodeCommand.render(graph, artifactoryReader: artifactoryReader))
    }
  }
} catch DaemonSocketClient.ClientError.timedOut {
  // Reached only if the daemon accepted the command and then never broadcast anything —
  // so the useful thing to say is that the command may well have been applied, rather
  // than implying it failed.
  fail(
    """
    timed out waiting for graphcoded to answer. The command may still have been applied — \
    check with `graphcode status`.
    """, code: ExitCode.ambiguous)
} catch FramedMessageIO.IOError.connectionClosed {
  // graphcoded went away mid-exchange — a restart landing between the write and the
  // broadcast. Whether it applied the command first is not knowable from here, and the
  // mutating verbs are not idempotent, so this says "check" rather than "retry".
  fail(
    """
    graphcoded closed the connection before answering. The command may still have been \
    applied — check with `graphcode status` rather than re-running it.
    """, code: ExitCode.ambiguous)
} catch {
  fail("\(error)")
}
