import Foundation

/// One ssh round trip that brings a remote session's transcript tail back to be read.
///
/// **Why the rail could not see a remote loop at all.** The three readers work by tailing
/// the file the agent writes, and for a remote project that file is on the other machine.
/// Presence and activity solved the same problem by asking a *question* over ssh and
/// bringing back one word; a summary needs the records themselves, which is a payload
/// rather than an answer. So the probe does as much of the work as a shell can — find the
/// file, decide whether it has moved, throw away everything a beat is never made from —
/// and ships only what is left.
///
/// Three things keep that from being expensive:
///
/// 1. **One connection.** `sshInvocation` multiplexes over the same `ControlMaster` every
///    other remote read uses, so this is a channel on a live master, not a dial.
/// 2. **Nothing when nothing moved.** The last modification time comes back with the
///    payload and goes out with the next request; a transcript that has not been written
///    to answers `unchanged` in one short line. A quiet remote loop costs a `stat`.
/// 3. **The big records never travel.** Tool *results* — a file's whole contents, a
///    command's whole output — are most of a transcript's bytes and are read by nothing
///    here. Each backend passes the filter that drops its own, and a line longer than
///    64 KB is dropped whatever it is.
enum RemoteTranscriptProbe {
  /// The one line of the reply this side parses, for the reason
  /// `ZmxSessionLauncher.remoteProbeMarker` exists: the remote login shell is interactive
  /// and a `~/.zshrc` may print anything it likes first.
  static let marker = "graphcode-summary:"

  /// How much of the remote tail to consider before filtering. Half the local window: the
  /// filter throws away most of what it reads, and the bytes here cross a network.
  static let tailBytes = 256 * 1024

  enum Reply: Equatable {
    /// The transport failed, no session id was banked, or no transcript was found.
    case nothing
    /// The file has not been written to since the stamp we sent.
    case unchanged
    /// The tail, as whole lines, with the modification time to send next time.
    case lines(stamp: String, lines: [Data])
  }

  /// The remote script: a backend's own way of finding the file, then the same three
  /// steps for all of them.
  ///
  /// `stat` is spelled twice because the remote host may be either kind — `-c` is GNU and
  /// `-f` is BSD, and a graphcode loop runs on Linux boxes and Macs alike.
  static func script(findingFileWith find: String, filter: String, since stamp: String?) -> String {
    let known = stamp ?? "-"
    return [
      find,
      "if [ -z \"$F\" ]; then echo '\(marker) nothing'; exit 0; fi",
      "M=$(stat -c %Y \"$F\" 2>/dev/null || stat -f %m \"$F\" 2>/dev/null)",
      "if [ \"$M\" = '\(known)' ]; then echo '\(marker) unchanged'; exit 0; fi",
      "echo \"\(marker) lines $M\"",
      "tail -c \(tailBytes) \"$F\" 2>/dev/null | \(filter) | awk 'length($0) < 65536' | tail -n 300",
    ].joined(separator: "; ")
  }

  static func run(_ invocation: [String]) async -> Reply {
    RemoteProjectLocation.prepareControlSocketDirectory()
    guard
      let session = try? PTYProcessSession(
        executable: invocation[0], arguments: Array(invocation.dropFirst()))
    else { return .nothing }
    let (succeeded, output) = await session.waitCollectingOutput()
    return parse(succeeded: succeeded, output: output)
  }

  /// The marker line, then everything after it.
  ///
  /// Carried over a PTY, so every line arrives with a carriage return on it that JSON
  /// tolerates and string comparison does not — trimmed here rather than everywhere
  /// downstream. The *last* marker wins, for the reason `parseRemoteStatus` says: what
  /// comes before it is shell chatter.
  static func parse(succeeded: Bool, output: String) -> Reply {
    guard succeeded else { return .nothing }
    // `whereSeparator` rather than a `"\n"` literal, which took the whole reply as one
    // line — the same call `parseRemoteStatus` makes, and now for the same measured reason.
    let lines = output.split(whereSeparator: \.isNewline)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    guard let index = lines.lastIndex(where: { $0.hasPrefix(marker) }) else { return .nothing }
    let words = lines[index].dropFirst(marker.count).split(separator: " ").map(String.init)
    switch words.first {
    case "unchanged": return .unchanged
    case "lines":
      guard let stamp = words.dropFirst().first else { return .nothing }
      let body = lines[(index + 1)...].filter { $0.hasPrefix("{") }.map { Data($0.utf8) }
      return body.isEmpty ? .nothing : .lines(stamp: stamp, lines: body)
    default: return .nothing
    }
  }
}
