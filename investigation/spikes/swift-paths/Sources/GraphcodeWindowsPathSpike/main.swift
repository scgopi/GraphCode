import Foundation

let projectPath = #"C:\Projects\GraphCode Demo"#
let supportOverride = #"D:\GraphCodeState"#
let home = FileManager.default.homeDirectoryForCurrentUser
let registryAcceptsPath = projectPath.hasPrefix("/")
let currentSupportResolution =
  supportOverride.hasPrefix("/")
  ? URL(fileURLWithPath: supportOverride, isDirectory: true)
  : home.appendingPathComponent(supportOverride, isDirectory: true)
let persistenceFileName =
  projectPath.replacingOccurrences(of: "/", with: "_") + ".json"
print("project=\(projectPath)")
print("registryAcceptsPath=\(registryAcceptsPath)")
print("supportOverrideResolved=\(currentSupportResolution.path)")
print("persistenceFileName=\(persistenceFileName)")
guard registryAcceptsPath == false else {
  fatalError("Expected the current POSIX absolute-path check to reject a Windows drive path")
}
guard currentSupportResolution.path != supportOverride else {
  fatalError("Expected the current support-directory logic to misclassify a Windows drive path")
}
guard persistenceFileName.contains("\\") && persistenceFileName.contains(":") else {
  fatalError("Expected the current persistence filename sanitizer to retain Windows separators")
}
print("observed-current-windows-path-blockers")
