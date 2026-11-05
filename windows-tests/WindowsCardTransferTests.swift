import Foundation
import GraphcodeKit
import XCTest

@testable import WindowsCardTransferCore

final class WindowsCardTransferTests: XCTestCase {
  private let invocation = UUID(uuidString: "B114D184-BDC8-4144-924F-F8EC26D1729C")!
  private let project = "C:\\synthetic\\transfer"

  private func arguments(
    _ operation: String = "import", node: UUID = UUID(), scope: String = "root"
  ) -> [String] {
    [
      "--windows-card-transfer", operation,
      "--invocation", invocation.uuidString,
      "--project", project, "--node", node.uuidString,
      "--containing-composite", scope,
      operation == "export" ? "--output" : "--input", "C:\\synthetic\\bundle.zip",
    ]
  }

  private func graph(nodes: [LoopNode]) -> LoopGraph {
    var graph = LoopGraph(project: ProjectRef(path: project, name: "Synthetic"))
    graph.nodes.append(contentsOf: nodes)
    return graph
  }

  private func failure(_ body: () throws -> Void) -> CardTransferFailure? {
    do {
      try body()
      XCTFail("Expected an explicit failure")
      return nil
    } catch let error as CardTransferFailure {
      return error
    } catch {
      XCTFail("Unexpected error: \(error)")
      return nil
    }
  }

  func testOrdinaryCLIArgumentsRemainUnclaimed() throws {
    for argv in [[], ["help"], ["node", "export", project, UUID().uuidString]] {
      XCTAssertNil(try CardTransferRequest.parse(argv))
    }
  }

  func testExportArgumentsPreserveUnicodeAndSpaces() throws {
    var argv = arguments("export")
    argv[5] = "C:\\synthetic\\My Project \u{96EA}"
    argv[11] = "C:\\synthetic\\My Bundle \u{96EA}.zip"
    argv.append("--replace-existing")
    let request = try XCTUnwrap(CardTransferRequest.parse(argv))
    XCTAssertEqual(request.projectPath, argv[5])
    XCTAssertEqual(request.zipPath, argv[11])
    XCTAssertTrue(request.replaceExisting)
    XCTAssertEqual(request.invocation, invocation)
  }

  func testImportArgumentsCaptureContainingComposite() throws {
    let owner = UUID()
    let request = try XCTUnwrap(
      CardTransferRequest.parse(arguments(scope: owner.uuidString.lowercased())))
    XCTAssertEqual(request.scope, .composite(owner))
    XCTAssertFalse(request.replaceExisting)
  }

  func testAbsoluteZIPPathsAcceptDriveUNCAndExtendedForms() throws {
    for path in [
      "C:\\synthetic\\bundle.zip", "\\\\server\\share\\bundle.zip",
      "\\\\?\\C:\\synthetic\\bundle.zip", "\\\\?\\UNC\\server\\share\\bundle.zip",
    ] {
      var argv = arguments()
      argv[11] = path
      XCTAssertEqual(try XCTUnwrap(CardTransferRequest.parse(argv)).zipPath, path)
    }
  }

  func testMalformedDuplicateAndCrossOperationArgumentsAreRefused() {
    var missing = arguments()
    missing.removeLast(2)
    var badNode = arguments()
    badNode[7] = "not-a-uuid"
    var badScope = arguments()
    badScope[9] = "ROOT"
    var relativeZIP = arguments()
    relativeZIP[11] = "relative.zip"
    var deviceZIP = arguments()
    deviceZIP[11] = "\\\\.\\pipe\\not-a-file.zip"
    for argv in [
      missing, badNode, badScope, relativeZIP, deviceZIP,
      arguments() + ["--replace-existing"],
      arguments() + ["--project", project],
      arguments() + ["--unknown", "value"],
      arguments() + ["--output", "C:\\synthetic\\other.zip"],
    ] {
      XCTAssertEqual(failure { _ = try CardTransferRequest.parse(argv) }?.status, .rejected)
    }
  }

  func testRootCardResolvesInItsContainingGraph() throws {
    let node = LoopNode(title: "Root", state: .succeeded)
    let original = graph(nodes: [node])
    let target = try CardTransferTarget.resolve(
      nodeID: node.id, expectedScope: .root, in: original)
    XCTAssertEqual(target.graph, original)
    XCTAssertNil(target.containingComposite)
  }

