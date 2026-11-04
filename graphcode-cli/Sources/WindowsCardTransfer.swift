#if os(Windows)
  import Foundation
  import GraphcodeKit
  import WinSDK
  import WindowsCardTransferCore

  enum WindowsCardTransfer {
    static func runIfRequested(_ arguments: [String]) -> Int32? {
      guard arguments.first == CardTransferRequest.optIn else { return nil }
      let request: CardTransferRequest
      do {
        guard let parsed = try CardTransferRequest.parse(arguments) else {
          return emit(CardTransferResult(
            request: nil, status: .rejected, message: "Missing card-transfer opt-in.",
            sessionPreparationStarted: false))
        }
        request = parsed
      } catch {
        return emit(CardTransferResult(
          request: nil, status: .rejected, message: error.localizedDescription,
          sessionPreparationStarted: false))
      }
      final class ResultBox: @unchecked Sendable {
        var result: CardTransferResult?
      }
      let box = ResultBox()
      let finished = DispatchSemaphore(value: 0)
      Task {
        box.result = await execute(request)
        finished.signal()
      }
      finished.wait()
      guard let result = box.result else {
        return emit(CardTransferResult(
          request: request, status: .failed, message: "The transfer completed without a result.",
          sessionPreparationStarted: false))
      }
      return emit(result)
    }

    private static func emit(_ result: CardTransferResult) -> Int32 {
      do {
        FileHandle.standardOutput.write(Data(try result.record().utf8))
        return result.exitCode
      } catch {
        FileHandle.standardError.write(
          Data("graphcode card transfer: \(error.localizedDescription)\n".utf8))
        return result.exitCode == 0 ? 1 : result.exitCode
      }
    }

    private static func execute(_ request: CardTransferRequest) async -> CardTransferResult {
      var client: CardTransferClient?
      var sessionPreparationStarted = false
      var result: CardTransferResult
      do {
        let projectPath: String
        do {
          projectPath = try CardTransferLocalProject.beforeRuntime(request.projectPath) {
            try CurrentPlatformPaths.value.canonicalProjectPath(request.projectPath)
          }
        } catch {
          throw CardTransferFailure(status: .rejected, message: error.localizedDescription)
        }
        let pipeName = try WindowsNamedPipeEndpoint.name()
        let connection: WindowsNamedPipeConnection
        do {
          connection = try WindowsNamedPipeClient.connect(to: pipeName)
        } catch {
          let rejected = (error as? WindowsPipeError) == .serverIdentityRejected
          throw CardTransferFailure(
            status: rejected ? .rejected : .unavailable,
            message: "Could not connect to the selected daemon: \(error.localizedDescription)")
        }
        let openedClient = CardTransferClient(connection: connection)
        client = openedClient
        try await openedClient.handshake()
        let root = try await openedClient.graph(
          .openProject(path: projectPath), projectPath: projectPath)
        let target = try CardTransferTarget.resolve(
          nodeID: request.nodeID, expectedScope: request.scope, in: root)
        switch request.operation {
        case .export:
          result = await export(request, projectPath: projectPath, target: target)
        case .import:
          guard let bundle = GraphExportBundle.readFromZip(at: request.zipPath) else {
            throw CardTransferFailure(status: .failed, message: "Could not read the selected GraphCode ZIP bundle.")
          }
          guard !bundle.graphSnapshot.nodes.isEmpty else {
            throw CardTransferFailure(status: .rejected, message: "The bundle contains no loops.")
          }
          let current = try await openedClient.graph(
            .readProjectGraph(path: projectPath), projectPath: projectPath)
          guard current.id == root.id else {
            throw CardTransferFailure(status: .rejected, message: "The project changed before session preparation.")
          }
          _ = try CardTransferTarget.resolve(
            nodeID: request.nodeID, expectedScope: request.scope, in: current)
          sessionPreparationStarted = true
          guard let prepared = await bundle.preparedImportRequest(
            asChildOf: request.nodeID, projectPath: projectPath)
          else {
            throw CardTransferFailure(status: .rejected, message: "The bundle contains no loops.")
          }
          let refreshed = try await openedClient.graph(
            .readProjectGraph(path: projectPath), projectPath: projectPath)
          guard refreshed.id == root.id else {
            throw CardTransferFailure(status: .rejected, message: "The project changed while preparing sessions.")
          }
          let refreshedTarget = try CardTransferTarget.resolve(
            nodeID: request.nodeID, expectedScope: request.scope, in: refreshed)
          let command = try refreshedTarget.importCommand(prepared.request)
          let imported = try await openedClient.graph(
            .graphCommand(projectPath: projectPath, command: command),
            projectPath: projectPath, mutation: true)
          guard imported.id == root.id else {
            throw CardTransferFailure(
              status: .outcome_unknown,
              message: "The import reply names another graph identity. Check the graph; do not retry automatically.")
          }
          result = CardTransferResult(
            request: request, status: .succeeded,
            message: "Imported \(prepared.request.snapshot.nodes.count) loop(s); \(prepared.resumingSessions) session(s) restored. Embedded descendants may not carry all memory or session history.",
            sessionPreparationStarted: true)
        }
      } catch {
        let failure = error as? CardTransferFailure
          ?? CardTransferFailure(status: .failed, message: error.localizedDescription)
        result = CardTransferResult(
          request: request, status: failure.status,
          message: failure.message + (sessionPreparationStarted
            ? " Session preparation already started; restored artifacts may remain even if the graph was not changed."
            : ""),
          sessionPreparationStarted: sessionPreparationStarted)
      }
      if let client {
        do {
          try await client.connection.close()
        } catch {
          result = CardTransferResult(
            request: request, status: result.outcome,
            message: result.message + " Closing the owned daemon connection failed: \(error.localizedDescription)",
            sessionPreparationStarted: result.sessionPreparationStarted, outputPath: result.outputPath)
        }
      }
      return result
    }

    private static func export(
      _ request: CardTransferRequest, projectPath: String, target: CardTransferTarget
    ) async -> CardTransferResult {
      var staging: CardTransferStaging?
      var publication = CardTransferPublication()
      var status = CardTransferStatus.failed
      var message: String
      do {
        let owned = try CardTransferStaging(
          destination: request.zipPath, replaceExisting: request.replaceExisting)
        staging = owned
        let persistence = ProjectPersistence(baseDirectory: SupportDirectory.url)
        guard let bundle = await persistence.createExportBundle(
          for: [request.nodeID], from: target.graph, projectPath: projectPath)
        else {
          throw CardTransferFailure(status: .failed, message: "Could not prepare the selected loop's bundle.")
        }
        try publication.writeAndCommit(
          writeArchive: {
            guard bundle.writeToZip(at: owned.archive.path) != nil else {
              throw CardTransferFailure(
                status: .failed, message: "ZIP creation failed; the selected destination was not replaced.")
            }
          },
          acquireArchive: { try owned.acquireArchive() },
          validateOwnership: { try owned.validateForCommit() },
          commit: { try owned.commit() })
        status = .succeeded
        message = "Exported the selected loop. Embedded descendants may not carry all memory or session history."
      } catch {
        let failure = error as? CardTransferFailure
          ?? CardTransferFailure(status: .failed, message: error.localizedDescription)
        status = failure.status
        message = failure.message
      }
      if let staging {
        do {
          try publication.cleanup { try staging.removeOwnedEmptyDirectory() }
        } catch {
          message += " Export staging retained at \(staging.directory.path): \(error.localizedDescription)"
        }
        do {
          try staging.close()
        } catch {
          message += " Closing export ownership handles failed: \(error.localizedDescription)"
        }
      }
      return CardTransferResult(
        request: request, status: status, message: message, sessionPreparationStarted: false,
        outputPath: status == .succeeded ? request.zipPath : nil)
    }
  }

  private struct CardTransferClient {
    let connection: WindowsNamedPipeConnection

    func handshake() async throws {
      do {
        try await connection.sendFrame(CardTransferWire.hello())
        let reply = try await connection.receiveFrameWithDeadline(10)
        try CardTransferWire.validateHello(reply)
      } catch {
        throw CardTransferFailure.exchange(error, mutationDispatched: false)
      }
    }

    func graph(
      _ command: DaemonCommand, projectPath: String, mutation: Bool = false
    ) async throws -> LoopGraph {
      let id = Foundation.UUID()
      let data = try CardTransferWire.request(id: id, command: command)
      let clock = ContinuousClock()
      let deadline = clock.now.advanced(by: .seconds(10))
      do {
        // A failed write can have delivered a complete mutation; never retry it.
        try await connection.sendFrame(data)
        for _ in 0..<64 {
          let remaining = clock.now.duration(to: deadline).components
          let timeout = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
          guard timeout > 0 else {
            throw CardTransferFailure(status: .failed, message: "Timed out waiting for the correlated daemon reply.")
          }
          let frame = try await connection.receiveFrameWithDeadline(timeout)
          if let graph = try CardTransferWire.graphReply(frame, requestID: id, projectPath: projectPath) {
            return graph
          }
        }
        throw CardTransferFailure(status: .failed, message: "No correlated reply within 64 daemon frames.")
      } catch {
        throw CardTransferFailure.exchange(error, mutationDispatched: mutation)
      }
    }
  }

  private final class CardTransferStaging {
    let directory: URL
    let archive: URL
    private let destination: URL
    private let replaceExisting: Bool
    private var parentHandle: HANDLE?
    private var directoryHandle: HANDLE?
    private var archiveHandle: HANDLE?
    private var parentIdentity: CardTransferFileIdentity?
    private var directoryIdentity: CardTransferFileIdentity?
    private var ownership: CardTransferOwnership?

    init(destination: String, replaceExisting: Bool) throws {
      let target = URL(fileURLWithPath: destination).standardizedFileURL
      let attributes = try withWindowsPath(target) { GetFileAttributesW($0) }
      if attributes != INVALID_FILE_ATTRIBUTES {
        guard attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
          throw CardTransferFailure(status: .rejected, message: "The export destination is not a regular file.")
        }
        guard replaceExisting else {
          throw CardTransferFailure(status: .rejected, message: "The destination exists and overwrite was not approved.")
        }
      } else {
        let error = GetLastError()
        guard error == ERROR_FILE_NOT_FOUND else {
          throw WindowsPipeError.win32(operation: "Inspect export destination", code: error)
        }
      }
      let ownedDirectory = target.deletingLastPathComponent().appendingPathComponent(
        ".graphcode-card-export-\(Foundation.UUID().uuidString)", isDirectory: true)
      directory = ownedDirectory
      archive = ownedDirectory.appendingPathComponent("bundle.zip")
      self.destination = target
      self.replaceExisting = replaceExisting
      var created = false
      do {
        let parent = try open(
          target.deletingLastPathComponent(),
          access: DWORD(FILE_LIST_DIRECTORY | FILE_ADD_FILE | FILE_READ_ATTRIBUTES),
          share: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), directory: true)
        parentHandle = parent
        let parentInfo = try information(parent)
        try requireDirectory(parentInfo)
        parentIdentity = try identity(parentInfo)
        guard try withWindowsPath(directory, { CreateDirectoryW($0, nil) }) else {
          throw WindowsPipeError.win32(operation: "Create owned export staging", code: GetLastError())
        }
        created = true
        let ownedHandle = try open(
          directory, access: DWORD(DELETE | FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES),
          share: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE), directory: true)
        directoryHandle = ownedHandle
        let directoryInfo = try information(ownedHandle)
        try requireDirectory(directoryInfo)
        directoryIdentity = try identity(directoryInfo)
      } catch {
        var message = error.localizedDescription
        if created { message += " Staging retained at \(directory.path); ownership was not established." }
        do { try close() } catch { message += " Handle close failed: \(error.localizedDescription)" }
        throw CardTransferFailure(status: .failed, message: message)
      }
    }

    deinit {
      for handle in [archiveHandle, directoryHandle, parentHandle].compactMap({ $0 }) {
        _ = CloseHandle(handle)
      }
    }

    func acquireArchive() throws {
      guard archiveHandle == nil, let directoryIdentity else {
        throw CardTransferFailure(status: .failed, message: "Export staging has no directory ownership receipt.")
      }
      let handle = try open(
        archive, access: DWORD(DELETE | FILE_READ_DATA | FILE_READ_ATTRIBUTES),
        share: DWORD(FILE_SHARE_READ), directory: false)
      archiveHandle = handle
      let info = try information(handle)
      guard info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0 else {
        throw CardTransferFailure(status: .rejected, message: "The completed archive is not a regular file.")
      }
      ownership = CardTransferOwnership(directory: directoryIdentity, archive: try identity(info))
    }

    func validateForCommit() throws {
      guard let ownership, let archiveHandle, let directoryHandle,
        let parentHandle, let parentIdentity, let directoryIdentity
      else {
        throw CardTransferFailure(status: .failed, message: "The export archive has no held ownership receipt.")
      }
      try requireDirectory(information(parentHandle))
      try requireDirectory(information(directoryHandle))
      guard try identity(information(parentHandle)) == parentIdentity,
        try identity(information(directoryHandle)) == directoryIdentity,
        try probe(destination.deletingLastPathComponent(), directory: true) == parentIdentity,
        try identity(information(archiveHandle)) == ownership.archive
      else {
        throw CardTransferFailure(status: .rejected, message: "The export's held directory or archive identity changed.")
      }
      let archiveInfo = try information(archiveHandle)
      try ownership.validate(
        directory: probe(directory, directory: true), archive: probe(archive, directory: false),
        directoryIsReparse: false,
        archiveIsRegular: archiveInfo.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) == 0,
        children: FileManager.default.contentsOfDirectory(atPath: directory.path).sorted())
    }

    func commit() throws {
      try validateForCommit()
      guard let archiveHandle, let parentHandle else {
        throw CardTransferFailure(status: .failed, message: "The platform cannot describe an owned archive rename.")
      }
      let attributes = try withWindowsPath(destination) { GetFileAttributesW($0) }
      if attributes != INVALID_FILE_ATTRIBUTES,
        attributes & DWORD(FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT) != 0
      {
        throw CardTransferFailure(status: .rejected, message: "The export destination changed to a directory or link.")
      }
      try CardTransferNativeArchiveCommit.rename(
        archive: archiveHandle, parent: parentHandle,
        filename: destination.lastPathComponent, replaceExisting: replaceExisting)
    }

    func removeOwnedEmptyDirectory() throws {
      guard let directoryHandle, let directoryIdentity else {
        throw CardTransferFailure(status: .failed, message: "No held staging directory receipt.")
      }
      try requireDirectory(information(directoryHandle))
      guard try identity(information(directoryHandle)) == directoryIdentity else {
        throw CardTransferFailure(status: .rejected, message: "The held staging directory identity changed.")
      }
      try CardTransferOwnership.removeEmptyDirectory(
        expected: directoryIdentity, observed: probe(directory, directory: true),
        isReparse: false, children: FileManager.default.contentsOfDirectory(atPath: directory.path)
      ) {
        var disposition = FILE_DISPOSITION_INFO()
        withUnsafeMutableBytes(of: &disposition) { $0[0] = 1 }
        guard SetFileInformationByHandle(
          directoryHandle, FileDispositionInfo, &disposition, DWORD(MemoryLayout<FILE_DISPOSITION_INFO>.size))
        else {
          throw WindowsPipeError.win32(operation: "Remove held empty staging directory", code: GetLastError())
        }
      }
    }

    func close() throws {
      var errors: [String] = []
      for handle in [archiveHandle, directoryHandle, parentHandle].compactMap({ $0 }) {
        if !CloseHandle(handle) { errors.append("Win32 \(GetLastError())") }
      }
      archiveHandle = nil
      directoryHandle = nil
      parentHandle = nil
      if !errors.isEmpty {
        throw CardTransferFailure(status: .failed, message: errors.joined(separator: "; "))
      }
    }

    private func open(_ url: URL, access: DWORD, share: DWORD, directory: Bool) throws -> HANDLE {
      let handle = try withWindowsPath(url) {
        CreateFileW(
          $0, access, share, nil, DWORD(OPEN_EXISTING),
          DWORD(FILE_FLAG_OPEN_REPARSE_POINT | (directory ? FILE_FLAG_BACKUP_SEMANTICS : 0)), nil)
      }
      guard let handle, handle != INVALID_HANDLE_VALUE else {
        throw WindowsPipeError.win32(operation: "Acquire export identity handle", code: GetLastError())
      }
      return handle
    }

    private func information(_ handle: HANDLE) throws -> BY_HANDLE_FILE_INFORMATION {
      var info = BY_HANDLE_FILE_INFORMATION()
      guard GetFileInformationByHandle(handle, &info) else {
        throw WindowsPipeError.win32(operation: "Read export file identity", code: GetLastError())
      }
      return info
    }

    private func identity(_ info: BY_HANDLE_FILE_INFORMATION) throws -> CardTransferFileIdentity {
      let index = UInt64(info.nFileIndexHigh) << 32 | UInt64(info.nFileIndexLow)
      guard index != 0 else {
        throw CardTransferFailure(status: .rejected, message: "The filesystem did not provide a reliable export identity.")
      }
      return CardTransferFileIdentity(volume: info.dwVolumeSerialNumber, index: index)
    }

    private func requireDirectory(_ info: BY_HANDLE_FILE_INFORMATION) throws {
      guard info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_DIRECTORY) != 0,
        info.dwFileAttributes & DWORD(FILE_ATTRIBUTE_REPARSE_POINT) == 0
      else {
        throw CardTransferFailure(status: .rejected, message: "Export staging or its parent is not an ordinary directory.")
      }
    }

    private func probe(_ url: URL, directory: Bool) throws -> CardTransferFileIdentity {
      let handle = try open(
        url, access: DWORD(FILE_READ_ATTRIBUTES),
        share: DWORD(FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE), directory: directory)
      defer { _ = CloseHandle(handle) }
      let info = try information(handle)
      if directory { try requireDirectory(info) }
      return try identity(info)
    }
  }

  private func withWindowsPath<T>(_ url: URL, _ body: (UnsafePointer<WCHAR>) -> T) throws -> T {
    let wide = try CardTransferWindowsPath.wide(url)
    return wide.withUnsafeBufferPointer { body($0.baseAddress!) }
  }
#endif
