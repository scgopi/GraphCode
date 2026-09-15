import Foundation

struct ChildReport: Codable, Equatable {
  var arguments: [String]
  var workingDirectory: String
  var environmentValue: String?
}
if CommandLine.arguments.dropFirst().first == "--child" {
  let report = ChildReport(
    arguments: Array(CommandLine.arguments.dropFirst(2)),
    workingDirectory: FileManager.default.currentDirectoryPath,
    environmentValue: ProcessInfo.processInfo.environment["GRAPHCODE_PROCESS_SPIKE"])
  FileHandle.standardOutput.write(try JSONEncoder().encode(report))
  exit(0)
}
struct ProcessResult {
  var status: Int32
  var output: String
}
func run(
  _ executable: String,
  _ arguments: [String],
  workingDirectory: URL? = nil,
  environment: [String: String]? = nil
) throws -> ProcessResult {
  let process = Process()
  process.executableURL = URL(fileURLWithPath: executable)
  process.arguments = arguments
  process.currentDirectoryURL = workingDirectory
  process.environment = environment
  let output = Pipe()
  process.standardOutput = output
  process.standardError = output
  try process.run()
  let data = output.fileHandleForReading.readDataToEndOfFile()
  process.waitUntilExit()
  return ProcessResult(
    status: process.terminationStatus,
    output: String(decoding: data, as: UTF8.self))
}
let temporaryDirectory = FileManager.default.temporaryDirectory
  .appendingPathComponent("graphcode process spike \(UUID().uuidString)", isDirectory: true)
try FileManager.default.createDirectory(
  at: temporaryDirectory,
  withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
let currentExecutable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL.path
var environment = ProcessInfo.processInfo.environment
environment["GRAPHCODE_PROCESS_SPIKE"] = "inherited"
let directArguments = ["space value", #"quote"value"#, "雪"]
let direct = try run(
  currentExecutable,
  ["--child"] + directArguments,
  workingDirectory: temporaryDirectory,
  environment: environment)
guard direct.status == 0,
  let report = try? JSONDecoder().decode(ChildReport.self, from: Data(direct.output.utf8))
else {
  fatalError("Direct executable launch did not preserve argv, cwd, and environment")
}
FileHandle.standardOutput.write(
  Data(
    [
      "direct.arguments=\(report.arguments)",
      "direct.cwd=\(report.workingDirectory)",
      "direct.environment=\(report.environmentValue ?? "nil")",
      "",
    ].joined(separator: "\n").utf8))
guard report.arguments == directArguments,
  URL(fileURLWithPath: report.workingDirectory).standardizedFileURL
    == temporaryDirectory.standardizedFileURL,
  report.environmentValue == "inherited"
else {
  fatalError("Direct executable launch changed argv, cwd, or environment")
}
let commandScript = temporaryDirectory.appendingPathComponent("echo args.cmd")
try "@echo off\r\necho CMD_OK:%~1\r\n".write(
  to: commandScript,
  atomically: true,
  encoding: .utf8)
var commandScriptDirectlyLaunches = false
do {
  let result = try run(commandScript.path, ["space value"])
  commandScriptDirectlyLaunches =
    result.status == 0 && result.output.contains("CMD_OK:space value")
} catch {}
let commandHost = #"C:\Windows\System32\cmd.exe"#
let hostedCommand = try run(
  commandHost,
  ["/d", "/c", "call", commandScript.path, "space value"])
FileHandle.standardOutput.write(
  Data("cmd.status=\(hostedCommand.status) cmd.output=\(hostedCommand.output)\n".utf8))
guard hostedCommand.status == 0, hostedCommand.output.contains("CMD_OK:space value") else {
  fatalError("cmd.exe did not launch a .cmd shim with a spaced argument")
}
let powerShellScript = temporaryDirectory.appendingPathComponent("echo args.ps1")
try #"param([string]$Value) Write-Output "PS_OK:$Value""#.write(
  to: powerShellScript,
  atomically: true,
  encoding: .utf8)
let powerShell = #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#
var powerShellScriptDirectlyLaunches = false
do {
  let result = try run(powerShellScript.path, ["-Value", "space value"])
  powerShellScriptDirectlyLaunches =
    result.status == 0 && result.output.contains("PS_OK:space value")
} catch {}
let hostedPowerShell = try run(
  powerShell,
  ["-NoLogo", "-NoProfile", "-File", powerShellScript.path, "-Value", "space value"])
guard hostedPowerShell.status == 0, hostedPowerShell.output.contains("PS_OK:space value") else {
  fatalError("PowerShell did not launch a .ps1 shim with a spaced argument")
}
print("swift-process direct-exe-argv-cwd-environment: ok")
print("swift-process direct-cmd-launches=\(commandScriptDirectlyLaunches)")
print("swift-process direct-ps1-launches=\(powerShellScriptDirectlyLaunches)")
print("swift-process cmd-hosted-shim: ok")
print("swift-process powershell-hosted-shim: ok")
