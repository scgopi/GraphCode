import Foundation

/// Where prompt templates live and how they are read, written and watched.
/// See PROMPT_TEMPLATES.md (New Designs v4) § Storage.
///
/// **Home is where the app writes; the project is also read.**
///
/// | Location | Role |
/// | --- | --- |
/// | `~/.graphcode/templates/*.md` | Yours, offered in every project. Save writes here by default. |
/// | `<project>/.graphcode/templates/*.md` | Read if present, sorted first. Saving here is an explicit choice. |
///
/// Nothing may land in a checkout by default — many repos will not accept a new
/// dotfolder — and the app must be fully usable with only the home location. A team
/// that *can* commit templates gets project ones for free. Sharing is a git action,
/// not an app feature: GraphCode never pushes, pulls, or touches `.gitignore`.
///
/// Pure Foundation so both the app and the daemon can read the same files; the
/// daemon resolves a following loop's brief here at its next run.
public struct TemplateStorage: Sendable {
  /// Injected so tests can point every path at a scratch directory — the real
  /// entry points below default to the true locations.
  public var homeDirectory: URL
  public var projectDirectory: @Sendable (String) -> URL

  public init(
    homeDirectory: URL? = nil,
    projectDirectory: (@Sendable (String) -> URL)? = nil
  ) {
    self.homeDirectory =
      homeDirectory ?? SupportDirectory.url.appendingPathComponent("templates", isDirectory: true)
    self.projectDirectory =
      projectDirectory ?? { path in
        URL(fileURLWithPath: path, isDirectory: true)
          .appendingPathComponent(".graphcode", isDirectory: true)
          .appendingPathComponent("templates", isDirectory: true)
      }
  }

  public static let shared = TemplateStorage()

  // MARK: - Reading

  /// Every template this project is offered: the project's own first, then home.
  /// Same filename in both means the project's copy wins — a team's committed
  /// version outranks a personal one with the same name, which is what "sorted
  /// first and deduped with project winning" means when both exist.
  public func load(projectPath: String?) -> [PromptTemplate] {
    let home = read(directory: homeDirectory, origin: .home)
    guard let projectPath, !projectPath.isEmpty else { return home }
    let project = read(
      directory: projectDirectory(projectPath), origin: .project(projectPath))
    guard !project.isEmpty else { return home }
    let projectNames = Set(project.map(\.fileName))
    return project + home.filter { !projectNames.contains($0.fileName) }
  }

  /// The one template a following loop looks for, by id — how a rename or a move
  /// between home and a project keeps the loop attached. Searched project first
  /// for the same reason `load` sorts that way.
  public func template(withID id: UUID, projectPath: String?) -> PromptTemplate? {
    load(projectPath: projectPath).first(where: { $0.id == id })
  }

