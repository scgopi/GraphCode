import ComposableArchitecture
import Foundation
import Testing

@testable import GraphcodeKit

/// Issue #819: an image pasted on the Mac reaches the machine a remote loop runs on as a
/// file the agent there can open. The writer is run for real against a fake `HOME`;
/// only the ssh hop is replaced.
@Suite
struct RemoteAttachmentUploadTests {
  private let nodeID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
  private let sshProject = "ssh://dev@build-box:2222/home/dev/widget"

  /// Every byte a naive text path would mangle: NUL, invalid UTF-8, newlines, shell
  /// metacharacters.
  private let awkwardBytes = Data(
    [0x89, 0x50, 0x4E, 0x47, 0x00, 0x0A, 0x0D, 0xFF, 0xFE, 0xC3, 0x28]
      + Array("'$(rm -rf ~)`\"\n".utf8) + (0...255).map(UInt8.init))

  private struct WriterRun {
    var status: Int32
    var stdout: String
    var home: URL
  }

  private func runWriter(
    sending input: Data, declaredCount: Int? = nil, declaredDigest: String? = nil,
    fileName: String = "paste-1.png"
  ) throws -> WriterRun {
    let home = FileManager.default.temporaryDirectory
      .appendingPathComponent("rau-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
    let destination =
      RemoteAttachmentUpload.attachmentsDirectory(forProjectPath: sshProject, nodeID: nodeID)
      + "/" + fileName
    let command = RemoteAttachmentUpload.writerCommand(
      destination: destination, byteCount: declaredCount ?? input.count,
      sha256: declaredDigest ?? GraphcodeSHA256.hex(input))
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/sh")
    process.arguments = ["-c", command]
    var environment = ProcessInfo.processInfo.environment
    environment["HOME"] = home.path
    process.environment = environment
    let stdin = Pipe()
    let stdout = Pipe()
    process.standardInput = stdin
    process.standardOutput = stdout
    process.standardError = FileHandle.nullDevice
    try process.run()
    stdin.fileHandleForWriting.write(input)
    try stdin.fileHandleForWriting.close()
    let output = stdout.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return WriterRun(
      status: process.terminationStatus, stdout: String(decoding: output, as: UTF8.self),
      home: home)
  }

  private func attachmentsDirectory(in home: URL) -> URL {
    home.appendingPathComponent(
      String(
        RemoteAttachmentUpload.attachmentsDirectory(forProjectPath: sshProject, nodeID: nodeID)
          .dropFirst(2)), isDirectory: true)
  }

  @Test
  func theWriterLandsExactBytesPrivatelyAndPrintsTheAbsolutePath() throws {
    let run = try runWriter(sending: awkwardBytes)
    defer { try? FileManager.default.removeItem(at: run.home) }
    #expect(run.status == 0)
    let file = attachmentsDirectory(in: run.home).appendingPathComponent("paste-1.png")
    #expect(try Data(contentsOf: file) == awkwardBytes)
    let result = ProcessResult(
      exitCode: 0, standardOutput: Data(run.stdout.utf8), standardError: Data())
    let published = try RemoteAttachmentUpload.publishedPath(from: result)
    #expect(
      URL(fileURLWithPath: published).resolvingSymlinksInPath().path
        == file.resolvingSymlinksInPath().path)
    let fileMode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions]
    #expect((fileMode as? NSNumber)?.intValue == 0o600)
    let folderMode = try FileManager.default.attributesOfItem(
      atPath: attachmentsDirectory(in: run.home).path)[.posixPermissions]
    #expect((folderMode as? NSNumber)?.intValue == 0o700)
  }

  @Test
  func aCorruptedTransferPublishesNothingAndLeavesNoTemporaryFile() throws {
    let run = try runWriter(
      sending: awkwardBytes, declaredDigest: String(repeating: "0", count: 64))
    defer { try? FileManager.default.removeItem(at: run.home) }
    #expect(run.status != 0)
    #expect(!run.stdout.contains(RemoteAttachmentUpload.pathMarker))
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: attachmentsDirectory(in: run.home).path)
    #expect(leftovers.isEmpty)
  }

  @Test
  func aCutOffTransferPublishesNothing() throws {
    let run = try runWriter(sending: awkwardBytes.prefix(40), declaredCount: awkwardBytes.count)
    defer { try? FileManager.default.removeItem(at: run.home) }
    #expect(run.status != 0)
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: attachmentsDirectory(in: run.home).path)
    #expect(leftovers.isEmpty)
  }

  @Test
  func extraBytesPastTheDeclaredCountAreRefused() throws {
    let run = try runWriter(
      sending: awkwardBytes + Data([1, 2, 3]), declaredCount: awkwardBytes.count,
      declaredDigest: GraphcodeSHA256.hex(awkwardBytes))
    defer { try? FileManager.default.removeItem(at: run.home) }
    #expect(run.status != 0)
    let leftovers = try FileManager.default.contentsOfDirectory(
      atPath: attachmentsDirectory(in: run.home).path)
    #expect(leftovers.isEmpty)
  }

  @Test
  func theRequestCarriesTheBytesOnStdinAndOnlyMetadataInArgv() throws {
    let request = try RemoteAttachmentUpload.request(
      awkwardBytes, fileName: "paste-1.png", projectPath: sshProject, nodeID: nodeID)
    #expect(request.standardInput == awkwardBytes)
    let argv = [request.executable.path] + request.arguments
    #expect(argv.contains("-p"))
    #expect(argv.contains("2222"))
    #expect(argv.contains("dev@build-box"))
    let remote = try #require(argv.last)
    #expect(remote.contains(GraphcodeSHA256.hex(awkwardBytes)))
    #expect(remote.contains("/attachments/paste-1.png"))
    #expect(remote.contains(nodeID.uuidString))
    #expect(!remote.contains("rm -rf ~)"))
  }

  @Test(arguments: [
    "ssh://build-box/srv/widget",
    "ssh://dev@build-box/srv/widget",
    "ssh://dev@build-box:2222/srv/widget",
    "ssh://dev@[fe80::1]:2222/srv/widget",
    "codespace://fluffy-space-umbrella/workspaces/widget",
  ])
  func everyKindOfHostGoesThroughItsOwnSSHInvocation(projectPath: String) throws {
    let location = try #require(RemoteProjectLocation.parse(projectPath: projectPath))
    let request = try RemoteAttachmentUpload.request(
      Data([1, 2, 3]), fileName: "paste-1.png", projectPath: projectPath, nodeID: nodeID)
    let argv = [request.executable.path] + request.arguments
    let expected = location.sshInvocation(remoteCommand: try #require(argv.last))
    #expect(argv == expected)
  }

  @Test
  func theMultiplexedCodespaceDialIsTheSameInvocation() throws {
    let location = try #require(
      RemoteProjectLocation.parse(projectPath: "codespace://fluffy-space-umbrella/workspaces/w"))
    let command = RemoteAttachmentUpload.writerCommand(
      destination: "~/.graphcode/memory/x/attachments/paste-1.png", byteCount: 3,
      sha256: GraphcodeSHA256.hex(Data([1, 2, 3])))
    let argv = location.sshInvocation(
      remoteCommand: location.remoteLoginShellCommand(command), interactive: false,
      codespaceUser: "codespace")
    #expect(argv.contains("cs.fluffy-space-umbrella"))
    #expect(argv.last == location.remoteLoginShellCommand(command))
  }

  @Test
  func refusesWhatShouldNeverBeDialedWith() {
    #expect(throws: RemoteAttachmentUploadError.notRemote) {
      try RemoteAttachmentUpload.request(
        Data([1]), fileName: "a.png", projectPath: "/Users/dev/widget", nodeID: nodeID)
    }
    for name in ["a.exe", "../a.png", ".png", "a b.png", "a/b.png", "a.png;rm"] {
      #expect(throws: RemoteAttachmentUploadError.unsupportedImage) {
        try RemoteAttachmentUpload.request(
          Data([1]), fileName: name, projectPath: sshProject, nodeID: nodeID)
      }
    }
    #expect(throws: RemoteAttachmentUploadError.unsupportedImage) {
      try RemoteAttachmentUpload.request(
        Data(), fileName: "a.png", projectPath: sshProject, nodeID: nodeID)
    }
    #expect(throws: RemoteAttachmentUploadError.tooLarge) {
      try RemoteAttachmentUpload.request(
        Data(count: RemoteAttachmentUpload.maximumBytes + 1), fileName: "a.png",
        projectPath: sshProject, nodeID: nodeID)
    }
    #expect(
      (try? RemoteAttachmentUpload.request(
        Data(count: RemoteAttachmentUpload.maximumBytes), fileName: "a.png",
        projectPath: sshProject, nodeID: nodeID)) != nil)
  }

  @Test
  func thePathIsFoundPastLoginShellNoise() throws {
    let output = "Welcome to build-box\n\(RemoteAttachmentUpload.pathMarker)/home/dev/a.png\n"
    let path = try RemoteAttachmentUpload.publishedPath(
      from: ProcessResult(exitCode: 0, standardOutput: Data(output.utf8), standardError: Data()))
    #expect(path == "/home/dev/a.png")
  }

  @Test
  func failuresSayWhatWentWrong() {
    #expect(throws: RemoteAttachmentUploadError.unreachable("Permission denied (publickey).")) {
      try RemoteAttachmentUpload.publishedPath(
        from: ProcessResult(
          exitCode: 255, standardOutput: Data(),
          standardError: Data("Permission denied (publickey).\n".utf8)))
    }
    #expect(throws: RemoteAttachmentUploadError.failed("graphcode: the image arrived corrupted")) {
      try RemoteAttachmentUpload.publishedPath(
        from: ProcessResult(
          exitCode: 1, standardOutput: Data(),
          standardError: Data("graphcode: the image arrived corrupted\n".utf8)))
    }
  }

  private struct RecordingRunner: ProcessRunner {
    let recorded: LockIsolated<[ProcessRequest]>
    let result: ProcessResult
    func run(_ request: ProcessRequest, timeout: Duration?) async throws -> ProcessResult {
      recorded.withValue { $0.append(request) }
      return result
    }
  }

  @Test
  func uploadRunsOneProcessAndReturnsTheRemotePath() async throws {
    let recorded = LockIsolated<[ProcessRequest]>([])
    let runner = RecordingRunner(
      recorded: recorded,
      result: ProcessResult(
        exitCode: 0,
        standardOutput: Data("\(RemoteAttachmentUpload.pathMarker)/home/dev/x.png\n".utf8),
        standardError: Data()))
    let path = try await RemoteAttachmentUpload.upload(
      awkwardBytes, fileName: "paste-1.png", projectPath: sshProject, nodeID: nodeID,
      runner: runner)
    #expect(path == "/home/dev/x.png")
    #expect(recorded.value.count == 1)
    #expect(recorded.value.first?.standardInput == awkwardBytes)
  }

  @Test
  func removalTargetsOnlyTheNodesRemoteMemory() throws {
    let argv = try #require(
      RemoteAttachmentUpload.removalInvocation(forProjectPath: sshProject, nodeID: nodeID))
    let command = try #require(argv.last)
    #expect(command.hasPrefix("rm -rf ~/'.graphcode/memory/"))
    #expect(command.hasSuffix("/\(nodeID.uuidString)'"))
    #expect(
      RemoteAttachmentUpload.removalInvocation(forProjectPath: "/Users/dev/w", nodeID: nodeID)
        == nil)
  }

  @Test
  func everyRemoteLaunchGrantsTheNodesMemoryDirectory() {
    let node = LoopNode(id: nodeID, title: "Fix", loopType: .turnBased)
    let paths = ZmxSessionLauncher.workspacePaths(forNode: node, projectPath: sshProject)
    #expect(paths.contains("/home/dev/widget"))
    #expect(
      paths.contains(
        RemoteGraphAccess.memoryDirectory(forProjectPath: sshProject, nodeID: nodeID)))
    let local = ZmxSessionLauncher.workspacePaths(forNode: node, projectPath: "/Users/dev/w")
    #expect(local == ["/Users/dev/w"])
  }

  @Test
  func aRemoteLaunchCreatesTheAttachmentsDirectoryBeforeTheAgentStarts() throws {
    let location = try #require(RemoteProjectLocation.parse(projectPath: sshProject))
    let node = LoopNode(
      id: nodeID, title: "Fix", loopType: .goalBased, goal: GoalSpec(summary: "tests pass"))
    let script = try #require(
      ZmxSessionLauncher.remoteEnsureDialScript(forNode: node, at: location)?.script)
    let make = try #require(script.range(of: "mkdir -p -m 700 ~/'.graphcode/memory/"))
    let run = try #require(script.range(of: "zmx' 'run'"))
    #expect(make.lowerBound < run.lowerBound)
  }
}

