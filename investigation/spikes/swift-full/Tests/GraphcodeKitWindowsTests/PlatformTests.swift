import Foundation
import GraphcodeKit
import XCTest

final class PlatformTests: XCTestCase {
  func testSupportDirectoryAcceptsWindowsAbsoluteOverride() {
    let home = URL(fileURLWithPath: #"C:\Users\Test User"#, isDirectory: true)
    let root = SupportDirectory.url(
      environment: [SupportDirectory.environmentKey: #"D:\Graph Code\State"#],
      homeDirectory: home)

    XCTAssertEqual(root.path, #"D:/Graph Code/State"#)
  }

  func testSupportDirectoryResolvesRelativeOverrideAgainstHome() {
    let home = URL(fileURLWithPath: #"C:\Users\Test User"#, isDirectory: true)
    let root = SupportDirectory.url(
      environment: [SupportDirectory.environmentKey: "graphcode-dev"],
      homeDirectory: home)

    XCTAssertEqual(
      root.path,
      home.appendingPathComponent("graphcode-dev", isDirectory: true).path)
  }

  func testCanonicalProjectPathAcceptsDrivePathAndRejectsRoot() throws {
    let paths = WindowsPlatformPaths(
      homeDirectory: URL(fileURLWithPath: #"C:\Users\Test User"#, isDirectory: true))
    let canonical = try paths.canonicalProjectPath(#"C:\Projects\GraphCode Demo\.\src\.."#)

    XCTAssertTrue(canonical.contains(#"C:/Projects/GraphCode Demo"#))
    XCTAssertThrowsError(try paths.canonicalProjectPath(#"C:\"#))
  }

  func testPersistenceKeyIsSafeStableAndDistinct() {
    let paths = WindowsPlatformPaths()
    let first = paths.persistenceKey(forProjectPath: #"C:\Projects\GraphCode Demo"#)
    let equivalent = paths.persistenceKey(forProjectPath: #"C:\Projects\GraphCode Demo\."#)
    let second = paths.persistenceKey(forProjectPath: #"C:\Projects\Other"#)

    XCTAssertEqual(first, equivalent)
    XCTAssertNotEqual(first, second)
    XCTAssertNotNil(first.range(of: #"^v1-[0-9a-f]{64}$"#, options: .regularExpression))
    XCTAssertLessThanOrEqual(first.utf8.count, 80)
  }

  func testWindowsShellClassifiesScriptExtensions() throws {
    let strategy = WindowsShellStrategy(
      commandPrompt: URL(fileURLWithPath: #"C:\Windows\System32\cmd.exe"#),
      powerShell: URL(
        fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#))
    let script = URL(fileURLWithPath: #"C:\Tools\echo args.cmd"#)
    let invocation = try strategy.invocation(
      executable: script,
      arguments: ["space value", #"quote"value"#],
      workingDirectory: nil,
      environment: [:])

    XCTAssertEqual(invocation.kind, .commandPrompt)
    XCTAssertEqual(invocation.request.arguments.prefix(4), ["/d", "/c", "call", script.path])
    XCTAssertEqual(invocation.request.arguments.suffix(2), ["space value", #"quote"value"#])
  }

  func testProcessRunnerCapturesCwdEnvironmentAndOutput() async throws {
    let comSpec =
      ProcessInfo.processInfo.environment["ComSpec"]
      ?? ProcessInfo.processInfo.environment["COMSPEC"]
      ?? "cmd.exe"
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-platform-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let runner = FoundationProcessRunner()
    let result = try await runner.run(
      ProcessRequest(
        executable: URL(fileURLWithPath: comSpec),
        arguments: ["/d", "/c", "echo %GRAPHCODE_PLATFORM_TEST% & cd"],
        workingDirectory: directory,
        environment: ["GRAPHCODE_PLATFORM_TEST": "platform-ok"]))

    XCTAssertEqual(result.exitCode, 0)
    let output = String(decoding: result.standardOutput, as: UTF8.self)
    XCTAssertTrue(output.contains("platform-ok"))
    XCTAssertTrue(output.localizedCaseInsensitiveContains(directory.lastPathComponent))
  }

  func testProcessRunnerExecutesCmdAndPowerShellScripts() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-scripts-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let commandScript = directory.appendingPathComponent("echo args.cmd")
    try "@echo off\r\necho CMD_OK:%~1\r\n".write(
      to: commandScript,
      atomically: true,
      encoding: .utf8)
    let powerShellScript = directory.appendingPathComponent("echo args.ps1")
    try #"param([string]$Value) Write-Output "PS_OK:$Value""#.write(
      to: powerShellScript,
      atomically: true,
      encoding: .utf8)

    let strategy = WindowsShellStrategy(
      commandPrompt: URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"]
          ?? ProcessInfo.processInfo.environment["COMSPEC"]
          ?? "cmd.exe"))
    let runner = FoundationProcessRunner()

    let command = try strategy.invocation(
      executable: commandScript,
      arguments: ["space value"],
      workingDirectory: directory,
      environment: [:])
    let commandResult: ProcessResult
    do {
      commandResult = try await runner.run(command.request)
    } catch {
      XCTFail("cmd launch failed: \(error)")
      return
    }
    XCTAssertEqual(commandResult.exitCode, 0)
    XCTAssertTrue(
      String(decoding: commandResult.standardOutput, as: UTF8.self).contains("CMD_OK:space value"))

    let powerShell = try strategy.invocation(
      executable: powerShellScript,
      arguments: ["-Value", "space value"],
      workingDirectory: directory,
      environment: [:])
    let powerShellResult: ProcessResult
    do {
      powerShellResult = try await runner.run(powerShell.request)
    } catch {
      XCTFail("PowerShell launch failed: \(error)")
      return
    }
    XCTAssertEqual(powerShellResult.exitCode, 0)
    XCTAssertTrue(
      String(decoding: powerShellResult.standardOutput, as: UTF8.self)
        .contains("PS_OK:space value"))
  }

  func testProcessRunnerTimesOutAndCancels() async {
    let powerShell = URL(
      fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
    let runner = FoundationProcessRunner()

    do {
      _ = try await runner.run(
        ProcessRequest(
          executable: powerShell,
          arguments: ["-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 5"]),
        timeout: .milliseconds(50))
      XCTFail("Expected timeout")
    } catch let error as ProcessRunnerError {
      XCTAssertEqual(error, .timedOut)
    } catch {
      XCTFail("Unexpected error: \(error)")
    }
  }

  func testProcessRunnerCancellationIsExplicit() async throws {
    let powerShell = URL(
      fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
    let runner = FoundationProcessRunner()
    let task = Task {
      try await runner.run(
        ProcessRequest(
          executable: powerShell,
          arguments: ["-NoLogo", "-NoProfile", "-Command", "Start-Sleep -Seconds 5"]))
    }

    try await Task.sleep(for: .milliseconds(50))
    task.cancel()
    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch let error as ProcessRunnerError {
      XCTAssertEqual(error, .cancelled)
    }
  }

  func testProjectPersistenceUsesSafeWindowsKey() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(
      baseDirectory: directory,
      platformPaths: WindowsPlatformPaths())
    let project = ProjectRef(path: #"C:\Projects\GraphCode Demo"#, name: "Demo")
    let graph = LoopGraph(project: project, nodes: [LoopNode(title: "Worker")])

    persistence.saveGraph(graph)

    let files = try FileManager.default.contentsOfDirectory(
      at: directory.appendingPathComponent("projects", isDirectory: true),
      includingPropertiesForKeys: nil)
    XCTAssertEqual(files.count, 1)
    XCTAssertNotNil(
      files.first?.lastPathComponent.range(
        of: #"^v1-[0-9a-f]{64}\.json$"#,
        options: .regularExpression))
    XCTAssertEqual(persistence.loadGraph(path: project.path)?.project.path, project.path)
  }
}