  func testNestedCardResolvesInContainingGraphNotItsOwnSubgraph() throws {
    let inner = LoopNode(title: "Inner")
    let card = LoopNode(title: "Nested composite", loopType: .composite, subGraph: graph(nodes: [inner]))
    let nested = graph(nodes: [card])
    let owner = LoopNode(title: "Owner", loopType: .composite, subGraph: nested)
    let target = try CardTransferTarget.resolve(
      nodeID: card.id, expectedScope: .composite(owner.id), in: graph(nodes: [owner]))
    XCTAssertEqual(target.graph, nested)
    XCTAssertEqual(target.graph.nodes.first?.id, card.id)
    XCTAssertEqual(target.containingComposite, owner.id)
  }

  func testDeepCardResolvesImmediateCompositeOwner() throws {
    let card = LoopNode(title: "Deep")
    let inner = LoopNode(title: "Inner", loopType: .composite, subGraph: graph(nodes: [card]))
    let outer = LoopNode(title: "Outer", loopType: .composite, subGraph: graph(nodes: [inner]))
    let target = try CardTransferTarget.resolve(
      nodeID: card.id, expectedScope: .composite(inner.id), in: graph(nodes: [outer]))
    XCTAssertEqual(target.containingComposite, inner.id)
    XCTAssertEqual(target.graph.nodes.map(\.id), [card.id])
  }

  func testMissingCardAndChangedContainingScopeAreRefused() {
    let card = LoopNode(title: "Card")
    let owner = LoopNode(title: "Owner", loopType: .composite, subGraph: graph(nodes: [card]))
    let root = graph(nodes: [owner])
    XCTAssertEqual(
      failure {
        _ = try CardTransferTarget.resolve(nodeID: card.id, expectedScope: .root, in: root)
      }?.status, .rejected)
    XCTAssertEqual(
      failure {
        _ = try CardTransferTarget.resolve(nodeID: UUID(), expectedScope: .root, in: root)
      }?.status, .rejected)
  }

  func testAmbiguousNodeIdentityIsRefused() {
    let card = LoopNode(title: "Duplicate identity")
    let owner = LoopNode(title: "Owner", loopType: .composite, subGraph: graph(nodes: [card]))
    XCTAssertEqual(
      failure {
        _ = try CardTransferTarget.resolve(
          nodeID: card.id, expectedScope: .root, in: graph(nodes: [card, owner]))
      }?.status, .rejected)
  }

  func testNestedImportWrapsExistingCommandAndPreservesParent() throws {
    let card = LoopNode(title: "Parent")
    let owner = LoopNode(title: "Owner", loopType: .composite, subGraph: graph(nodes: [card]))
    let target = try CardTransferTarget.resolve(
      nodeID: card.id, expectedScope: .composite(owner.id), in: graph(nodes: [owner]))
    let request = GraphImportRequest(snapshot: graph(nodes: [LoopNode(title: "Arriving")]), asChildOf: card.id)
    XCTAssertEqual(
      try target.importCommand(request),
      .subGraphCommand(nodeID: owner.id, command: .importNodes(request)))
  }

  func testRootImportKeepsCardParentAndRejectsAnotherParent() throws {
    let card = LoopNode(title: "Parent")
    let target = try CardTransferTarget.resolve(
      nodeID: card.id, expectedScope: .root, in: graph(nodes: [card]))
    let request = GraphImportRequest(snapshot: graph(nodes: [LoopNode(title: "Arriving")]), asChildOf: card.id)
    XCTAssertEqual(try target.importCommand(request), .importNodes(request))
    XCTAssertEqual(
      failure {
        _ = try target.importCommand(GraphImportRequest(snapshot: request.snapshot))
      }?.status, .rejected)
  }

  func testUnrelatedEventsAndResponsesCannotConfirmRequest() throws {
    let id = UUID()
    let snapshot = graph(nodes: [])
    for envelope in [
      DaemonWireEnvelope.event(sequence: 1, event: .graphChanged(snapshot)),
      .response(id: UUID(), event: .graphChanged(snapshot)),
      .error(id: UUID(), code: "requestFailed", message: "Other request"),
    ] {
      XCTAssertNil(
        try CardTransferWire.graphReply(
          JSONEncoder().encode(envelope), requestID: id, projectPath: project))
    }
  }