extension RemoteAttachmentUploadTests {
  /// A loopback sshd with a fake `HOME` (`TEST_RUNNER_GRAPHCODE_LOOPBACK_RIG`): `ssh` is a
  /// wrapper passing the rig's own `-F` config, so the human's `~/.ssh` is never touched.
  private static let loopbackRig = ProcessInfo.processInfo.environment["GRAPHCODE_LOOPBACK_RIG"]

  @Test(.enabled(if: loopbackRig != nil))
  func aRealSSHHopDeliversTheExactBytes() async throws {
    let rig = try #require(Self.loopbackRig)
    let projectPath = "ssh://\(NSUserName())@127.0.0.1\(rig)/repo"
    let image = awkwardBytes + Data((0..<300_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    var request = try RemoteAttachmentUpload.request(
      image, fileName: "paste-1.png", projectPath: projectPath, nodeID: nodeID)
    request.executable = URL(fileURLWithPath: "\(rig)/ssh")
    let result = try await FoundationProcessRunner().run(request, timeout: .seconds(60))
    let path = try RemoteAttachmentUpload.publishedPath(from: result)
    #expect(path.hasPrefix("\(rig)/home/.graphcode/memory/"))
    #expect(try Data(contentsOf: URL(fileURLWithPath: path)) == image)
    let mode = try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions]
    #expect((mode as? NSNumber)?.intValue == 0o600)
  }
}
