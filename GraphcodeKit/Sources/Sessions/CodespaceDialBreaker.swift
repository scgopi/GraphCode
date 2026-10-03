import Foundation

/// The daemon's side of `CodespaceDialSchedule`: one outage clock per codespace, shared
/// by every read and ensure that would otherwise each rediscover the outage on its own
/// clock. Plain ssh hosts are never gated — their dials multiplex over one connection and
/// cost no API calls.
///
/// A human restarts the schedule: pressing Enter at a paused terminal pane, or selecting
/// any loop of the codespace in the app, touches `reconnectMarker(for:)`, and a marker
/// newer than the outage clears it — holding or paused alike — so the next read or
/// ensure dials at once. A file rather than a daemon command because the pane is a shell
/// loop in the app's process, and a `stat` spends nothing.
///
/// Paused, one dial per `slowRetryInterval` still goes through, whichever reader or
/// ensure asks first. The one that reaches the codespace clears the outage for all of
/// them and calls `onRecovered`, which is how the finished loops on the codespace get
/// restored as well as the running ones.
public actor CodespaceDialBreaker {
  static let shared = CodespaceDialBreaker(onRecovered: { location in
    ZmxSessionLauncher.markRedialed(location)
  })

  private let schedule: CodespaceDialSchedule
  private let markerDirectory: URL
  private let onRecovered: @Sendable (RemoteProjectLocation) -> Void
  private var downSince: [String: Date] = [:]
  private var lastPausedDial: [String: Date] = [:]

  init(
    schedule: CodespaceDialSchedule = .standard,
    markerDirectory: URL = CodespaceDialBreaker.defaultMarkerDirectory,
    onRecovered: @escaping @Sendable (RemoteProjectLocation) -> Void = { _ in }
  ) {
    self.schedule = schedule
    self.markerDirectory = markerDirectory
    self.onRecovered = onRecovered
  }

  public static var defaultMarkerDirectory: URL {
    RemoteProjectLocation.codespaceStateDirectory
  }

  public static func reconnectMarker(
    for location: RemoteProjectLocation, in directory: URL = defaultMarkerDirectory
  ) -> URL {
    directory.appendingPathComponent("\(location.host).reconnect")
  }

  /// Asks every dialer of this codespace — the daemon's reads and ensures, and any open
  /// terminal pane — to restart the schedule and redial now.
  ///
  /// At most once per `minimumInterval`: every selection of a loop asks, and without a
  /// floor a human browsing the loops of a codespace that is down would keep restarting
  /// the schedule, never reaching the pause and spending a dial per pane per click.
  public static func requestReconnect(
    for location: RemoteProjectLocation, in directory: URL = defaultMarkerDirectory,
    minimumInterval: TimeInterval = 30, now: Date = Date()
  ) {
    let marker = reconnectMarker(for: location, in: directory)
    if let touched = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[
      .modificationDate] as? Date,
      now.timeIntervalSince(touched) < minimumInterval
    {
      return
    }
    try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    FileManager.default.createFile(atPath: marker.path, contents: nil)
    try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: marker.path)
  }

  func permits(_ location: RemoteProjectLocation, now: Date = Date()) -> Bool {
    guard location.isCodespace, let since = downSince[location.host] else { return true }
    if reconnectRequested(for: location, after: since) {
      clearOutage(location.host)
      return true
    }
    switch schedule.verdict(secondsDown: now.timeIntervalSince(since)) {
    case .dial: return true
    case .hold: return false
    case .paused:
      let pausedAt = since.addingTimeInterval(TimeInterval(schedule.pauseAfter))
      let last = lastPausedDial[location.host] ?? pausedAt
      guard now.timeIntervalSince(last) >= TimeInterval(schedule.slowRetryInterval) else {
        return false
      }
      lastPausedDial[location.host] = now
      return true
    }
  }

  func record(_ location: RemoteProjectLocation, reached: Bool, now: Date = Date()) {
    guard location.isCodespace else { return }
    if reached {
      guard downSince[location.host] != nil else { return }
      clearOutage(location.host)
      onRecovered(location)
    } else if downSince[location.host] == nil {
      downSince[location.host] = now
    }
  }

  private func clearOutage(_ host: String) {
    downSince.removeValue(forKey: host)
    lastPausedDial.removeValue(forKey: host)
  }

  private func reconnectRequested(for location: RemoteProjectLocation, after since: Date) -> Bool {
    let marker = Self.reconnectMarker(for: location, in: markerDirectory)
    guard
      let touched = (try? FileManager.default.attributesOfItem(atPath: marker.path))?[
        .modificationDate] as? Date
    else { return false }
    return touched > since
  }
}
