import Foundation

/// A sink for a child's stdout or stderr that nobody reads.
///
/// On Windows a child handed `FileHandle.nullDevice` for stderr (or for stdout and stderr
/// together) exits 1 on its first write to it: `zmx ls` with no sessions prints "no sessions
/// found" to stderr, and `cmd /c "echo x"` with both streams null exits 1. Anything that
/// reads that exit code as a decision must use this instead. `NUL` is opened writable, one
/// handle per stream. If `NUL` cannot be opened the fallback is a `Pipe` whose read end
/// is drained and discarded, so a chatty child can never block on a full pipe and hang its
/// parent. Stdin is unaffected and may keep using `FileHandle.nullDevice`.
enum DiscardedStream {
  typealias Opener = (_ path: String) -> FileHandle?

  static func handle(opener: Opener = { FileHandle(forWritingAtPath: $0) }) -> Any {
    #if os(Windows)
      if let nul = opener("NUL") { return nul }
      return drainedSink()
    #else
      return FileHandle.nullDevice
    #endif
  }

  /// A pipe whose reader discards everything written, ending when the write side closes.
  static func drainedSink() -> Pipe {
    let pipe = Pipe()
    pipe.fileHandleForReading.readabilityHandler = { handle in
      if handle.availableData.isEmpty { handle.readabilityHandler = nil }
    }
    return pipe
  }
}