  func testOnlyMatchingGraphResponseConfirmsRequest() throws {
    let id = UUID()
    let snapshot = graph(nodes: [LoopNode(title: "Result")])
    let data = try JSONEncoder().encode(
      DaemonWireEnvelope.response(id: id, event: .graphChanged(snapshot)))
    XCTAssertEqual(
      try CardTransferWire.graphReply(data, requestID: id, projectPath: project), snapshot)
  }

  func testEmptySuccessAndWrongProjectResponsesAreNotConfirmation() throws {
    let id = UUID()
    let wrong = LoopGraph(project: ProjectRef(path: "C:\\synthetic\\other", name: "Other"))
    for envelope in [
      DaemonWireEnvelope.success(id: id),
      .response(id: id, event: .graphChanged(wrong)),
    ] {
      XCTAssertEqual(
        failure {
          _ = try CardTransferWire.graphReply(
            JSONEncoder().encode(envelope), requestID: id, projectPath: project)
        }?.status, .failed)
    }
  }

  func testCorrelatedRefusalAndOversizeHaveExplicitStatuses() throws {
    let id = UUID()
    for (message, status) in [
      ("import refused: missing parent", CardTransferStatus.rejected),
      ("resulting graph response exceeds the v2 payload limit", .oversized),
    ] {
      let data = try JSONEncoder().encode(
        DaemonWireEnvelope.error(id: id, code: "requestFailed", message: message))
      XCTAssertEqual(
        failure {
          _ = try CardTransferWire.graphReply(data, requestID: id, projectPath: project)
        }?.status, status)
    }
  }

  func testOversizedRequestIsRejectedBeforeTransport() {
    let huge = LoopNode(title: String(repeating: "x", count: FramedMessageIO.v2MaxPayloadBytes))
    let request = GraphImportRequest(snapshot: graph(nodes: [huge]))
    XCTAssertEqual(
      failure {
        _ = try CardTransferWire.request(
          id: UUID(), command: .graphCommand(projectPath: project, command: .importNodes(request)))
      }?.status, .oversized)
  }

  func testHelloRequiresV2AndDoesNotDowngrade() throws {
    try CardTransferWire.validateHello(
      JSONEncoder().encode(DaemonWireEnvelope.helloResponse(selectedVersion: 2)))
    XCTAssertEqual(
      failure {
        try CardTransferWire.validateHello(
          JSONEncoder().encode(DaemonWireEnvelope.helloResponse(selectedVersion: 1)))
      }?.status, .rejected)
  }

  func testTransportFailureAfterDispatchIsUnknownNotRetryable() {
    enum Closed: Error { case connection }
    XCTAssertEqual(
      CardTransferFailure.exchange(Closed.connection, mutationDispatched: true).status,
      .outcomeUnknown)
    XCTAssertEqual(
      CardTransferFailure.exchange(Closed.connection, mutationDispatched: false).status, .failed)
    let refusal = CardTransferFailure(status: .rejected, message: "Refused")
    XCTAssertEqual(
      CardTransferFailure.exchange(refusal, mutationDispatched: true).status, .rejected)
  }

  func testNonVerdictErrorCodesRemainUnknownAfterMutationDispatch() throws {
    let id = UUID()
    for code in ["malformedEnvelope", "connectionClosed", "transportFailure", "futureError"] {
      let data = try JSONEncoder().encode(DaemonWireEnvelope.error(
        id: id, code: code, message: "resulting graph response exceeds the v2 payload limit"))
      let error = try XCTUnwrap(failure {
        _ = try CardTransferWire.graphReply(data, requestID: id, projectPath: project)
      })
      XCTAssertEqual(error.status, .failed)
      XCTAssertEqual(CardTransferFailure.exchange(error, mutationDispatched: true).status, .outcomeUnknown)
      XCTAssertEqual(CardTransferFailure.exchange(error, mutationDispatched: false).status, .failed)
    }
  }

