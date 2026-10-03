import Foundation
import GraphcodeKit

extension GhosttyTerminalView {
  /// Nod's half of `launchPrefix`: the runtime by absolute path, its state directory in
  /// the environment, and the same `nodArguments` the daemon launches with. `nil` for a
  /// remote project or a runtime that is not there, which leaves the pane a plain shell
  /// rather than a command that cannot run. The lineage brief rides a fresh launch only,
  /// as it does from `ZmxSessionLauncher.nodArguments`.
  func nodLaunchPrefix(settings: GraphcodeSettings, fresh: Bool = true) -> [String]? {
    guard remoteLocation == nil, let executable = NodRuntimeLocator.binaryURL()?.path,
      let nodeID = SurfaceRef.nodeID(fromZmxSessionName: sessionName)
    else { return nil }
    let goalFile = NodRuntimeLocator.stateDirectory(forNodeID: nodeID)
      .appendingPathComponent(NodProtocol.goalFileName).path
    let arguments = backend.nodArguments(
      nodeID: nodeID, loopType: loopType, settings: settings,
      workingDirectory: effectiveWorkingDirectory,
      goalFile: loopType == .goalBased && FileManager.default.fileExists(atPath: goalFile)
        ? goalFile : nil,
      inheritFile: fresh ? lineage?.briefPath : nil,
      unattended: loopType == .timeBased || lineage?.kind == .compositeChild)
    let environment = NodRuntimeLocator.environment(forNodeID: nodeID, projectPath: projectPath)
      .sorted { $0.key < $1.key }
      .map { "\($0.key)=\(PresenceHooks.singleQuoted($0.value))" }
    return ["exec", "env"] + environment + [PresenceHooks.singleQuoted(executable)]
      + arguments.map(PresenceHooks.singleQuoted)
  }
}
