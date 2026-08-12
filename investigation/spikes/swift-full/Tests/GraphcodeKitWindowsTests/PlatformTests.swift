import Foundation
import XCTest

@testable import GraphcodeKit

#if canImport(Darwin)
  import Darwin
#endif
#if os(Windows)
  import WinSDK
#endif

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

  func testCanonicalProjectPathRejectsCanonicalizedDriveShareAndRootRelativePaths() {
    let paths = WindowsPlatformPaths()
    for path in [
      #"C:\"#,
      #"C:\Projects\.."#,
      #"\\server\share"#,
      #"\\server\share\folder\.."#,
      #"\path"#,
      #"/path"#,
      #"C:relative"#,
    ] {
      XCTAssertThrowsError(try paths.canonicalProjectPath(path), path)
    }
  }

  func testDarwinCanonicalProjectPathRejectsSymlinkToFilesystemRoot() throws {
    #if canImport(Darwin)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "graphcode-darwin-root-link-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let link = directory.appendingPathComponent("root-link", isDirectory: true)
      try FileManager.default.createSymbolicLink(
        atPath: link.path,
        withDestinationPath: "/")

      XCTAssertThrowsError(try DarwinPlatformPaths().canonicalProjectPath(link.path)) { error in
        XCTAssertEqual(error as? PlatformPathError, .rootPath(link.path))
      }
    #else
      throw XCTSkip("Darwin symlink-root assertion")
    #endif
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
    XCTAssertEqual(invocation.request.arguments.count, 5)
    XCTAssertEqual(Array(invocation.request.arguments.prefix(4)), ["/d", "/q", "/s", "/c"])
    let command = invocation.request.arguments[4]
    XCTAssertNil(invocation.request.standardInput)
    XCTAssertTrue(command.contains(script.path))
    XCTAssertTrue(command.contains("space value"))
    XCTAssertTrue(command.contains(#"quote^"value"#))
  }

  func testWindowsShellFallsBackToSystemPowerShell() {
    let systemRoot =
      ProcessInfo.processInfo.environment["SystemRoot"]
      ?? ProcessInfo.processInfo.environment["WINDIR"]
      ?? #"C:\Windows"#
    let strategy = WindowsShellStrategy(
      environment: [
        "ProgramW6432": #"C:\GraphCode\missing-program-files"#,
        "PATH": #"C:\GraphCode\missing-bin"#,
        "SystemRoot": systemRoot,
      ])

    let normalizedPath = strategy.powerShell.path.replacingOccurrences(of: "/", with: "\\")
    XCTAssertTrue(
      normalizedPath.localizedCaseInsensitiveContains(
        #"WindowsPowerShell\v1.0\powershell.exe"#))
  }

  func testWindowsShellEscapesHostileCmdArguments() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-hostile-cmd-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let script = directory.appendingPathComponent("echo-hostile.cmd")
    try "@echo off\r\necho ARG:%~1\r\n".write(to: script, atomically: true, encoding: .utf8)
    let strategy = WindowsShellStrategy(
      commandPrompt: URL(
        fileURLWithPath: ProcessInfo.processInfo.environment["ComSpec"]
          ?? ProcessInfo.processInfo.environment["COMSPEC"]
          ?? "cmd.exe"))
    for argument in ["a&b", "a|b", "a<d>", "a(e)", "a^b", "a!b", "a%b"] {
      let invocation = try strategy.invocation(
        executable: script,
        arguments: [argument],
        workingDirectory: directory,
        environment: [:])

      let result = try await FoundationProcessRunner().run(invocation.request)
      let output = String(decoding: result.standardOutput, as: UTF8.self)
      XCTAssertEqual(
        result.exitCode,
        0,
        "\(argument): stdout=\(output) "
          + "stderr=\(String(decoding: result.standardError, as: UTF8.self))")
      XCTAssertEqual(
        output,
        "ARG:\(argument)\r\n",
        "\(argument): args=\(invocation.request.arguments) stdout=\(output)")
    }
  }

  func testWindowsShellRejectsLineBreakInjection() {
    let strategy = WindowsShellStrategy()
    let script = URL(fileURLWithPath: #"C:\Tools\echo.cmd"#)

    XCTAssertThrowsError(
      try strategy.invocation(
        executable: script,
        arguments: ["safe\r\necho injected"],
        workingDirectory: nil,
        environment: [:])
    ) { error in
      XCTAssertEqual(error as? ShellStrategyError, .commandContainsLineBreak)
    }
    XCTAssertThrowsError(
      try strategy.invocation(
        executable: URL(fileURLWithPath: "C:\\Tools\\echo\r\n.cmd"),
        arguments: [],
        workingDirectory: nil,
        environment: [:])
    ) { error in
      XCTAssertEqual(error as? ShellStrategyError, .commandContainsLineBreak)
    }
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

  func testProcessRunnerPreservesWindowsArgvZeroForDirectExecutable() async throws {
    #if os(Windows)
      let powerShell = URL(
        fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
      let result = try await FoundationProcessRunner().run(
        ProcessRequest(
          executable: powerShell,
          arguments: [
            "-NoLogo",
            "-NoProfile",
            "-Command",
            "[Environment]::GetCommandLineArgs()[0]",
          ]))

      XCTAssertEqual(result.exitCode, 0)
      XCTAssertEqual(
        String(decoding: result.standardOutput, as: UTF8.self)
          .trimmingCharacters(in: .whitespacesAndNewlines)
          .replacingOccurrences(of: "/", with: "\\"),
        powerShell.path.replacingOccurrences(of: "/", with: "\\"))
    #else
      throw XCTSkip("Windows argv[0] assertion")
    #endif
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
    XCTAssertEqual(
      commandResult.standardOutput,
      Data("CMD_OK:space value\r\n".utf8))
    XCTAssertEqual(commandResult.standardError, Data())

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

  func testProcessRunnerCancellationBeforeLaunchResumesAndDoesNotLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-cancel-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched.txt")
    let gate = LaunchGate()
    let runner = FoundationProcessRunner(beforeStart: { await gate.wait() })
    let comSpec =
      ProcessInfo.processInfo.environment["ComSpec"]
      ?? ProcessInfo.processInfo.environment["COMSPEC"]
      ?? "cmd.exe"

    let task = Task {
      try await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: comSpec),
          arguments: ["/d", "/c", "echo launched > \"\(marker.path)\""]))
    }
    await gate.waitUntilEntered()
    task.cancel()
    await gate.release()

    do {
      _ = try await task.value
      XCTFail("Expected cancellation")
    } catch let error as ProcessRunnerError {
      XCTAssertEqual(error, .cancelled)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testProcessRunnerTimeoutBeforeLaunchResumesAndDoesNotLaunch() async throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-timeout-race-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let marker = directory.appendingPathComponent("launched.txt")
    let gate = LaunchGate()
    let runner = FoundationProcessRunner(beforeStart: { await gate.wait() })
    let comSpec =
      ProcessInfo.processInfo.environment["ComSpec"]
      ?? ProcessInfo.processInfo.environment["COMSPEC"]
      ?? "cmd.exe"

    let task = Task {
      try await runner.run(
        ProcessRequest(
          executable: URL(fileURLWithPath: comSpec),
          arguments: ["/d", "/c", "echo launched > \"\(marker.path)\""]),
        timeout: .milliseconds(1))
    }
    await gate.waitUntilEntered()
    try await Task.sleep(for: .milliseconds(100))
    await gate.release()

    do {
      _ = try await task.value
      XCTFail("Expected timeout")
    } catch let error as ProcessRunnerError {
      XCTAssertEqual(error, .timedOut)
    }
    XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
  }

  func testProcessRunnerTimeoutKillsChildProcessAndDrainsPipes() async throws {
    try await assertProcessTreeTermination(.timeout)
  }

  func testProcessRunnerCancellationKillsChildProcessAndDrainsPipes() async throws {
    try await assertProcessTreeTermination(.cancellation)
  }

  func testConcurrentWindowsLaunchesDoNotCrossInheritPipeHandles() async throws {
    #if os(Windows)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "graphcode-handle-race-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }

      let comSpec =
        ProcessInfo.processInfo.environment["ComSpec"]
        ?? ProcessInfo.processInfo.environment["COMSPEC"]
        ?? "cmd.exe"

      for iteration in 0..<16 {
        let iterationDirectory = directory.appendingPathComponent(
          "iteration-\(iteration)", isDirectory: true)
        try FileManager.default.createDirectory(
          at: iterationDirectory, withIntermediateDirectories: true)
        let longMarker = iterationDirectory.appendingPathComponent("long.started")
        let shortMarker = iterationDirectory.appendingPathComponent("short.started")
        let longScript =
          "echo started>\"\(longMarker.path)\" & ping -n 30 127.0.0.1 > nul"
        let shortScript =
          "echo started>\"\(shortMarker.path)\" & ping -n 30 127.0.0.1 > nul"
        let longCompletion = ProcessCompletionBox()
        let shortCompletion = ProcessCompletionBox()

        let barrier = LaunchBarrier(count: 2)
        let synchronizedRunner = FoundationProcessRunner(beforeStart: {
          await barrier.wait()
        })
        let longTask = Task {
          do {
            let result = try await synchronizedRunner.run(
              ProcessRequest(
                executable: URL(fileURLWithPath: comSpec),
                arguments: ["/d", "/c", longScript]))
            await longCompletion.finish(.succeeded(result))
          } catch let error as ProcessRunnerError {
            await longCompletion.finish(.failed(error))
          } catch {
            await longCompletion.finish(.unexpected(String(describing: error)))
          }
        }
        let shortTask = Task {
          do {
            let result = try await synchronizedRunner.run(
              ProcessRequest(
                executable: URL(fileURLWithPath: comSpec),
                arguments: ["/d", "/c", shortScript]))
            await shortCompletion.finish(.succeeded(result))
          } catch let error as ProcessRunnerError {
            await shortCompletion.finish(.failed(error))
          } catch {
            await shortCompletion.finish(.unexpected(String(describing: error)))
          }
        }

        var markersPublished = false
        for _ in 0..<200 {
          if FileManager.default.fileExists(atPath: longMarker.path),
            FileManager.default.fileExists(atPath: shortMarker.path)
          {
            markersPublished = true
            break
          }
          try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(markersPublished, "Both concurrent processes must start")

        shortTask.cancel()
        var shortState: ProcessCompletionState?
        for _ in 0..<200 {
          shortState = await shortCompletion.current()
          if shortState != nil { break }
          try await Task.sleep(for: .milliseconds(10))
        }

        XCTAssertEqual(shortState, .failed(.cancelled))
        let longState = await longCompletion.current()
        XCTAssertNil(longState)
        let shortFinalState = await shortCompletion.current()
        XCTAssertEqual(
          shortFinalState,
          .failed(.cancelled),
          "The cancelled process must finish its pipe readers while its sibling remains alive")

        longTask.cancel()
        _ = await shortTask.value
        _ = await longTask.value
      }
    #else
      throw XCTSkip("Windows handle-inheritance assertion")
    #endif
  }

  private enum TreeTermination: Equatable {
    case timeout
    case cancellation
  }

  private func assertProcessTreeTermination(_ termination: TreeTermination) async throws {
    #if os(Windows)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-tree-timeout-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let pidFile = directory.appendingPathComponent("child.pid")
      let powerShell = URL(
        fileURLWithPath: #"C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe"#)
      let script =
        #"$child = Start-Process -FilePath $env:ComSpec -ArgumentList '/d','/c','ping.exe -t 127.0.0.1 > nul' -PassThru; Set-Content -LiteralPath '$PID_FILE' -Value $child.Id -NoNewline; Start-Sleep -Seconds 30"#
        .replacingOccurrences(
          of: "$PID_FILE", with: pidFile.path.replacingOccurrences(of: "'", with: "''"))
      let task = Task {
        try await FoundationProcessRunner().run(
          ProcessRequest(
            executable: powerShell,
            arguments: ["-NoLogo", "-NoProfile", "-Command", script]),
          timeout: termination == .timeout ? .seconds(15) : nil)
      }

      var childPID: DWORD?
      for _ in 0..<400 {
        if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
          let parsed = UInt32(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          childPID = DWORD(parsed)
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard let childPID else {
        XCTFail("The child process did not publish its PID")
        _ = try? await task.value
        return
      }

      if termination == .cancellation {
        task.cancel()
      }
      do {
        _ = try await task.value
        XCTFail("Expected \(termination)")
      } catch let error as ProcessRunnerError {
        XCTAssertEqual(
          error,
          termination == .timeout ? .timedOut : .cancelled)
      }

      var childExited = false
      for _ in 0..<40 {
        let handle = OpenProcess(
          DWORD(PROCESS_QUERY_LIMITED_INFORMATION), false, childPID)
        if let handle {
          _ = CloseHandle(handle)
          try await Task.sleep(for: .milliseconds(25))
        } else {
          childExited = true
          break
        }
      }
      XCTAssertTrue(childExited)
    #else
      throw XCTSkip("Windows process-tree assertion")
    #endif
  }

  func testDarwinProcessGroupKillsDescendants() async throws {
    #if canImport(Darwin)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("graphcode-darwin-tree-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let pidFile = directory.appendingPathComponent("child.pid")
      let escapedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
      let script = "sleep 30 & child=$!; printf '%s' \"$child\" > '\(escapedPIDFile)'; wait"
      let task = Task {
        try await FoundationProcessRunner().run(
          ProcessRequest(
            executable: URL(fileURLWithPath: "/bin/sh"),
            arguments: ["-c", script]),
          timeout: .seconds(2))
      }

      var childPID: pid_t?
      for _ in 0..<200 {
        if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
          let parsed = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          childPID = parsed
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      guard let childPID else {
        XCTFail("The Darwin child process did not publish its PID")
        _ = try? await task.value
        return
      }

      do {
        _ = try await task.value
        XCTFail("Expected timeout")
      } catch let error as ProcessRunnerError {
        XCTAssertEqual(error, .timedOut)
      }

      var childExited = false
      for _ in 0..<100 {
        if kill(childPID, 0) == -1 {
          childExited = true
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(childExited)
    #else
      throw XCTSkip("Darwin process-group assertion")
    #endif
  }

  func testDarwinProcessGroupKillsBackgroundDescendantAfterSuccessfulRootExit() async throws {
    #if canImport(Darwin)
      let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent(
          "graphcode-darwin-success-tree-\(UUID().uuidString)", isDirectory: true)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      defer { try? FileManager.default.removeItem(at: directory) }
      let pidFile = directory.appendingPathComponent("child.pid")
      let escapedPIDFile = pidFile.path.replacingOccurrences(of: "'", with: "'\\''")
      let script =
        "sleep 30 & child=$!; printf '%s' \"$child\" > '\(escapedPIDFile)'; exit 0"
      let completion = ProcessCompletionBox()
      let task = Task {
        do {
          let result = try await FoundationProcessRunner().run(
            ProcessRequest(
              executable: URL(fileURLWithPath: "/bin/sh"),
              arguments: ["-c", script]))
          await completion.finish(.succeeded(result))
        } catch let error as ProcessRunnerError {
          await completion.finish(.failed(error))
        } catch {
          await completion.finish(.unexpected(String(describing: error)))
        }
      }

      var childPID: pid_t?
      for _ in 0..<200 {
        if let contents = try? String(contentsOf: pidFile, encoding: .utf8),
          let parsed = pid_t(contents.trimmingCharacters(in: .whitespacesAndNewlines))
        {
          childPID = parsed
          break
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      guard let childPID else {
        XCTFail("The successful Darwin child did not publish its PID")
        _ = await task.value
        return
      }

      var state: ProcessCompletionState?
      for _ in 0..<200 {
        state = await completion.current()
        if state != nil { break }
        try await Task.sleep(for: .milliseconds(10))
      }
      XCTAssertNotNil(
        state,
        "A successful root exit must release after cleaning up its process group")
      if state == nil {
        _ = kill(childPID, SIGKILL)
      }
      _ = await task.value

      let finalState = await completion.current()
      guard case .succeeded(let result) = finalState else {
        XCTFail("Expected successful root completion, got \(String(describing: finalState))")
        return
      }
      XCTAssertEqual(result.exitCode, 0)

      var childExited = false
      for _ in 0..<100 {
        if kill(childPID, 0) == -1 {
          childExited = true
          break
        }
        try await Task.sleep(for: .milliseconds(25))
      }
      XCTAssertTrue(childExited)
    #else
      throw XCTSkip("Darwin successful-root process-group assertion")
    #endif
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

  func testProjectPersistenceMigratesAndDeletesLegacyPathFile() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent(
        "graphcode-legacy-persistence-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(
      baseDirectory: directory,
      platformPaths: DarwinPlatformPaths())
    let project = ProjectRef(path: "/tmp/legacy-windows-test", name: "Legacy")
    let graph = LoopGraph(project: project, nodes: [LoopNode(title: "Legacy")])
    let legacyURL =
      directory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("_tmp_legacy-windows-test.json")
    try JSONEncoder()
      .encode(graph)
      .write(to: legacyURL)

    XCTAssertEqual(persistence.loadGraph(path: project.path)?.nodes.first?.title, "Legacy")
    XCTAssertFalse(FileManager.default.fileExists(atPath: legacyURL.path))

    persistence.deleteGraph(path: project.path)
    XCTAssertNil(persistence.loadGraph(path: project.path))
  }

  func testProjectPersistenceLeavesCollidingLegacyFileForAnotherGraph() throws {
    let directory = FileManager.default.temporaryDirectory
      .appendingPathComponent("graphcode-legacy-collision-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let persistence = ProjectPersistence(
      baseDirectory: directory,
      platformPaths: DarwinPlatformPaths())
    let requestedPath = "/tmp/a/b_c"
    let otherPath = "/tmp/a_b/c"
    let legacyURL =
      directory
      .appendingPathComponent("projects", isDirectory: true)
      .appendingPathComponent("_tmp_a_b_c.json")
    let otherGraph = LoopGraph(project: ProjectRef(path: otherPath, name: "Other"))
    try JSONEncoder().encode(otherGraph).write(to: legacyURL)

    XCTAssertNil(persistence.loadGraph(path: requestedPath))
    persistence.deleteGraph(path: requestedPath)
    XCTAssertTrue(FileManager.default.fileExists(atPath: legacyURL.path))
  }
}
private actor LaunchGate {
  private var entered = false
  private var entryContinuation: CheckedContinuation<Void, Never>?
  private var releaseContinuation: CheckedContinuation<Void, Never>?

  func wait() async {
    entered = true
    entryContinuation?.resume()
    entryContinuation = nil
    await withCheckedContinuation { continuation in
      releaseContinuation = continuation
    }
  }

  func waitUntilEntered() async {
    if entered { return }
    await withCheckedContinuation { continuation in
      entryContinuation = continuation
    }
  }

  func release() {
    releaseContinuation?.resume()
    releaseContinuation = nil
  }
}

private actor LaunchBarrier {
  private let expected: Int
  private var arrivals = 0
  private var continuations: [CheckedContinuation<Void, Never>] = []

  init(count: Int) {
    expected = count
  }

  func wait() async {
    arrivals += 1
    guard arrivals < expected else {
      let continuations = self.continuations
      self.continuations.removeAll()
      for continuation in continuations {
        continuation.resume()
      }
      return
    }
    await withCheckedContinuation { continuation in
      continuations.append(continuation)
    }
  }
}

private enum ProcessCompletionState: Equatable, Sendable {
  case succeeded(ProcessResult)
  case failed(ProcessRunnerError)
  case unexpected(String)
}

private actor ProcessCompletionBox {
  private var state: ProcessCompletionState?

  func finish(_ state: ProcessCompletionState) {
    self.state = state
  }

  func current() -> ProcessCompletionState? {
    state
  }
}
