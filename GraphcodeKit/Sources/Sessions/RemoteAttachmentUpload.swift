import Foundation

/// Puts an image a human pasted on the Mac onto the machine a remote loop runs on, and
/// answers with the path the agent there can open (issue #819).
///
/// **Raw bytes over one ssh process's stdin, never through a PTY or the ensure dial.**
/// The ensure delivery (`RemoteGraphAccess.remoteDeliveryScript`) carries text and runs
/// again on later ensures; a canonical-mode tty drops input past `MAX_CANON`; and an
/// image is up to `maximumBytes` that base64 would only inflate. A plain
/// `FoundationProcessRunner` child with the bytes as its standard input is binary-safe,
/// and `RemoteProjectLocation.sshInvocation` already knows every way a host is reached —
/// plain ssh, ports, multiplexing, and both Codespace dials — so this adds no transport
/// of its own.
///
/// Only the byte count, the digest and graphcode-generated home-relative paths reach the
/// remote command line, each single-quoted; the remote writer refuses anything whose
/// size or SHA-256 differs, and publishes by `os.replace` so a cut-off transfer never
/// leaves a partial file at the final path.
public enum RemoteAttachmentUpload {
  /// The New Node dialog's own bound (`DraftImageImport.maximumBytes`), enforced again
  /// here so nothing larger is ever dialed with.
  public static let maximumBytes = 10 * 1024 * 1024

  public static let imageExtensions: Set<String> = [
    "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff", "tif", "bmp",
  ]

  /// Printed before the published path so the answer can be found in output a remote
  /// login shell's rc files may have written to as well.
  static let pathMarker = "GRAPHCODE_ATTACHMENT_PATH="

  /// A Codespace that has to be started first spends most of this in gh.
  public static let defaultTimeout: Duration = .seconds(120)

  /// `~/.graphcode/memory/<slug>/<node>/attachments` — beside the wake digest and the
  /// shed prompt, inside the directory every remote launch grants
  /// (`ZmxSessionLauncher.workspacePaths`), and never inside the repository.
  public static func attachmentsDirectory(forProjectPath projectPath: String, nodeID: UUID)
    -> String
  {
    RemoteGraphAccess.memoryDirectory(forProjectPath: projectPath, nodeID: nodeID) + "/"
      + NodeMemory.attachmentsDirectoryName
  }

