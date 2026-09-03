import Foundation

/// One workspace: a support directory with its own graphs, terminal layouts, daemon and
/// loops, opened by its own app instance.
///
/// The mechanism is `GRAPHCODE_SUPPORT_DIR`, which has always been able to point a second
/// graphcode at a directory of its own (see `SupportDirectory`). What this adds is the
/// part that made it unusable as a product feature: a name, a way to find the ones that
/// exist, and a daemon label per workspace — without which a second app rewrote the one
/// launch agent `dev.graphcode.graphcoded` and took the first workspace's daemon with it.
///
/// **Why separate directories rather than more windows.** A window showing a different
/// selection of the *same* graph is a different feature (and a much larger one — the app's
/// state is a single store and a terminal surface is a single `NSView`). This is for the
/// other need: keeping unrelated work apart, so that a hundred loops across three lines of
/// work are three sidebars of a manageable size rather than one that can't be monitored.
/// Nothing is shared between workspaces, which is the point — a loop in one is invisible
/// in the other.
///
/// The default workspace is `~/.graphcode` and is left exactly as it always was: same
/// path, same daemon label, same launch agent bytes. Everything here is additive, so an
/// install that never creates a second workspace cannot tell this shipped.
public struct Workspace: Equatable, Identifiable, Sendable {
  /// Named workspaces are siblings of the default directory: `~/.graphcode-work`.
  ///
  /// Siblings rather than `~/.graphcode/workspaces/work` because the socket path has to
  /// fit `sockaddr_un.sun_path`'s 104 bytes, and nesting spends 12 of them on every
  /// workspace before its name is even counted. It also keeps the default workspace's
  /// directory free of directories that are not its own.
  public static let directoryPrefix = ".graphcode-"

  /// The default workspace's launch agent label, unchanged since the daemon shipped. A
  /// named workspace appends its slug; the default must never do so, or an existing
  /// install would see its agent rewritten under a new label on first launch.
  public static let daemonLabelBase = "dev.graphcode.graphcoded"

  /// `sun_path` is 104 bytes *including* its terminator, so a socket path may use 103.
  /// A workspace whose name would breach it is rejected at creation with something to
  /// read, rather than binding nothing at runtime and looking like a dead daemon.
  public static let maximumSocketPathLength = 103

  /// Empty for the default workspace. Otherwise the directory suffix, which is also the
  /// name shown in the UI and the suffix on the daemon label.
  public let slug: String
  public let url: URL

  public init(slug: String, url: URL) {
    self.slug = slug
    self.url = url
  }

  public var id: String { url.path }
  public var isDefault: Bool { slug.isEmpty }
  public var name: String { isDefault ? "Default" : slug }

  public var daemonLabel: String {
    isDefault ? Self.daemonLabelBase : "\(Self.daemonLabelBase).\(slug)"
  }

  public var socketPath: String {
    url.appendingPathComponent("graphcoded.sock").path
  }
}

extension Workspace {
  public static var `default`: Workspace {
    Workspace(slug: "", url: SupportDirectory.defaultURL)
  }

  /// The workspace this process is running in, derived from wherever
  /// `GRAPHCODE_SUPPORT_DIR` (if anywhere) has pointed it.
  public static var current: Workspace {
    workspace(for: SupportDirectory.url)
  }

