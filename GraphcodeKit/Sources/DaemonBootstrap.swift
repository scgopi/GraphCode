import Foundation

// launchd, quarantine xattrs, `~/Library/LaunchAgents` — this whole mechanism is the
// macOS app's drag-to-Applications install, and only the app calls it. A Linux install
// story (systemd user unit or equivalent) would be a sibling, not a port of this.
#if os(macOS)

  /// Installs the helpers a shipped `graphcode.app` carries inside itself — `graphcoded` and
  /// `zmx` — and loads the daemon, so dragging the app to `/Applications` is the whole
  /// installation.
  ///
  /// **Only ever acts on a packaged build.** `make release-dmg` copies the two binaries into
  /// `Contents/Resources/bin`; nothing else does. A build run from Xcode has no such
  /// directory, so this is a no-op there and a developer's own
  /// `make install-zmx install-cli daemon-install` setup — which usually points at
  /// DerivedData — is left exactly as it is.
  ///
  /// Re-runs only when the bundled binaries differ from what's installed, tracked by a stamp
  /// file. That makes app updates carry daemon updates without a reinstall, and makes
  /// ordinary launches cost one small file read — plus one `launchctl print`, because a
  /// launch also has to answer the question no file on disk can: whether the daemon the
  /// stamp vouches for is actually loaded.
  public enum DaemonBootstrap {
    public enum Outcome: Equatable {
      /// Not a packaged build, so there was nothing to install.
      case notPackaged
      /// Already installed and current.
      case upToDate
      /// Installed and current on disk, but launchd had lost the agent; it was loaded again.
      case reloaded
      case installed
      case failed(String)
    }

    /// One agent per workspace, so that opening a second one installs a daemon of its own
    /// instead of rewriting the first's. The default workspace keeps the bare label it has
    /// always had — an existing install must not see its agent renamed.
    static var label: String { Workspace.current.daemonLabel }
    private static let appBundleIdentifier = "dev.graphcode.app"
    /// `graphcode` here is the CLI, not the app — a different product that happens to share
    /// the name a human types. Shipping it matters: `~/.graphcode/bin` is what the README
    /// tells people to put on their PATH, and without this a drag-to-Applications install
    /// would leave that promise unmet.
    private static let helpers = ["graphcoded", "zmx", "graphcode"]

    /// The helpers a packaged app carries, or `nil` when this isn't one.
    static func bundledHelperDirectory(in bundle: Bundle = .main) -> URL? {
      guard let resources = bundle.resourceURL else { return nil }
      let binary = resources.appendingPathComponent("bin", isDirectory: true)
      let allPresent = helpers.allSatisfy {
        FileManager.default.isExecutableFile(atPath: binary.appendingPathComponent($0).path)
      }
      return allPresent ? binary : nil
    }

    static var stampURL: URL {
      SupportDirectory.url.appendingPathComponent("installed-helpers.txt")
    }

    /// Identifies *which* helpers are installed, without hashing megabytes on every launch.
    /// Size plus modification time is enough: these come from a build, so any new copy
    /// differs in at least one.
    static func stamp(forHelpersIn directory: URL) -> String {
      helpers.compactMap { name -> String? in
        let path = directory.appendingPathComponent(name).path
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
          let size = attributes[.size] as? Int,
          let modified = attributes[.modificationDate] as? Date
        else { return nil }
        return "\(name):\(size):\(Int(modified.timeIntervalSince1970))"
      }
      .joined(separator: "\n")
    }

    /// Whether every helper is actually present and runnable where it was installed.
    ///
    /// The stamp alone cannot answer this: it records which *bundle* was installed, not
    /// whether the installed copies still exist. A bin directory that lost a helper — an
    /// interrupted install, a hand-run `rm`, a cleanup tool — while the stamp survived
    /// produced an app that reported itself up to date over a missing daemon, forever.
    /// That is the "the beta is corrupted" failure: nothing was corrupt, the bootstrap
    /// just refused to look.
    static func helpersInstalled(in directory: URL = SupportDirectory.binDirectory) -> Bool {
      helpers.allSatisfy {
        FileManager.default.isExecutableFile(atPath: directory.appendingPathComponent($0).path)
      }
    }

    /// The bundle's helper stamp when it no longer matches the one this workspace
    /// installed from it — a bundle replaced underneath a running app, which is what a
    /// `brew upgrade`, a DMG dragged over /Applications, or an install whose relaunch was
    /// declined all leave behind. `nil` when they agree, or when there is nothing packaged
    /// to compare.
    ///
    /// Deliberately only the three `stat`s the stamp is made of: no launchctl probe, no
    /// copy, no daemon reload. This is asked every time a window comes forward, and none of
    /// `installIfNeeded`'s work is work to repeat on activation — nor would it be *correct*
    /// there. Installing the new helpers under an app whose own code was swapped on disk
    /// leaves a new daemon serving an old window, which is a worse pairing than the stale
    /// one it replaced. The answer belongs to the human as a relaunch prompt; the relaunch
    /// is what runs the bootstrap, on both halves at once.
    public static func changedBundleStamp() -> String? {
      guard let bundled = bundledHelperDirectory() else { return nil }
      let expected = stamp(forHelpersIn: bundled)
      guard !expected.isEmpty else { return nil }
      let installed = try? String(contentsOf: stampURL, encoding: .utf8)
      return expected == installed ? nil : expected
    }

    @discardableResult
    public static func installIfNeeded() -> Outcome {
      guard let bundled = bundledHelperDirectory() else { return .notPackaged }
      // Whatever this workspace's own outcome, carry the update to the workspaces nobody
      // has opened (#199) — off the main thread, because a stale sibling daemon that
      // predates its SIGTERM handler can take launchd's full escalation (~29s, #167) to
      // die, and app launch must not wait on it.
      defer { DispatchQueue.global().async { refreshClosedSiblingWorkspaces(from: bundled) } }

      let expected = stamp(forHelpersIn: bundled)
      let current = try? String(contentsOf: stampURL, encoding: .utf8)
      if current == expected, helpersInstalled(), launchAgentIsCurrent() {
        // Everything a file can record is right. The one thing no file records is whether
        // launchd still has the agent, and it routinely does not: an agent loaded the
        // legacy way is not re-bootstrapped into the next login session, so a reboot or a
        // logout leaves a correct install with no daemon behind it and nothing to say so.
        if daemonIsLoaded() { return .upToDate }
        reloadDaemon()
        return .reloaded
      }

      do {
        try installHelpers(from: bundled)
        try writeLaunchAgent()
        reloadDaemon()
        try expected.write(to: stampURL, atomically: true, encoding: .utf8)
        return .installed
      } catch {
        // Written somewhere a human (or a bug report) can find: the app has no console,
        // and a bootstrap that failed silently is how a machine ends up looking
        // "corrupted" with nothing to say why.
        appendReport(
          "\(Date().ISO8601Format())  helper install failed: \(error)\n",
          to: SupportDirectory.url.appendingPathComponent("bootstrap.err.log"))
        return .failed("\(error)")
      }
    }

    /// Brings every workspace this app is *not* running to the bundled helpers (#199).
    ///
    /// `installIfNeeded` acts on the current workspace only, and each workspace's daemon
    /// is respawned from its own `bin` — so a workspace whose window was never opened
    /// after an update kept an old daemon running old code under `KeepAlive` forever,
    /// which is how a leak fixed months ago goes on leaking under a new version's name.
    ///
    /// A workspace with a live app instance (`WorkspaceLock.holder`) is skipped: installing
    /// new helpers under a running window makes the new-daemon/old-window pairing
    /// `changedBundleStamp` exists to prevent, and that instance updates itself at its own
    /// relaunch. A workspace directory with no launch agent has no daemon to serve and is
    /// left alone too.
    static func refreshClosedSiblingWorkspaces(from bundled: URL) {
      let expected = stamp(forHelpersIn: bundled)
      guard !expected.isEmpty else { return }
      let current = Workspace.current
      // An instance pointed somewhere the workspace scan would never find — a
      // `GRAPHCODE_SUPPORT_DIR=/tmp/…` test daemon, a `~/.graphcode.dev` — is isolated by
      // intent. Before this feature it touched nothing outside its own directory, and a
      // refresh from it would break exactly that isolation.
      guard isStandardWorkspaceDirectory(current.url) else { return }
      for workspace in Workspace.all() where workspace.id != current.id {
        guard WorkspaceLock.holder(of: workspace) == nil else { continue }
        let agentURL = launchAgentURL(forLabel: workspace.daemonLabel)
        guard FileManager.default.fileExists(atPath: agentURL.path) else { continue }
        let binDirectory = workspace.url.appendingPathComponent("bin", isDirectory: true)
        let stampFile = workspace.url.appendingPathComponent("installed-helpers.txt")
        let installed = try? String(contentsOf: stampFile, encoding: .utf8)
        if installed == expected, helpersInstalled(in: binDirectory) { continue }
        // Direction matters: any packaged copy that gets launched runs this — an old DMG
        // still sitting in ~/Downloads included — and "different" alone would let it
        // rewrite every closed workspace *backward* and bounce their daemons, ping-ponging
        // versions with each alternating launch. Helper modification times come from the
        // build, so newest-wins is version order without inventing a version file.
        if stampRegresses(from: installed, to: expected) { continue }
        do {
          try installHelpers(from: bundled, to: binDirectory)
          let plist = launchAgentPlist(
            daemonPath: binDirectory.appendingPathComponent("graphcoded").path,
            supportDirectory: workspace.url.path, workspace: workspace)
          if !launchAgentIsCurrent(at: agentURL, expected: plist) {
            let data = try PropertyListSerialization.data(
              fromPropertyList: plist, format: .xml, options: 0)
            try data.write(to: agentURL, options: .atomic)
          }
          // The reload matters most on the release that introduces the staleness timer:
          // a sibling daemon older than the timer would never notice its binary changed.
          // Once every daemon carries the timer this is a minute of immediacy, no more.
          reloadDaemon(
            serviceTarget: "\(domainTarget)/\(workspace.daemonLabel)", agentURL: agentURL)
          try expected.write(to: stampFile, atomically: true, encoding: .utf8)
        } catch {
          // The sibling's own directory, so the report is found next to the daemon it
          // concerns — same reasoning, and the same append, as `installIfNeeded`'s log:
          // a failure here recurs every launch until the stamp lands, and each report
          // must not erase the one before it.
          appendReport(
            "\(Date().ISO8601Format())  sibling helper refresh failed: \(error)\n",
            to: workspace.url.appendingPathComponent("bootstrap.err.log"))
        }
      }
    }

    /// Whether `url` is a workspace directory the scan in `Workspace.all` would find on
    /// its own: the default `~/.graphcode`, or a `~/.graphcode-<slug>` sibling. Anything
    /// else reached this process only through `GRAPHCODE_SUPPORT_DIR`.
    static func isStandardWorkspaceDirectory(
      _ url: URL, home: URL = URL(fileURLWithPath: NSHomeDirectory())
    ) -> Bool {
      let standardized = url.standardizedFileURL
      guard standardized.deletingLastPathComponent().path == home.standardizedFileURL.path
      else { return false }
      let name = standardized.lastPathComponent
      return name == ".graphcode" || name.hasPrefix(Workspace.directoryPrefix)
    }

    /// Whether replacing helpers stamped `installed` with ones stamped `expected` would
    /// move a workspace *backward*. Judged by the newest modification time each stamp
    /// records: those come from the build, so a strictly older bundle reads strictly
    /// older. An unreadable stamp on either side regresses nothing — a workspace with no
    /// stamp is simply behind.
    static func stampRegresses(from installed: String?, to expected: String) -> Bool {
      guard let installed,
        let theirs = newestModification(inStamp: installed),
        let mine = newestModification(inStamp: expected)
      else { return false }
      return mine < theirs
    }

    static func newestModification(inStamp stamp: String) -> Int? {
      stamp.split(separator: "\n")
        .compactMap { line in Int(line.split(separator: ":").last ?? "") }
        .max()
    }

    static func appendReport(_ report: String, to log: URL) {
      if let handle = try? FileHandle(forWritingTo: log) {
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(report.utf8))
        try? handle.close()
      } else {
        try? report.write(to: log, atomically: true, encoding: .utf8)
      }
    }

    static func installHelpers(
      from bundled: URL, to destination: URL = SupportDirectory.binDirectory
    ) throws {
      let fileManager = FileManager.default
      try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

      for name in helpers {
        let target = destination.appendingPathComponent(name)
        // Stage the copy next to the target, then swap. The earlier remove-then-copy
        // order meant a copy that failed left neither binary — an interrupted first
        // launch gutted `~/.graphcode/bin`, and with the stamp check above blind to it,
        // every later launch called that state up to date. Staging costs one rename and
        // means the old helper survives until its replacement has fully landed.
        //
        // The swap also gives the target a fresh inode, which preserves the original fix
        // here: writing over a path macOS has already validated leaves a stale cached
        // signature and the result is SIGKILLed at exec ("Taskgated Invalid Signature") —
        // a near-silent failure, since the binary dies before it can print anything.
        //
        // What deliberately does *not* happen anymore: an ad-hoc re-sign. The copy keeps
        // the bundle's own Developer ID signature byte for byte; forcing `--sign -` over
        // it replaced a notarized identity with an anonymous one. Combined with the
        // quarantine flag `copyItem` faithfully carries over from a downloaded install,
        // that produced a quarantined, ad-hoc-signed daemon — which launchd's first spawn
        // on a fresh machine greets with "Apple could not verify 'graphcoded' is free of
        // malware". It looked fine on the build machine only because its quarantine was
        // already marked approved. Clearing the xattr is the install step Finder would
        // have performed had a human dragged the helper out themselves.
        //
        // Staged under this process's pid, because two refreshers can meet in one bin:
        // after an update relaunches every open workspace, each relaunched instance sees
        // the same closed siblings stale and refreshes them concurrently — closed
        // workspaces have no `WorkspaceLock` to serialize on. A shared staging name let
        // one refresher delete the file another was about to rename, leaving a workspace
        // with a written stamp and no daemon. Per-pid names cannot collide; the loser of
        // the final rename merely throws, and the defer clears its leftover.
        let staged = destination.appendingPathComponent("\(name).new.\(getpid())")
        try? fileManager.removeItem(at: staged)
        defer { try? fileManager.removeItem(at: staged) }
        try fileManager.copyItem(at: bundled.appendingPathComponent(name), to: staged)
        clearQuarantine(staged)
        try? fileManager.removeItem(at: target)
        try fileManager.moveItem(at: staged, to: target)
      }
    }

    /// Drops `com.apple.quarantine` from an installed helper. Failure is ignored: a file
    /// that never had the xattr (a build-machine install) errors with ENOATTR, and that
    /// is the healthy case.
    static func clearQuarantine(_ url: URL) {
      removexattr(url.path, "com.apple.quarantine", 0)
    }

    static var launchAgentURL: URL { launchAgentURL(forLabel: label) }

    static func launchAgentURL(forLabel label: String) -> URL {
      URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }

    /// Takes a workspace's daemon out of launchd and removes its agent — the first step of
    /// deleting a workspace, and the one that cannot be skipped: the agent is `KeepAlive`,
    /// so a daemon left loaded over a deleted directory is restarted by launchd and
    /// recreates it.
    ///
    /// Refuses the default workspace outright. There is no path through the UI that asks
    /// for this, and the cost of being wrong is an install whose daemon is gone.
    public static func removeLaunchAgent(for workspace: Workspace) {
      guard !workspace.isDefault else { return }
      let url = launchAgentURL(forLabel: workspace.daemonLabel)
      launchctl(["bootout", "\(domainTarget)/\(workspace.daemonLabel)"])
      // The legacy pair as well, for an agent loaded by a build old enough to have used it.
      launchctl(["unload", url.path])
      try? FileManager.default.removeItem(at: url)
    }

    /// Built here rather than shipped as a template file: the two paths it needs are already
    /// known at runtime, and a template would be one more thing to keep in sync.
    ///
    /// `workspace` decides both the label and whether the daemon is told where to look.
    /// launchd starts an agent with its own minimal environment, so a named workspace's
    /// daemon inherits nothing from the app that installed it and would compute
    /// `~/.graphcode` — serving the default workspace's graphs under the second
    /// workspace's label. The default workspace passes no `EnvironmentVariables` at all,
    /// which keeps its plist byte-for-byte what it has always been: anything else and
    /// `launchAgentIsCurrent` would report every existing install as stale and bounce a
    /// daemon that was running perfectly well.
    static func launchAgentPlist(
      daemonPath: String, supportDirectory: String, workspace: Workspace = .current
    ) -> [String: Any] {
      var plist: [String: Any] = [
        "Label": workspace.daemonLabel,
        "ProgramArguments": [daemonPath],
        "RunAtLoad": true,
        "KeepAlive": true,
        "StandardOutPath": "\(supportDirectory)/graphcoded.log",
        "StandardErrorPath": "\(supportDirectory)/graphcoded.err.log",
        // `graphcoded` is a bare signed executable, not a bundle, so it carries no name of
        // its own. Without this key macOS has nothing to call the agent and falls back to
        // the only name it can read — the one on the signing certificate — which is how
        // Login Items and the "can run in the background" notification came to announce a
        // stranger's personal name to every user. `launchd.plist(5)` names this key as
        // exactly what an app installing a legacy plist should set.
        "AssociatedBundleIdentifiers": [appBundleIdentifier],
      ]
      if !workspace.isDefault {
        plist["EnvironmentVariables"] = [SupportDirectory.environmentKey: supportDirectory]
      }
      return plist
    }

    static func currentLaunchAgentPlist() -> [String: Any] {
      launchAgentPlist(
        daemonPath: SupportDirectory.binDirectory.appendingPathComponent("graphcoded").path,
        supportDirectory: SupportDirectory.url.path)
    }

    /// Whether the installed agent is the one this build would write.
    ///
    /// The check this replaced only asked whether the file existed, which meant a change to
    /// the agent itself reached a machine solely as a side effect of its helper binaries
    /// changing in the same release. Comparing the content makes an agent-only fix — the
    /// naming key above — land on the next launch, and does the same for the next one.
    static func launchAgentIsCurrent(
      at url: URL = launchAgentURL, expected: [String: Any] = currentLaunchAgentPlist()
    ) -> Bool {
      guard let data = try? Data(contentsOf: url),
        let installed = try? PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any]
      else { return false }
      return NSDictionary(dictionary: installed).isEqual(to: expected)
    }

    private static func writeLaunchAgent() throws {
      let url = launchAgentURL
      try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
      let data = try PropertyListSerialization.data(
        fromPropertyList: currentLaunchAgentPlist(), format: .xml, options: 0)
      try data.write(to: url, options: .atomic)
    }

    static var domainTarget: String { "gui/\(getuid())" }
    static var serviceTarget: String { "\(domainTarget)/\(label)" }

    /// Whether launchd currently holds the agent in this login session.
    ///
    /// Asking the plist, the helpers or the stamp cannot answer this — all three describe
    /// the disk, and the disk stays perfectly correct while the daemon is gone. `print`
    /// exits non-zero with "Could not find service" when the label is absent from the
    /// domain, which is the only durable signal there is.
    static func daemonIsLoaded(probe: ([String]) -> Int32 = launchctlStatus) -> Bool {
      probe(["print", serviceTarget]) == 0
    }

    /// Bootout then bootstrap. The teardown is what makes an app update actually take:
    /// without it, launchd keeps running the daemon binary it already started, and the
    /// freshly installed one never gets used.
    ///
    /// `bootstrap`/`bootout` rather than `load`/`unload` because the legacy pair registers
    /// the agent only for the session it is run in — the reason a reboot could strand a
    /// healthy install without a daemon. The legacy pair stays as a fallback for the case
    /// where the modern one is refused.
    private static func reloadDaemon() {
      reloadDaemon(serviceTarget: serviceTarget, agentURL: launchAgentURL)
    }

    private static func reloadDaemon(serviceTarget: String, agentURL: URL) {
      launchctl(["bootout", serviceTarget])
      if launchctlStatus(["bootstrap", domainTarget, agentURL.path]) != 0 {
        launchctl(["unload", agentURL.path])
        launchctl(["load", agentURL.path])
      }
    }

    private static func launchctl(_ arguments: [String]) {
      _ = launchctlStatus(arguments)
    }

    static func launchctlStatus(_ arguments: [String]) -> Int32 {
      let process = Process()
      process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
      process.arguments = arguments
      process.standardOutput = FileHandle.nullDevice
      process.standardError = FileHandle.nullDevice
      do { try process.run() } catch { return -1 }
      process.waitUntilExit()
      return process.terminationStatus
    }
  }

#endif
