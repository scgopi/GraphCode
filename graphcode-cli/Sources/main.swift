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

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("graphcode: \(message)\n".utf8))
  exit(1)
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

let client: DaemonSocketClient
do {
  client = try DaemonSocketClient()
} catch DaemonSocketClient.ClientError.daemonNotRunning {
  fail("graphcoded isn't running. Start it with `make daemon-install`.")
} catch {
  fail("couldn't reach graphcoded: \(error)")
}
defer { client.closeConnection() }

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
  try client.send(.openProject(path: projectPath))
  let opened = try client.waitForEvent {
    if case .graphChanged = $0 { return true } else { return false }
  }

  guard !commands.isEmpty else {
    if case .graphChanged(let graph) = opened {
      print(GraphcodeCommand.render(graph))
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
    print(GraphcodeCommand.render(graph))
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

  case .deleteNode(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .deleteNode(nodeID))])

  case .sendMessage(let projectPath, let nodeID, let text):
    // Attributed the same way `node create` attributes `createdBy`: run from inside a
    // loop, ZMX_SESSION names the sender, and the target sees who's talking.
    let sender = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try client.send(.openProject(path: projectPath))
    _ = try client.waitForEvent { if case .graphChanged = $0 { return true } else { return false } }
    try client.send(
      .graphCommand(
        projectPath: projectPath,
        command: .messageNode(nodeID, text: text, from: sender)))
    // Delivery is judged and attempted before the daemon broadcasts, so the first event
    // back is the verdict: an error means it did not land, the graph means it did.
    let verdict = try client.waitForEvent { event in
      switch event {
      case .graphChanged, .errorOccurred: return true
      default: return false
      }
    }
    if case .errorOccurred(let message) = verdict { fail(message) }
    print("delivered")

  case .updateNode(let projectPath, let nodeID, let update):
    // Attributed like `node create`/`node send`: run from inside a loop, ZMX_SESSION
    // names the author — which is also what lets the daemon refuse a loop loosening
    // its own stop condition.
    var attributed = update
    attributed.updatedBy = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try client.send(.openProject(path: projectPath))
    _ = try client.waitForEvent { if case .graphChanged = $0 { return true } else { return false } }
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
      print(GraphcodeCommand.render(graph))
    }

  case .memoNode(let projectPath, let nodeID, let text):
    let author = SurfaceRef.nodeID(
      fromZmxSessionName: ProcessInfo.processInfo.environment["ZMX_SESSION"] ?? "")
    try client.send(.openProject(path: projectPath))
    _ = try client.waitForEvent { if case .graphChanged = $0 { return true } else { return false } }
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

  case .pilotComposite(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .pilotComposite(nodeID))])

  case .armComposite(let projectPath, let nodeID):
    try runAndPrintGraph(
      projectPath: projectPath,
      [.graphCommand(projectPath: projectPath, command: .armComposite(nodeID))])

  case .usage(let projectPath):
    // Refresh first: usage is pulled on demand rather than polled, so printing without
    // asking would show whatever was last read, which could be nothing at all.
    try client.send(.openProject(path: projectPath))
    _ = try client.waitForEvent { if case .graphChanged = $0 { return true } else { return false } }
    try client.send(.graphCommand(projectPath: projectPath, command: .refreshUsage))
    let event = try client.waitForEvent {
      if case .graphChanged = $0 { return true } else { return false }
    }
    if case .graphChanged(let graph) = event {
      print(GraphcodeCommand.renderUsage(graph))
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
    """)
} catch {
  fail("\(error)")
}