  /// Recognizes a directory as a workspace.
  ///
  /// The third branch matters more than it looks: a developer running with
  /// `GRAPHCODE_SUPPORT_DIR=~/.graphcode.dev` is in a directory this feature never
  /// created, and before there were labels per workspace that build shared
  /// `dev.graphcode.graphcoded` with the installed app — so launching it rewrote the
  /// real agent and pointed launchd at a DerivedData daemon. Giving every non-default
  /// directory a slug of its own is what stops that.
  static func workspace(for url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory()))
    -> Workspace
  {
    let path = url.standardizedFileURL.path
    guard path != SupportDirectory.defaultURL.standardizedFileURL.path else { return .default }

    let name = url.standardizedFileURL.lastPathComponent
    let parent = url.standardizedFileURL.deletingLastPathComponent().path
    if parent == home.standardizedFileURL.path, name.hasPrefix(directoryPrefix) {
      return Workspace(slug: String(name.dropFirst(directoryPrefix.count)), url: url)
    }
    return Workspace(slug: slug(from: name), url: url)
  }

  public static func url(forSlug slug: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()))
    -> URL
  {
    home.appendingPathComponent(directoryPrefix + slug, isDirectory: true)
  }

  /// Every workspace on this machine: the default, plus the `~/.graphcode-*` siblings,
  /// plus wherever this process itself is pointed.
  ///
  /// Discovered by scanning rather than kept in a registry file. A registry would have to
  /// live in one workspace's directory — making every other workspace write into it,
  /// which is the coupling this feature exists to avoid — and would go stale the moment
  /// someone moved a directory by hand. The directory *is* the record.
  ///
  /// Ordered oldest first, which is to say the order they were created in — the default
  /// workspace, then each named one behind it. Alphabetical is what this was, and it put
  /// a workspace created today in the middle of the list, moving every ⌥⌘<n> after it:
  /// the numbers are a habit and a habit cannot survive a list that reshuffles. Creation
  /// order only ever appends. A rename keeps its place too, since `moveItem` carries the
  /// creation date with the directory.
  public static func all(
    home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    fileManager: FileManager = .default
  ) -> [Workspace] {
    // No `.skipsHiddenFiles`: every workspace directory is a dotfile, so that option
    // would hide the whole result set.
    let entries =
      (try? fileManager.contentsOfDirectory(
        at: home, includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
        options: [])) ?? []

    let named =
      entries
      .filter { $0.lastPathComponent.hasPrefix(directoryPrefix) }
      .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? true }
      .map { (workspace: workspace(for: $0, home: home), created: creationDate(of: $0)) }

    // Slug breaks a tie rather than leaving `sorted` to decide: two directories created
    // in the same second are ordinary on a restore from backup, and an order that is
    // stable between two calls is the whole point of this.
    let ordered = named.sorted {
      $0.created == $1.created
        ? $0.workspace.slug < $1.workspace.slug : $0.created < $1.created
    }

    var found = [Workspace.default] + ordered.map(\.workspace)
    // The current workspace may be somewhere the scan can't see it — a developer's
    // `GRAPHCODE_SUPPORT_DIR=/tmp/…`, say. A switcher that omits where you already are
    // reads as a bug.
    let current = Workspace.current
    if !found.contains(where: { $0.id == current.id }) {
      found.append(current)
    }
    return found
  }

  /// A directory with no readable creation date sorts to the end rather than the front:
  /// the unknown case is a directory the scan could not stat, and putting it first would
  /// renumber every workspace behind it.
  private static func creationDate(of url: URL) -> Date {
    (try? url.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? .distantFuture
  }

  /// Turns what a human typed into something that is safe as a directory suffix, as a
  /// launchd label suffix, and as a name to read back: lowercase ASCII alphanumerics and
  /// single hyphens.
  ///
  /// Accents and non-Latin scripts are transliterated first, so "Café Zürich" becomes
  /// `cafe-zurich` rather than a row of hyphens. ASCII-only is not fussiness: the slug
  /// ends up in a launchd label, and a label is not a place to discover how launchd
  /// handles a codepoint.
  public static func slug(from name: String) -> String {
    let latin = name.applyingTransform(.toLatin, reverse: false) ?? name
    let plain = latin.applyingTransform(.stripDiacritics, reverse: false) ?? latin
    let mapped = plain.lowercased().map { character -> Character in
      character.isASCII && (character.isLetter || character.isNumber) ? character : "-"
    }
    let collapsed = String(mapped).split(separator: "-", omittingEmptySubsequences: true)
    return String(collapsed.joined(separator: "-").prefix(32))
  }

  public enum NameProblem: Error, Equatable, LocalizedError {
    case empty
    case taken(String)
    case pathTooLong(Int)

    public var errorDescription: String? {
      switch self {
      case .empty:
        return "Give the workspace a name — letters and numbers."
      case .taken(let slug):
        return "A workspace named \(slug) already exists."
      case .pathTooLong(let length):
        return
          "That name makes a socket path of \(length) bytes; macOS allows "
          + "\(Workspace.maximumSocketPathLength). Try a shorter one."
      }
    }
  }

  /// Validates a typed name without creating anything, so the sheet can say what is wrong
  /// while it is still being typed.
  public static func validate(
    name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    fileManager: FileManager = .default
  ) -> Result<Workspace, NameProblem> {
    let slug = slug(from: name)
    guard !slug.isEmpty else { return .failure(.empty) }

    let url = url(forSlug: slug, home: home)
    guard !fileManager.fileExists(atPath: url.path) else { return .failure(.taken(slug)) }

    let workspace = Workspace(slug: slug, url: url)
    let length = workspace.socketPath.utf8.count
    guard length <= maximumSocketPathLength else { return .failure(.pathTooLong(length)) }

    return .success(workspace)
  }

  /// What deleting this workspace would take with it — shown in the confirmation, and
  /// the source of the `zmx` sessions that have to be ended before the directory goes.
  ///
  /// Session names come from the terminal layouts as well as the graphs: a loop's first
  /// surface is named after the node, but its extra tabs and splits are surfaces of their
  /// own, and a session missed here is an agent left running against a workspace that no
  /// longer exists.
  public struct Contents: Equatable, Sendable {
    public var projects = 0
    public var loops = 0
    public var sessionNames: [String] = []
  }

  public func contents(fileManager: FileManager = .default) -> Contents {
    var contents = Contents()
    var surfaceIDs = Set<UUID>()

    let projectsDirectory = url.appendingPathComponent("projects", isDirectory: true)
    for name in (try? fileManager.contentsOfDirectory(atPath: projectsDirectory.path)) ?? []
    where name.hasSuffix(".json") {
      guard let data = try? Data(contentsOf: projectsDirectory.appendingPathComponent(name)),
        let graph = try? JSONDecoder().decode(LoopGraph.self, from: data)
      else { continue }
      contents.projects += 1
      contents.loops += graph.nodes.count
      surfaceIDs.formUnion(graph.nodes.map(\.id))
    }

    let layoutsDirectory = url.appendingPathComponent("terminal-layouts", isDirectory: true)
    for name in (try? fileManager.contentsOfDirectory(atPath: layoutsDirectory.path)) ?? []
    where name.hasSuffix(".json") {
      guard let data = try? Data(contentsOf: layoutsDirectory.appendingPathComponent(name)),
        let layout = try? JSONDecoder().decode(TerminalLayout.self, from: data)
      else { continue }
      surfaceIDs.formUnion(layout.tabs.flatMap(\.surfaces).map(\.id))
    }

    contents.sessionNames = surfaceIDs.map { "\(SurfaceRef.zmxSessionPrefix)\($0.uuidString)" }
      .sorted()
    return contents
  }

  /// What is being asked of a workspace, so a refusal can say so in words.
  public enum Change: Equatable, Sendable {
    case rename
    case delete

    var verb: String {
      switch self {
      case .rename: return "renamed"
      case .delete: return "deleted"
      }
    }
  }

  /// What a switcher row needs to say about a workspace it is not inside: how much is in
  /// it, and whether a window has it open.
  ///
  /// Read from disk every time rather than cached. These are small JSON files, the list
  /// is opened by a human gesture, and the alternative — a cache — would be wrong in the
  /// one case that matters, which is another instance working while you look at the row.
  public struct Summary: Equatable, Sendable {
    public var projects = 0
    public var loops = 0
    public var isOpen = false

    public init(projects: Int = 0, loops: Int = 0, isOpen: Bool = false) {
      self.projects = projects
      self.loops = loops
      self.isOpen = isOpen
    }
  }

  public func summary(fileManager: FileManager = .default) -> Summary {
    let contents = contents(fileManager: fileManager)
    return Summary(
      projects: contents.projects, loops: contents.loops,
      isOpen: WorkspaceLock.holder(of: self) != nil)
  }

  /// Why a workspace cannot be changed right now.
  public enum Refusal: Error, Equatable, LocalizedError {
    case isDefault(Change)
    case isCurrent(Change)
    case isOpen(pid: Int32, Change)

    public var errorDescription: String? {
      switch self {
      case .isDefault(let change):
        return "The default workspace can't be \(change.verb)."
      case .isCurrent(let change):
        return
          "This is the workspace you're in — it can't be \(change.verb) from inside. "
          + "Switch to another one first."
      case .isOpen(let pid, _):
        return "That workspace is open in another window (pid \(pid)). Quit it first."
      }
    }
  }

  /// The three questions asked before a workspace is touched. Both changes move or
  /// remove the directory a running app resolves every path through, so doing either to
  /// the workspace a window is *using* pulls its graphs out from under it — and doing it
  /// to one another instance has open is the same thing, one process away.
  public func refusal(for change: Change, current: Workspace = .current) -> Refusal? {
    if isDefault { return .isDefault(change) }
    if id == current.id { return .isCurrent(change) }
    if let pid = WorkspaceLock.holder(of: self) { return .isOpen(pid: pid, change) }
    return nil
  }

  /// Moves this workspace to a new name: its directory, and with it every graph, layout
  /// and session id inside.
  ///
  /// The old launch agent goes first — its label carries the old slug, and an agent left
  /// loaded over a directory that has moved is `KeepAlive`, so launchd restarts a daemon
  /// pointed at a path that is no longer there. Nothing installs the new one here: the
  /// instance that next opens the workspace writes its agent and starts its daemon, the
  /// same first-open path a freshly created workspace takes.
  ///
  /// What deliberately does *not* happen is any rewriting inside the directory. Graphs
  /// key projects by the project's own path, layouts key surfaces by node id, and the
  /// helpers in `bin/` are copies — none of it names the workspace. The exception worth
  /// knowing about is a `zmx` session that was already running: its environment still
  /// carries the old `GRAPHCODE_SUPPORT_DIR`, so the `graphcode` CLI inside it cannot
  /// reach the graph until that session is restarted. The session itself survives.
  @discardableResult
  public func renamed(
    to name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    fileManager: FileManager = .default
  ) throws -> Workspace {
    let destination = try Workspace.validate(name: name, home: home, fileManager: fileManager)
      .get()
    #if os(macOS)
      DaemonBootstrap.removeLaunchAgent(for: self)
    #endif
    try fileManager.moveItem(at: url, to: destination.url)
    return destination
  }

  /// What is wrong with a typed name, or `nil` when nothing is — the form the sheet wants
  /// while someone is still typing, where a `Result` would have it destructure a success
  /// it has no use for yet.
  public static func problem(
    name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    fileManager: FileManager = .default
  ) -> NameProblem? {
    switch validate(name: name, home: home, fileManager: fileManager) {
    case .success: return nil
    case .failure(let problem): return problem
    }
  }

  /// Creates the directory. Everything else a workspace needs — `bin/`, the launch agent,
  /// the daemon — is what the app instance opening it does on launch, exactly as it does
  /// for a first install of the default workspace.
  public static func create(
    name: String, home: URL = URL(fileURLWithPath: NSHomeDirectory()),
    fileManager: FileManager = .default
  ) throws -> Workspace {
    let workspace = try validate(name: name, home: home, fileManager: fileManager).get()
    try fileManager.createDirectory(at: workspace.url, withIntermediateDirectories: true)
    return workspace
  }
}