  func testLocalOnlyGuardStopsBeforeInjectedRuntimeOperations() {
    var runtimeCalls = 0
    for path in [
      LoopGraphScope.globalPath, "ssh://host/project", "codespace://example/workspaces/repo",
      "https://example.invalid/project", "relative-project",
    ] {
      XCTAssertEqual(failure {
        try CardTransferLocalProject.beforeRuntime(path) { runtimeCalls += 1 }
      }?.status, .rejected)
    }
    XCTAssertEqual(runtimeCalls, 0)
  }

  func testLocalDriveAndUNCGuardsPermitOnlyTheExplicitRuntimeClosure() throws {
    var calls: [String] = []
    for path in [project, "\\\\server\\share\\project"] {
      try CardTransferLocalProject.beforeRuntime(path) { calls.append(path) }
    }
    XCTAssertEqual(calls, [project, "\\\\server\\share\\project"])
  }

  func testActualRuntimePathConversionPreservesDriveUNCAndExtendedUnicode() throws {
    for (input, expected) in [
      ("C:/synthetic/\u{96EA}/bundle.zip", "\\\\?\\C:\\synthetic\\\u{96EA}\\bundle.zip"),
      ("\\\\server\\share\\\u{96EA}.zip", "\\\\?\\UNC\\server\\share\\\u{96EA}.zip"),
      ("\\\\?\\C:\\synthetic\\\u{96EA}.zip", "\\\\?\\C:\\synthetic\\\u{96EA}.zip"),
      ("\\\\?\\UNC\\server\\share\\\u{96EA}.zip", "\\\\?\\UNC\\server\\share\\\u{96EA}.zip"),
    ] {
      XCTAssertEqual(try CardTransferWindowsPath.extended(input), expected)
      XCTAssertEqual(
        try CardTransferWindowsPath.wide(URL(fileURLWithPath: input, isDirectory: false, relativeTo: nil)),
        Array(expected.utf16) + [0])
    }
    XCTAssertThrowsError(try CardTransferWindowsPath.extended("relative.zip"))
    XCTAssertThrowsError(try CardTransferWindowsPath.extended("\\\\.\\pipe\\not-a-file"))
  }

  func testNativeDriveDestinationKeepsExactOwnedParent() throws {
    let parent = FileManager.default.temporaryDirectory.appendingPathComponent(
      "graphcode-native-path-\(UUID().uuidString)", isDirectory: true)
    let expected = parent.appendingPathComponent("owned bundle.zip")
    let native = expected.path.replacingOccurrences(of: "/", with: "\\")
    let slash = native.replacingOccurrences(of: "\\", with: "/")
    for input in [native, slash] {
      let actual = URL(fileURLWithPath: input).standardizedFileURL
      XCTAssertEqual(
        try CardTransferWindowsPath.extended(actual.path),
        try CardTransferWindowsPath.extended(expected.path))
      XCTAssertEqual(
        try CardTransferWindowsPath.extended(actual.deletingLastPathComponent().path),
        try CardTransferWindowsPath.extended(parent.path))
      XCTAssertEqual(
        try CardTransferWindowsPath.wide(actual),
        try CardTransferWindowsPath.wide(expected))
      let representation = actual.withUnsafeFileSystemRepresentation { pointer in
        pointer.map { String(cString: $0) }
      }
      XCTAssertEqual(
        try CardTransferWindowsPath.extended(XCTUnwrap(representation)),
        try CardTransferWindowsPath.extended(expected.path))
    }
  }

  func testResultBindsInvocationScopeOperationAndExitCode() throws {
    let request = try XCTUnwrap(CardTransferRequest.parse(arguments()))
    for (status, exitCode) in [
      (CardTransferStatus.succeeded, Int32(0)), (.rejected, 1), (.oversized, 1),
      (.failed, 1), (.unavailable, 69), (.outcomeUnknown, 75),
    ] {
      let result = CardTransferResult(
        request: request, status: status, message: "Explicit result",
        sessionPreparationStarted: false)
      XCTAssertEqual(result.exitCode, exitCode)
      let line = try result.record()
      XCTAssertTrue(line.hasPrefix(CardTransferResult.prefix))
      let data = Data(line.dropFirst(CardTransferResult.prefix.count).utf8)
      let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(object["version"] as? Int, 1)
      XCTAssertEqual(object["invocation"] as? String, invocation.uuidString)
      XCTAssertEqual(object["containingComposite"] as? String, "root")
      XCTAssertEqual(object["operation"] as? String, "import")
      XCTAssertEqual(object["sessionPreparationStarted"] as? Bool, false)
    }
    let partial = CardTransferResult(
      request: request, status: .outcomeUnknown, message: "Check the graph; do not retry.",
      sessionPreparationStarted: true)
    XCTAssertTrue(partial.sessionPreparationStarted)
  }