  /// Reads one directory. Unreadable files are skipped, not fatal: a half-written
  /// file from an editor, or one an older build wrote differently, must not take
  /// the whole library down.
  private func read(directory: URL, origin: TemplateOrigin) -> [PromptTemplate] {
    let fileManager = FileManager.default
    guard
      let entries = try? fileManager.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.isDirectoryKey],
        options: [.skipsHiddenFiles])
    else { return [] }
    let files = entries.filter {
      (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false
        && $0.pathExtension == "md"
    }
    return
      files
      .sorted { $0.lastPathComponent < $1.lastPathComponent }
      .compactMap { url in
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        var template = TemplateFileCodec.decode(text, origin: origin)
        template?.fileName = url.lastPathComponent
        return template
      }
  }

  // MARK: - Starters

  /// Writes the templates the app ships with into the home folder — each of them
  /// **once**.
  ///
  /// A fresh install has an empty library, and an empty ⌘T picker teaches nothing —
  /// see `StarterTemplates` for what the briefs are chosen to demonstrate. They are
  /// written as real files so they read, diff and edit like any other template.
  ///
  /// The marker in the home folder lists the ids this install has already seeded, and
  /// that is what keeps this from being annoying:
  /// - **Once per starter.** A starter whose id is in the marker is never written
  ///   again, so one you deleted stays deleted — and a starter added in a later build
  ///   still arrives, because its id isn't there yet.
  /// - **Never over anything.** A file already at that name is somebody's, and is
  ///   left exactly as it is even on a first run.
  ///
  /// Returns what it actually wrote, which is empty on every launch that adds nothing.
  @discardableResult
  public func seedStartersIfNeeded(_ starters: [PromptTemplate] = StarterTemplates.all) throws
    -> [PromptTemplate]
  {
    let marker = homeDirectory.appendingPathComponent(Self.seededMarker)
    var seeded = seededIDs(at: marker)
    let pending = starters.filter { !seeded.contains($0.id) }
    guard !pending.isEmpty else { return [] }
    try FileManager.default.createDirectory(at: homeDirectory, withIntermediateDirectories: true)
    var written: [PromptTemplate] = []
    for starter in pending {
      let url = homeDirectory.appendingPathComponent(starter.fileName)
      if !FileManager.default.fileExists(atPath: url.path) {
        var copy = starter
        copy.origin = .home
        try TemplateFileCodec.encode(copy).write(to: url, atomically: true, encoding: .utf8)
        written.append(copy)
      }
      seeded.insert(starter.id)
    }
    // The marker is written last and whole: a run that threw half way through should
    // try again, not leave someone with four of the eleven.
    try seeded.map(\.uuidString).sorted().joined(separator: "\n")
      .write(to: marker, atomically: true, encoding: .utf8)
    return written
  }

  /// The ids the marker records. An **empty** marker is the one 0.1.58-beta2 and
  /// beta3 wrote, before ids were recorded: those installs seeded every starter that
  /// existed at the time, so the empty file is read as exactly that set — the ones
  /// shipped since are what a later launch still owes them.
  private func seededIDs(at marker: URL) -> Set<UUID> {
    guard let text = try? String(contentsOf: marker, encoding: .utf8) else { return [] }
    let ids = text.split(separator: "\n").compactMap { UUID(uuidString: String($0)) }
    if ids.isEmpty { return StarterTemplates.seededBeforeIDsWereRecorded }
    return Set(ids)
  }

  /// A dotfile, so it never shows up as a template — `read` skips hidden files.
  public static let seededMarker = ".starters-seeded"

  // MARK: - Writing

  /// Saves a template. Returns where it actually landed: **home unless the caller
  /// explicitly asked for the project, and the project only when that folder is
  /// actually writable** — a read-only checkout or a repo that would reject the
  /// dotfolder falls back to home rather than losing the save.
  @discardableResult
  public func save(
    _ template: PromptTemplate, to requested: TemplateOrigin, projectPath: String?
  ) throws -> (template: PromptTemplate, origin: TemplateOrigin) {
    var directory = homeDirectory
    var origin = TemplateOrigin.home
    if requested.isProject, let projectPath, !projectPath.isEmpty,
      canWrite(to: projectDirectory(projectPath))
    {
      directory = projectDirectory(projectPath)
      origin = .project(projectPath)
    }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    var saved = template
    saved.origin = origin
    // A name that slugs onto a file somebody else's template already owns gets the
    // next free suffix rather than the other one's contents. Saving is not editing:
    // nothing in the app asks to overwrite a template, so a collision here is always
    // two different briefs that happen to be called the same thing.
    saved.fileName = availableFileName(saved.fileName, in: directory, keeping: saved.id)
    let text = TemplateFileCodec.encode(saved)
    try text.write(
      to: directory.appendingPathComponent(saved.fileName), atomically: true, encoding: .utf8)
    return (saved, origin)
  }

  /// `name.md`, or `name-2.md`, `name-3.md` … — the first spelling no *other*
  /// template holds. A file already carrying this template's own id is its own
  /// earlier version and is written over.
  private func availableFileName(
    _ preferred: String, in directory: URL, keeping id: UUID
  ) -> String {
    let base = preferred.hasSuffix(".md") ? String(preferred.dropLast(3)) : preferred
    var candidate = preferred
    var suffix = 1
    while let existing = try? String(
      contentsOf: directory.appendingPathComponent(candidate), encoding: .utf8),
      TemplateFileCodec.decode(existing, origin: .home)?.id != id
    {
      suffix += 1
      candidate = "\(base)-\(suffix).md"
    }
    return candidate
  }

  /// Saves an edit to a template that already exists — the Settings editor's Save.
  ///
  /// Distinct from `save` in the one way that matters: **the id is kept**, so every
  /// timed and composite loop following this template goes on following it across
  /// the edit. That is the whole point of editing rather than saving a new one.
  /// The file stays in its own location; only a rename moves it, and the old file is
  /// removed only once the new one is written and only when it is a different file.
  @discardableResult
  public func update(
    _ edited: PromptTemplate, replacing original: PromptTemplate
  ) throws -> PromptTemplate {
    let directory = directoryURL(for: original.origin)
    var saved = edited
    saved.id = original.id
    saved.origin = original.origin
    saved.fileName =
      edited.name == original.name
      ? original.fileName
      : availableFileName(
        PromptTemplate.fileName(for: edited.name), in: directory, keeping: original.id)
    let target = directory.appendingPathComponent(saved.fileName)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try TemplateFileCodec.encode(saved).write(to: target, atomically: true, encoding: .utf8)
    let source = directory.appendingPathComponent(original.fileName)
    if source != target { try? FileManager.default.removeItem(at: source) }
    return saved
  }

  /// Removes a template file. Used by Settings' manage list; deleting a project
  /// template deletes the file in the checkout — an explicit act on an explicit
  /// location, same as saving there.
  public func delete(_ template: PromptTemplate) throws {
    let directory: URL
    switch template.origin {
    case .home: directory = homeDirectory
    case .project(let path): directory = projectDirectory(path)
    }
    try FileManager.default.removeItem(at: directory.appendingPathComponent(template.fileName))
  }

  /// "Put it in the project instead" / "Keep it at home instead" — the quiet line
  /// after a save offers the other location, and this is the move it performs.
  /// Returns the template as it now is — the origin it actually landed on, and the
  /// filename it took there, which is not always the one it arrived with.
  @discardableResult
  public func move(
    _ template: PromptTemplate, to destination: TemplateOrigin, projectPath: String?
  ) throws -> PromptTemplate {
    guard destination != template.origin else { return template }
    let directory: URL
    let origin: TemplateOrigin
    if destination.isProject, let projectPath, !projectPath.isEmpty,
      canWrite(to: projectDirectory(projectPath))
    {
      directory = projectDirectory(projectPath)
      origin = .project(projectPath)
    } else {
      directory = homeDirectory
      origin = .home
    }
    let source = directoryURL(for: template.origin).appendingPathComponent(template.fileName)
    // The other location may already hold a different template of the same name — a
    // teammate's committed `review-diff.md` is exactly the case the design expects.
    // Moving must not write over it.
    var moved = template
    moved.fileName = availableFileName(template.fileName, in: directory, keeping: template.id)
    let target = directory.appendingPathComponent(moved.fileName)
    // The destination can be the source: asking to move a home template into a
    // project that won't take one falls back to home, which is where it already is.
    // Writing and then deleting "the original" would delete the file itself, so the
    // move that isn't a move stops here.
    guard target != source else { return template }
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    moved.origin = origin
    try TemplateFileCodec.encode(moved).write(to: target, atomically: true, encoding: .utf8)
    // Only remove the original once the copy landed; a failed write must leave
    // the template exactly where it was.
    try? FileManager.default.removeItem(at: source)
    return moved
  }

  private func directoryURL(for origin: TemplateOrigin) -> URL {
    switch origin {
    case .home: return homeDirectory
    case .project(let path): return projectDirectory(path)
    }
  }

  /// Whether a template could be written to this folder — **without creating it**.
  /// The design's rule is that nothing lands in a checkout by default, so the
  /// question "should the save fall back to home" must not itself put a
  /// `.graphcode/templates` in somebody's repository. An absent folder is answered
  /// by the nearest ancestor that does exist: if that is writable, the folder can be
  /// created when a save actually asks for one.
  public func canWrite(to url: URL) -> Bool {
    let fileManager = FileManager.default
    var candidate = url.standardizedFileURL
    while !fileManager.fileExists(atPath: candidate.path) {
      let parent = candidate.deletingLastPathComponent().standardizedFileURL
      guard parent != candidate else { return false }
      candidate = parent
    }
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
      isDirectory.boolValue
    else { return false }
    return fileManager.isWritableFile(atPath: candidate.path)
  }

  // MARK: - Watching

  /// Fires once whenever either location's contents change — an external edit, a
  /// `git pull` bringing a teammate's template in, a save from this or another
  /// window — so the library is current without a relaunch.
  ///
  /// A directory that does not exist yet cannot be watched, and that is the common
  /// case rather than the corner one: most projects have no `.graphcode/templates`
  /// until the day a teammate commits one. So the set of watched directories is
  /// re-armed on a slow poll — appearing, disappearing and being replaced wholesale
  /// (which is what `git checkout` and an atomic editor save both look like) all put
  /// the watch back on the right descriptor and report the change.
  public func watch(projectPath: String?) -> AsyncStream<Void> {
    #if canImport(Darwin)
      let directories =
        [homeDirectory]
        + (projectPath.map { [projectDirectory($0)] } ?? [])
      return AsyncStream { continuation in
        let arming = DirectoryWatch(directories: directories) { continuation.yield() }
        continuation.onTermination = { _ in arming.stop() }
      }
    #else
      // Linux builds the non-UI sources for CI, and the only thing that reads
      // templates there is the daemon's by-id resolve, which re-reads the directory
      // on every call. There is no library to keep live because there is no picker.
      return AsyncStream { $0.finish() }
    #endif
  }
}

