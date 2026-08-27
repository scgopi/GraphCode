import Foundation

/// Which *file* a path currently names — device, inode, and size (#199).
///
/// `graphcoded` compares this at runtime against what it recorded at launch to notice
/// that `DaemonBootstrap` swapped a new binary underneath it. The install always stages
/// a copy and renames it into place, so an update lands as a fresh inode; size rides
/// along as the belt, the same reasoning as `DaemonBootstrap.stamp`. Modification time
/// is deliberately absent — the two stat fields that matter are portable across the
/// Darwin and Linux builds, and a rename never preserves the inode anyway.
public struct ExecutableIdentity: Equatable, Sendable {
  public let device: Int
  public let inode: Int
  public let size: Int

  /// The identity of the file at `path`, or `nil` when it cannot be read — a relative
  /// argv[0] from a hand launch, or the instant mid-swap where the old binary is gone
  /// and the new one not yet renamed in. Callers treat `nil` as "look again later",
  /// never as "changed": exiting on a transient miss would flap.
  public static func of(path: String) -> ExecutableIdentity? {
    guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
      let device = attributes[.systemNumber] as? Int,
      let inode = attributes[.systemFileNumber] as? Int,
      let size = attributes[.size] as? Int
    else { return nil }
    return ExecutableIdentity(device: device, inode: inode, size: size)
  }
}