  func testUnknownOutcomeRetainsItsWireCodeAndExitCode() throws {
    XCTAssertEqual(CardTransferStatus.outcomeUnknown.rawValue, "outcome_unknown")
    XCTAssertEqual(CardTransferStatus.outcomeUnknown.exitCode, 75)
    XCTAssertEqual(CardTransferStatus(rawValue: "outcome_unknown"), .outcomeUnknown)
    XCTAssertNil(CardTransferStatus(rawValue: "outcomeUnknown"))
    let result = CardTransferResult(
      request: nil, status: .outcomeUnknown, message: "Check the graph; do not retry.",
      sessionPreparationStarted: true)
    let line = try result.record()
    let data = Data(line.dropFirst(CardTransferResult.prefix.count).utf8)
    let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    XCTAssertEqual(object["status"] as? String, "outcome_unknown")
    XCTAssertEqual(result.exitCode, 75)
  }

  func testZIPFailureDoesNotReachDestinationCommit() {
    enum ZIPError: Error { case creation }
    var publication = CardTransferPublication()
    var destination = "original destination"
    var acquisitions = 0
    XCTAssertThrowsError(
      try publication.writeAndCommit(
        writeArchive: { throw ZIPError.creation }, acquireArchive: { acquisitions += 1 },
        validateOwnership: {}, commit: { destination = "new archive" }))
    XCTAssertEqual(destination, "original destination")
    XCTAssertEqual(acquisitions, 0)
    XCTAssertFalse(publication.hasArchiveReceipt)
    XCTAssertFalse(publication.committed)
  }

  func testMessageCapUsesUnicodeScalarsNotGraphemeClusters() throws {
    let request = try XCTUnwrap(CardTransferRequest.parse(arguments()))
    let text = String(repeating: "e\u{301}", count: 2048) + "\u{1F600}"
    let result = CardTransferResult(
      request: request, status: .failed, message: text, sessionPreparationStarted: false)
    XCTAssertEqual(result.message.unicodeScalars.count, 2048)
    XCTAssertEqual(result.message, String(text.unicodeScalars.prefix(2048)))
    XCTAssertNoThrow(try result.record())
  }

  func testExportSuccessRequiresSelectedOutputAndOtherStatusesOmitIt() throws {
    let request = try XCTUnwrap(CardTransferRequest.parse(arguments("export")))
    let invalidPaths: [String?] = [nil, "", "C:\\synthetic\\wrong.zip"]
    for path in invalidPaths {
      let result = CardTransferResult(
        request: request, status: .succeeded, message: "Exported",
        sessionPreparationStarted: false, outputPath: path)
      XCTAssertThrowsError(try result.record())
    }
    let success = CardTransferResult(
      request: request, status: .succeeded, message: "Exported",
      sessionPreparationStarted: false, outputPath: request.zipPath)
    XCTAssertNoThrow(try success.record())
    let failure = CardTransferResult(
      request: request, status: .failed, message: "Failed",
      sessionPreparationStarted: false, outputPath: request.zipPath)
    XCTAssertNil(failure.outputPath)
  }

  func testCommitRunsOnlyAfterCompleteZIPAndPropagatesFailure() {
    enum CommitError: Error { case refused }
    var calls: [String] = []
    var publication = CardTransferPublication()
    XCTAssertThrowsError(
      try publication.writeAndCommit(
        writeArchive: { calls.append("zip") },
        acquireArchive: { calls.append("acquire") },
        validateOwnership: { calls.append("validate") },
        commit: { calls.append("commit"); throw CommitError.refused }))
    XCTAssertEqual(calls, ["zip", "acquire", "validate", "commit"])
    XCTAssertTrue(publication.hasArchiveReceipt)
    XCTAssertFalse(publication.committed)
  }

