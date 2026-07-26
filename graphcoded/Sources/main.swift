import Foundation

#if canImport(Darwin)
  import Darwin
#endif

// graphcoded — the graphcode orchestrator daemon.
//
// Phase 0 (see docs/07-roadmap.md): an empty skeleton. It boots, opens a Unix domain
// socket, and accepts connections without yet speaking any protocol over them.
// `graphcode.app` and the `graphcode` CLI become clients of this socket starting
// Phase 3, once real LoopGraph/scheduler state moves in here — see
// docs/03-architecture.md#background-daemons for why this has to be a separate,
// long-lived process rather than in-app state.

let fileManager = FileManager.default

let supportDirectory =
  fileManager
  .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  .appendingPathComponent("graphcode", isDirectory: true)
try? fileManager.createDirectory(at: supportDirectory, withIntermediateDirectories: true)

let socketURL = supportDirectory.appendingPathComponent("graphcoded.sock")
// Clear a stale socket file left behind by a previous run that didn't shut down cleanly.
try? fileManager.removeItem(at: socketURL)

func fail(_ message: String) -> Never {
  FileHandle.standardError.write(Data("graphcoded: \(message)\n".utf8))
  exit(1)
}

let socketDescriptor = socket(AF_UNIX, SOCK_STREAM, 0)
guard socketDescriptor >= 0 else {
  fail("failed to create socket (errno \(errno))")
}

var address = sockaddr_un()
address.sun_family = sa_family_t(AF_UNIX)
address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)

let path = socketURL.path
withUnsafeMutablePointer(to: &address.sun_path) { pathField in
  pathField.withMemoryRebound(
    to: CChar.self, capacity: MemoryLayout.size(ofValue: pathField.pointee)
  ) { pathPointer in
    _ = path.withCString { cPath in
      strncpy(pathPointer, cPath, MemoryLayout.size(ofValue: pathField.pointee) - 1)
    }
  }
}

let bindResult = withUnsafePointer(to: &address) { addressPointer -> Int32 in
  addressPointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { rawPointer in
    bind(socketDescriptor, rawPointer, socklen_t(MemoryLayout<sockaddr_un>.size))
  }
}
guard bindResult == 0 else {
  fail("failed to bind \(path) (errno \(errno))")
}

guard listen(socketDescriptor, 8) == 0 else {
  fail("failed to listen on \(path) (errno \(errno))")
}

FileHandle.standardOutput.write(Data("graphcoded: listening on \(path)\n".utf8))

// A trap handler so `make stop` / SIGTERM cleans up the socket file instead of
// leaving a stale one for the next launch to skip past.
signal(SIGTERM) { _ in
  unlink(path)
  exit(0)
}
signal(SIGINT) { _ in
  unlink(path)
  exit(0)
}

while true {
  let clientDescriptor = accept(socketDescriptor, nil, nil)
  guard clientDescriptor >= 0 else { continue }
  FileHandle.standardOutput.write(
    Data("graphcoded: client connected (fd \(clientDescriptor))\n".utf8))
  // Phase 0 has no wire protocol yet — accept and close. Phase 3 replaces this
  // loop with the real request dispatcher (see docs/03-architecture.md#cli-graphcode).
  close(clientDescriptor)
}