#if canImport(Darwin)
  /// Keeps one `DispatchSource` per directory that currently exists, and re-arms as
  /// directories come and go. Separate from `TemplateStorage` because it owns mutable
  /// state with a lifetime — the storage type itself is a value anyone may copy.
  private final class DirectoryWatch: @unchecked Sendable {
    /// Slow on purpose: this only has to notice a directory *appearing*, which the
    /// dispatch sources cannot do for themselves. Everything that happens inside an
    /// already-watched directory is reported immediately by its source.
    private static let rearmInterval: DispatchTimeInterval = .seconds(2)

    private let queue = DispatchQueue(label: "graphcode.template-watch")
    private let directories: [URL]
    private let onChange: () -> Void
    private var sources: [URL: DispatchSourceFileSystemObject] = [:]
    private var timer: DispatchSourceTimer?
    private var stopped = false

    init(directories: [URL], onChange: @escaping () -> Void) {
      self.directories = directories
      self.onChange = onChange
      queue.async { [weak self] in self?.arm(reporting: false) }
      let timer = DispatchSource.makeTimerSource(queue: queue)
      timer.schedule(deadline: .now() + Self.rearmInterval, repeating: Self.rearmInterval)
      timer.setEventHandler { [weak self] in self?.arm(reporting: true) }
      timer.resume()
      self.timer = timer
    }

    func stop() {
      queue.async { [self] in
        stopped = true
        timer?.cancel()
        timer = nil
        for source in sources.values { source.cancel() }
        sources.removeAll()
      }
    }

    /// Brings `sources` back in line with which directories exist. `reporting` is false
    /// only for the very first pass, where the caller has just read the library itself
    /// and a yield would be a redundant re-read.
    private func arm(reporting: Bool) {
      guard !stopped else { return }
      var changed = false
      for url in directories {
        let exists = FileManager.default.fileExists(atPath: url.path)
        let watched = sources[url] != nil
        if exists, !watched, let source = makeSource(for: url) {
          sources[url] = source
          changed = true
        } else if !exists, watched {
          sources[url]?.cancel()
          sources[url] = nil
          changed = true
        }
      }
      if changed, reporting { onChange() }
    }

    private func makeSource(for url: URL) -> DispatchSourceFileSystemObject? {
      let descriptor = open(url.path, O_EVTONLY)
      guard descriptor >= 0 else { return nil }
      let source = DispatchSource.makeFileSystemObjectSource(
        fileDescriptor: descriptor, eventMask: [.write, .rename, .delete], queue: queue)
      source.setEventHandler { [weak self] in
        guard let self else { return }
        // A directory that was renamed or deleted out from under the descriptor keeps
        // reporting nothing useful; dropping it here lets the next re-arm re-open the
        // path, which is how a `git checkout` that swaps the folder is picked up.
        if source.data.contains(.delete) || source.data.contains(.rename) {
          source.cancel()
          sources[url] = nil
        }
        onChange()
      }
      source.setCancelHandler { close(descriptor) }
      source.resume()
      return source
    }
  }
#endif