  func testUnacquiredArchiveAndOldDestinationSurviveFailedOwnershipAcquisition() {
    enum Replaced: Error { case archive }
    var publication = CardTransferPublication()
    var files = ["destination": "old ZIP", "bundle.zip": "foreign replacement"]
    let original = files
    XCTAssertThrowsError(try publication.writeAndCommit(
      writeArchive: {}, acquireArchive: { throw Replaced.archive },
      validateOwnership: {}, commit: { files["destination"] = files.removeValue(forKey: "bundle.zip") }))
    XCTAssertThrowsError(try publication.cleanup { files.removeAll() })
    XCTAssertEqual(files, original)
    XCTAssertFalse(publication.hasArchiveReceipt)
  }

  func testReplacedArchiveReceiptRefusesCommitWithoutDeletingForeignFile() {
    let directory = CardTransferFileIdentity(volume: 1, index: 10)
    let archive = CardTransferFileIdentity(volume: 1, index: 20)
    let foreign = CardTransferFileIdentity(volume: 1, index: 30)
    let ownership = CardTransferOwnership(directory: directory, archive: archive)
    var publication = CardTransferPublication()
    var files = ["destination": "old ZIP", "bundle.zip": "foreign replacement"]
    let original = files
    XCTAssertThrowsError(try publication.writeAndCommit(
      writeArchive: {}, acquireArchive: {},
      validateOwnership: {
        try ownership.validate(
          directory: directory, archive: foreign, directoryIsReparse: false,
          archiveIsRegular: true, children: ["bundle.zip"])
      },
      commit: { files["destination"] = files.removeValue(forKey: "bundle.zip") }))
    XCTAssertThrowsError(try publication.cleanup { files.removeAll() })
    XCTAssertEqual(files, original)
  }

  func testUnexpectedArchiveAfterCommitSurvivesEmptyDirectoryCleanup() throws {
    let directory = CardTransferFileIdentity(volume: 1, index: 10)
    var publication = CardTransferPublication()
    try publication.writeAndCommit(
      writeArchive: {}, acquireArchive: {}, validateOwnership: {}, commit: {})
    var files = ["bundle.zip": "foreign new file"]
    XCTAssertThrowsError(try publication.cleanup {
      try CardTransferOwnership.removeEmptyDirectory(
        expected: directory, observed: directory, isReparse: false, children: Array(files.keys)
      ) { files.removeAll() }
    })
    XCTAssertEqual(files, ["bundle.zip": "foreign new file"])
  }

  func testChangedDirectoryReparseOrUnexpectedChildrenPreventCommit() {
    let directory = CardTransferFileIdentity(volume: 1, index: 10)
    let changed = CardTransferFileIdentity(volume: 1, index: 11)
    let archive = CardTransferFileIdentity(volume: 1, index: 20)
    let ownership = CardTransferOwnership(directory: directory, archive: archive)
    var commits = 0
    for (observed, reparse, regular, children) in [
      (changed, false, true, ["bundle.zip"]),
      (directory, true, true, ["bundle.zip"]),
      (directory, false, false, ["bundle.zip"]),
      (directory, false, true, ["bundle.zip", "foreign.txt"]),
    ] {
      var publication = CardTransferPublication()
      XCTAssertThrowsError(try publication.writeAndCommit(
        writeArchive: {}, acquireArchive: {},
        validateOwnership: {
          try ownership.validate(
            directory: observed, archive: archive, directoryIsReparse: reparse,
            archiveIsRegular: regular, children: children)
        },
        commit: { commits += 1 }))
      XCTAssertFalse(publication.committed)
    }
    XCTAssertEqual(commits, 0)
  }

  func testChangedOrReparseDirectoryCannotReachRemoval() {
    let expected = CardTransferFileIdentity(volume: 1, index: 10)
    let changed = CardTransferFileIdentity(volume: 1, index: 11)
    var removals = 0
    for (observed, reparse) in [(changed, false), (expected, true)] {
      XCTAssertThrowsError(try CardTransferOwnership.removeEmptyDirectory(
        expected: expected, observed: observed, isReparse: reparse, children: []
      ) { removals += 1 })
    }
    XCTAssertEqual(removals, 0)
  }
}
