import Foundation

/// The one directory graphcode keeps all of its own state in: `~/.graphcode`.
///
/// Everything lives here — per-project graphs, the recents and open-projects indexes,
/// terminal layouts, the daemon's socket and logs, and the `zmx`/`graphcode` binaries
/// `make install-*` drops in `bin/`. Nothing is ever written inside a project folder a
/// human opened.
///
/// **Why a dotfile rather than `~/Library/Application Support/graphcode`**, which is the
/// macOS convention this used to follow:
///
/// - graphcode is a developer tool with a first-class CLI (`graphcode status …`), and its
///   state is plain JSON people will want to `cat`, `jq`, and script against. `~/.graphcode`
///   sits where a developer already looks, next to `~/.claude` and `~/.ssh`.
/// - The daemon's socket path gets meaningfully shorter, and `sockaddr_un.sun_path` is a
///   hard 104 bytes on Darwin. `~/Library/Application Support/graphcode/graphcoded.sock`
///   is 64 bytes for a short username and grows with it; `~/.graphcode/graphcoded.sock`
///   is 37. That headroom is real, not theoretical — a long username plus a longer socket
///   name would have silently failed to bind.
///
/// The cost, recorded so it isn't rediscovered the hard way: **this choice is incompatible
/// with sandboxing.** If graphcode is ever distributed through the App Store, or otherwise
/// sandboxed, `~/.graphcode` is unreachable and the container's Application Support path
/// is the only writable option. That would mean moving back — and, because
/// `migrateFromLegacyLocationIfNeeded()` only ever moves in one direction, writing the
/// mirror of it.
public enum SupportDirectory {
  /// Names a directory to use instead of `~/.graphcode`, for running a second graphcode
  /// beside an installed one.
  ///
  /// Without this, a build run from Xcode and the copy in `/Applications` share every
  /// piece of state there is — the same graphs, the same terminal layouts, and therefore
  /// the same `zmx` session names, since a surface's session is named after its id. Two
  /// apps then attach to one session and fight over it, which surfaces as
  /// `session "graphcode-…" does not exist` when one of them has already taken it down.
  ///
  /// A relative value is resolved against the home directory, so
  /// `GRAPHCODE_SUPPORT_DIR=.graphcode.dev` does the obvious thing. The **daemon reads
  /// this too**, and its socket lives inside the directory — so a second app needs a
  /// second `graphcoded` started with the same value, or it will sit there unconnected.
  public static let environmentKey = "GRAPHCODE_SUPPORT_DIR"

  /// `~/.graphcode`, unless `GRAPHCODE_SUPPORT_DIR` says otherwise.
  public static var url: URL {
    url(
      environment: ProcessInfo.processInfo.environment,
      homeDirectory: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true))
  }

  /// Resolves an injected environment without changing the process environment.
  ///
  /// Foundation's `URL(fileURLWithPath:)` only recognizes POSIX absolute paths on
  /// Darwin. On Windows, drive-letter and UNC paths must be classified before URL
  /// construction or an override such as `C:\GraphCode` is appended to the user's
  /// home directory.
  public static func url(environment: [String: String], homeDirectory: URL) -> URL {
    let home = homeDirectory
    guard let value = environment[environmentKey] else {
      return home.appendingPathComponent(".graphcode", isDirectory: true)
    }

    let override = value.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !override.isEmpty else {
      return home.appendingPathComponent(".graphcode", isDirectory: true)
    }

    let expanded = expandTilde(override, homeDirectory: home)
    guard isAbsolutePath(expanded) else {
      return home.appendingPathComponent(expanded, isDirectory: true)
    }
    return URL(fileURLWithPath: expanded, isDirectory: true)
  }

  /// Where graphcode kept its state before this moved. Read only by the migration below.
  static var legacyURL: URL {
    FileManager.default
      .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("graphcode", isDirectory: true)
  }

  public static var binDirectory: URL {
    url.appendingPathComponent("bin", isDirectory: true)
  }

  /// Call once at startup, before anything reads or writes. Migrates a pre-existing
  /// Application Support directory, then makes sure the directory exists.
  ///
  /// Both the daemon and the app call this, and both may start first, so it has to be
  /// safe to run concurrently and repeatedly — hence "move only when the destination is
  /// entirely absent" rather than any kind of merge.
  public static func prepare() {
    // No migration when someone has named the directory themselves: moving the legacy
    // Application Support folder into `~/.graphcode.dev` would empty the real location
    // into a scratch one, which is the opposite of what asking for a separate directory
    // means. Such a directory just starts empty.
    let overridden =
      ProcessInfo.processInfo.environment[environmentKey]?
      .trimmingCharacters(in: .whitespaces).isEmpty == false
    prepare(destination: url, legacy: overridden ? url : legacyURL)
  }

  /// The real work, with both paths injected.
  ///
  /// Split out because the alternative is a test that calls the production entry point
  /// and moves the developer's actual `~/.graphcode` — which is not a hypothetical: an
  /// earlier version of the tests did exactly that, against a live daemon.
  static func prepare(destination: URL, legacy: URL) {
    migrateIfNeeded(from: legacy, to: destination)
    try? FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
  }

  /// Moves the old directory across, once, and only when there is nothing at the new
  /// path to conflict with.
  ///
  /// A move rather than a copy: two live copies of a graph, with a daemon writing one and
  /// a human reading the other, is a worse failure than either location alone. And it
  /// bails the moment `~/.graphcode` exists at all — a merge would have to decide which
  /// copy of a project's graph wins, and guessing wrong silently discards someone's
  /// loops.
  @discardableResult
  static func migrateIfNeeded(from source: URL, to destination: URL) -> Bool {
    let fileManager = FileManager.default

    guard !fileManager.fileExists(atPath: destination.path),
      fileManager.fileExists(atPath: source.path)
    else { return false }

    do {
      try fileManager.moveItem(at: source, to: destination)
      return true
    } catch {
      // Nothing useful to do from here — the daemon has no UI, and `prepare()` will
      // create an empty directory next, so graphcode starts clean rather than refusing
      // to run. The old directory is left untouched for a human to move by hand.
      return false
    }
  }

  private static func isAbsolutePath(_ path: String) -> Bool {
    if path.hasPrefix("/") || path.hasPrefix("\\") {
      return true
    }
    #if os(Windows)
      guard path.count >= 3 else { return false }
      let characters = Array(path)
      return characters[1] == ":" && (characters[2] == "\\" || characters[2] == "/")
    #else
      return false
    #endif
  }

  private static func expandTilde(_ path: String, homeDirectory: URL) -> String {
    guard path == "~" || path.hasPrefix("~/") || path.hasPrefix("~\\") else {
      return (path as NSString).expandingTildeInPath
    }
    let suffix = String(path.dropFirst()).trimmingCharacters(in: CharacterSet(charactersIn: "/\\"))
    return suffix.isEmpty
      ? homeDirectory.path
      : homeDirectory.appendingPathComponent(suffix, isDirectory: true).path
  }
}