  /// A file name graphcode chose, or `nil` for one that could become a path of its own.
  static func isSafeFileName(_ name: String) -> Bool {
    let ext = (name as NSString).pathExtension.lowercased()
    return imageExtensions.contains(ext) && !name.hasPrefix(".")
      && name.unicodeScalars.allSatisfy {
        CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0)
      }
  }

  /// The remote shell command: a `python3` writer whose every value rides as a quoted
  /// argument rather than as program text.
  static func writerCommand(destination: String, byteCount: Int, sha256: String) -> String {
    let program = """
      import hashlib
      import os
      import sys
      import tempfile

      count = int(sys.argv[1])
      digest = sys.argv[2]
      destination = os.path.expanduser(sys.argv[3])
      folder = os.path.dirname(destination)
      os.makedirs(folder, mode=0o700, exist_ok=True)
      os.chmod(folder, 0o700)
      fd, temporary = tempfile.mkstemp(dir=folder, prefix=".upload-")
      try:
          hasher = hashlib.sha256()
          written = 0
          with os.fdopen(fd, "wb") as output:
              while written <= count:
                  chunk = sys.stdin.buffer.read(min(65536, count + 1 - written))
                  if not chunk:
                      break
                  hasher.update(chunk)
                  output.write(chunk)
                  written += len(chunk)
              output.flush()
              os.fsync(output.fileno())
          if written != count:
              sys.exit("graphcode: received %d of %d bytes" % (written, count))
          if hasher.hexdigest() != digest:
              sys.exit("graphcode: the image arrived corrupted")
          os.chmod(temporary, 0o600)
          os.replace(temporary, destination)
          temporary = None
      finally:
          if temporary is not None:
              try:
                  os.unlink(temporary)
              except OSError:
                  pass
      print("\(pathMarker)" + os.path.abspath(destination))
      """
    return ["python3", "-c", program, String(byteCount), sha256, destination]
      .map(RemoteProjectLocation.shellQuoted).joined(separator: " ")
  }

  /// The request that uploads `data` as `fileName` into the node's attachments
  /// directory, or why it can't be made.
  public static func request(
    _ data: Data, fileName: String, projectPath: String, nodeID: UUID
  ) throws -> ProcessRequest {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath) else {
      throw RemoteAttachmentUploadError.notRemote
    }
    guard isSafeFileName(fileName) else { throw RemoteAttachmentUploadError.unsupportedImage }
    guard !data.isEmpty else { throw RemoteAttachmentUploadError.unsupportedImage }
    guard data.count <= maximumBytes else { throw RemoteAttachmentUploadError.tooLarge }
    let destination =
      attachmentsDirectory(forProjectPath: location.projectPath, nodeID: nodeID) + "/" + fileName
    let command = writerCommand(
      destination: destination, byteCount: data.count, sha256: GraphcodeSHA256.hex(data))
    let argv = location.sshInvocation(remoteCommand: location.remoteLoginShellCommand(command))
    return ProcessRequest(
      executable: URL(fileURLWithPath: argv[0]), arguments: Array(argv.dropFirst()),
      standardInput: data)
  }

  /// Uploads and returns the absolute path on the remote host.
  public static func upload(
    _ data: Data, fileName: String, projectPath: String, nodeID: UUID,
    runner: any ProcessRunner = FoundationProcessRunner(),
    timeout: Duration = defaultTimeout
  ) async throws -> String {
    let request = try request(data, fileName: fileName, projectPath: projectPath, nodeID: nodeID)
    RemoteProjectLocation.prepareControlSocketDirectory()
    let result: ProcessResult
    do {
      result = try await runner.run(request, timeout: timeout)
    } catch ProcessRunnerError.timedOut {
      throw RemoteAttachmentUploadError.timedOut
    } catch {
      throw RemoteAttachmentUploadError.failed(String(describing: error))
    }
    return try publishedPath(from: result)
  }

  static func publishedPath(from result: ProcessResult) throws -> String {
    let output = String(decoding: result.standardOutput, as: UTF8.self)
    let path = output.split(whereSeparator: \.isNewline).reversed()
      .first { $0.hasPrefix(pathMarker) }
      .map { String($0.dropFirst(pathMarker.count)) }
    if result.exitCode == 0, let path, path.hasPrefix("/") { return path }
    let detail = String(decoding: result.standardError, as: UTF8.self)
      .split(whereSeparator: \.isNewline).last
      .map(String.init)?.trimmingCharacters(in: .whitespaces)
    if result.exitCode == 255 {
      throw RemoteAttachmentUploadError.unreachable(detail ?? "ssh exited 255")
    }
    throw RemoteAttachmentUploadError.failed(detail ?? "exit \(result.exitCode)")
  }

  /// The ssh argv that removes deleted nodes' remote memory — the remote twin of
  /// `NodeMemory.remove`. Their digests, shed prompts and attachments are copies of things
  /// the Mac holds or the nodes no longer need. One dial for any number of nodes.
  ///
  /// `nil` for a Codespace unless `includingCodespace`: every Codespace dial goes through
  /// gh, which *starts* a stopped codespace, so deleting a graph of idle loops would boot
  /// the machine just to tidy a private folder it may never use again.
  public static func removalInvocation(
    forProjectPath projectPath: String, nodeIDs: [UUID], includingCodespace: Bool = false
  ) -> [String]? {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath), !nodeIDs.isEmpty,
      includingCodespace || !location.isCodespace
    else { return nil }
    let directories = nodeIDs.map {
      let directory = RemoteGraphAccess.memoryDirectory(
        forProjectPath: location.projectPath, nodeID: $0)
      return "~/" + RemoteProjectLocation.shellQuoted(String(directory.dropFirst(2)))
    }
    return location.sshInvocation(remoteCommand: "rm -rf " + directories.joined(separator: " "))
  }

  /// Best effort and detached: the host may be offline, and deleting a node must never
  /// wait on it. Coalesced by `RemoteMemoryJanitor`, so deleting a whole graph costs one
  /// dial per host rather than one per loop. What a failure leaves is a private directory
  /// under `~/.graphcode`.
  public static func removeRemoteMemory(
    projectPath: String, nodeID: UUID, includingCodespace: Bool = false
  ) {
    guard let location = RemoteProjectLocation.parse(projectPath: projectPath),
      includingCodespace || !location.isCodespace
    else { return }
    Task {
      await RemoteMemoryJanitor.shared.enqueue(
        projectPath: projectPath, nodeID: nodeID, includingCodespace: includingCodespace)
    }
  }

  /// What the agent is told, typed into its composer after an upload. Plain words on both
  /// sides of the path, for the reason `PromptAttachments.resolving` gives.
  public static func composerReference(toImageAt path: String) -> String {
    "Image available at \(path) - inspect it. "
  }
}

public enum RemoteAttachmentUploadError: Error, Equatable, LocalizedError {
  case notRemote
  case unsupportedImage
  case tooLarge
  case timedOut
  case unreachable(String)
  case failed(String)

  public var errorDescription: String? {
    switch self {
    case .notRemote: return "This loop doesn't run on another machine."
    case .unsupportedImage: return "That isn't an image GraphCode can attach."
    case .tooLarge: return "That image is over 10 MB."
    case .timedOut: return "Copying the image to the remote machine timed out."
    case .unreachable(let detail): return "Couldn't reach the remote machine: \(detail)"
    case .failed(let detail): return "Couldn't copy the image to the remote machine: \(detail)"
    }
  }
}

/// Collects remote-memory removals for a moment and sends each project's as one `rm -rf`,
/// one project at a time.
actor RemoteMemoryJanitor {
  static let shared = RemoteMemoryJanitor()

  private struct Key: Hashable {
    var projectPath: String
    var includingCodespace: Bool
  }

  private let delay: Duration
  private let runner: any ProcessRunner
  private var pending: [Key: [UUID]] = [:]
  private var flushScheduled = false

  init(delay: Duration = .seconds(2), runner: any ProcessRunner = FoundationProcessRunner()) {
    self.delay = delay
    self.runner = runner
  }

  func enqueue(projectPath: String, nodeID: UUID, includingCodespace: Bool = false) {
    pending[Key(projectPath: projectPath, includingCodespace: includingCodespace), default: []]
      .append(nodeID)
    guard !flushScheduled else { return }
    flushScheduled = true
    Task { await flushAfterDelay() }
  }

  private func flushAfterDelay() async {
    try? await Task.sleep(for: delay)
    await flush()
  }

  func flush() async {
    let batch = pending
    pending = [:]
    flushScheduled = false
    RemoteProjectLocation.prepareControlSocketDirectory()
    for (key, nodeIDs) in batch {
      guard
        let argv = RemoteAttachmentUpload.removalInvocation(
          forProjectPath: key.projectPath, nodeIDs: nodeIDs,
          includingCodespace: key.includingCodespace)
      else { continue }
      _ = try? await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: argv[0]), arguments: Array(argv.dropFirst())),
        timeout: .seconds(30))
    }
  }
}
