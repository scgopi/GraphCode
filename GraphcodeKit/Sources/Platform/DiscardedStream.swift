import Foundation

/// A sink for a child's stdout or stderr that nobody reads.
///
/// On Windows a child handed `FileHandle.nullDevice` for stderr (or for stdout and stderr
/// together) exits 1 on its first write to it: `zmx ls` with no sessions prints "no sessions
/// found" to stderr, and `cmd /c "echo x"` with both streams null exits 1. Anything that
/// reads that exit code as a decision must use this instead. `NUL` is opened writable, one
/// handle per stream; the `Pipe` fallback is never drained and only matters if `NUL`
/// cannot be opened. Stdin is unaffected and may keep using `FileHandle.nullDevice`.
enum DiscardedStream {
  static func handle() -> Any {
    #if os(Windows)
      if let nul = FileHandle(forWritingAtPath: "NUL") { return nul }
      return Pipe()
    #else
      return FileHandle.nullDevice
    #endif
  }
}
