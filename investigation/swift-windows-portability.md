# Swift Windows portability audit

Tested on Windows 11 with Swift 6.3.3 (`x86_64-unknown-windows-msvc`).

## Result

- `GraphcodeKit` contains 62 Swift files.
- 39 files (62.9%) are assessed as portable unchanged.
- 17 files (27.4%) retain shared behavior but need a platform/path/process/transport abstraction.
- 6 files (9.7%) are platform implementations and need Windows counterparts.
- No third-party Swift dependency blocker was found. `IdentifiedCollections` 1.1.1 and its `swift-collections` dependency built on Windows.
- A compiler-tested 31-file domain subset built and passed JSON/settings tests. This is 91.2% of `Domain/`; the three excluded files are cross-layer or path/shell coupled.
- The full package reached GraphCode sources and stopped at the unconditional `import Darwin` in `PTYProcessSession.swift`.

Categories:

- **A**: portable unchanged.
- **B**: shared behavior, portable after a small explicit abstraction or path correction.
- **C**: platform implementation; retain a Darwin version and add a Windows version.

## File inventory

| File | Category | Evidence / required change |
|---|---:|---|
| `CLI/GraphcodeCommand.swift` | A | Pure parsing/rendering over domain and daemon protocol values. |
| `DaemonBootstrap.swift` | C | launchd plist, `launchctl`, quarantine xattr, app-bundle helper layout. Add a per-user Windows startup/install host. |
| `Domain/AttentionRollup.swift` | A | Pure value derivation. |
| `Domain/BackendCapabilities.swift` | A | Pure capability values. |
| `Domain/BackendCommand.swift` | B | Domain layer calls `PresenceHooks.codexNotifyOverride`; separate OS-neutral backend policy from shell-specific hook arguments. |
| `Domain/CLISessionBackendKind.swift` | A | Pure enum/capabilities. |
| `Domain/CycleGuard.swift` | A | Codable value. |
| `Domain/EdgeCondition.swift` | A | Codable enum. |
| `Domain/EdgeKind.swift` | A | Codable enum. |
| `Domain/EdgeSpec.swift` | A | Codable value. |
| `Domain/GoalSpec.swift` | A | Codable value. |
| `Domain/GraphcodeSettings.swift` | A | Codable settings; Windows-specific defaults can be injected outside the type. |
| `Domain/LoopEdge.swift` | A | Codable value. |
| `Domain/LoopGraph.swift` | A | Built on Windows with `IdentifiedCollections`. |
| `Domain/LoopGraphScope.swift` | A | Pure scope/value logic. |
| `Domain/LoopNode.swift` | A | Built on Windows. |
| `Domain/LoopState.swift` | A | Codable state. |
| `Domain/LoopType.swift` | A | Codable enum and prompt composition. |
| `Domain/MetricSample.swift` | A | Pure value/trend logic. |
| `Domain/ModelTier.swift` | A | Codable enum. |
| `Domain/NodeDraft.swift` | A | Pure validation/value logic. |
| `Domain/NodeUpdate.swift` | A | Codable value. |
| `Domain/PayloadTransform.swift` | A | Codable enum. |
| `Domain/PilotState.swift` | A | Codable enum. |
| `Domain/Presence.swift` | A | Codable values. |
| `Domain/ProjectRef.swift` | A | Windows path strings round-trip unchanged. |
| `Domain/RemoteBootMarker.swift` | A | Pure marker parsing. |
| `Domain/RemoteProjectLocation.swift` | B | Remote path is intentionally POSIX, but local SSH executable/control-socket assumptions are macOS-specific. |
| `Domain/SafeArgument.swift` | A | Pure validation. |
| `Domain/SessionBriefing.swift` | B | Shared text, but fixed `~/.graphcode/bin/graphcode` and shell command examples need platform injection. |
| `Domain/ShellPredicate.swift` | A | Pure value. |
| `Domain/SSHReconnectLoop.swift` | B | Generates a `/bin/sh` retry loop; retain behavior behind a remote-shell strategy. |
| `Domain/TerminalLayout.swift` | A | Built on Windows with `IdentifiedCollections`. |
| `Domain/UsageSample.swift` | A | Codable value. |
| `Domain/WorktreeHygiene.swift` | A | Pure policy/value logic. |
| `Domain/WorktreeRef.swift` | A | Codable value. |
| `GraphStore.swift` | B | Orchestration is shared, but it stores raw `Int32` descriptors and calls `FramedMessageIO` directly. Store a send-capable connection instead. |
| `GraphcodeSettingsStore.swift` | A | Foundation JSON I/O is portable once `SupportDirectory` is corrected. |
| `IPC/DaemonProtocol.swift` | A | Codable command/event protocol is transport-independent. |
| `IPC/DaemonSocketClient.swift` | C | AF_UNIX, `sockaddr_un`, POSIX timeout and errno behavior. Add a Named Pipe client. |
| `IPC/DaemonSocketPath.swift` | B | Replace socket URL with a platform endpoint identity; retain support-dir/worktree isolation semantics. |
| `IPC/FramedMessageIO.swift` | B | Four-byte big-endian framing is reusable; raw POSIX `read`/`write` must become a byte-stream abstraction. |
| `ProjectPersistence.swift` | B | Replacing `/` only leaves `:` and `\` in Windows filenames. Use a stable hash plus optional readable suffix. |
| `ProjectRegistry.swift` | B | Rejects every drive-letter path via `hasPrefix("/")`; also owns raw descriptors. Use URL/path APIs and abstract connections. |
| `QuickChatStore.swift` | A | Foundation JSON I/O. |
| `Sessions/AgentEnvironment.swift` | B | `unsetenv` is not a portable public strategy. Build sanitized child environments and use a small Windows process-environment helper only where unavoidable. |
| `Sessions/CLISessionBackend.swift` | B | Shared facade, but defaults bind directly to `ZmxSessionLauncher` and shell/process implementations. Inject a session service. |
| `Sessions/CodexSessionLog.swift` | B | Foundation I/O is portable; `/` leaf parsing and zmx/process coupling need URL/platform helpers. |
| `Sessions/CopilotSessionLog.swift` | B | Foundation I/O is portable; `/` leaf parsing, Windows state locations, and zmx/process coupling need helpers. |
| `Sessions/MessageBus.swift` | A | Pure delivery policy and message construction. |
| `Sessions/NodeMemory.swift` | A | Foundation file I/O; default root follows corrected `SupportDirectory`. |
| `Sessions/PTYProcessSession.swift` | C | `Darwin`, `openpty`, `fcntl`, POSIX descriptors. Replace control-command use with a pipe-based process runner; interactive Windows PTY work belongs in zmx/ConPTY. |
| `Sessions/PresenceHooks.swift` | B | Shared lifecycle mapping, but generated hook bodies use `/bin/sh`, `sed`, `head`, shell quoting, and POSIX paths. Generate backend/OS-specific hook commands. |
| `Sessions/RemoteEnsureGate.swift` | A | Pure actor/lease logic. |
| `Sessions/RemoteGraphAccess.swift` | C | Embedded POSIX Python shim, AF_UNIX, chmod, shebangs, and Unix socket forwarding. Defer from native Windows v1 or add a separate Windows remote transport. |
| `Sessions/RemoteSocketForwarder.swift` | C | `/bin/sh`, `/usr/bin/ssh`, Unix remote socket forwarding, `kill -0`. |
| `Sessions/SessionIDStore.swift` | A | Foundation file I/O; default root follows corrected `SupportDirectory`. |
| `Sessions/ShellPredicateEvaluator.swift` | C | Hard-coded `/bin/zsh` and POSIX shell evaluation. Add a Windows predicate runner with an explicit shell policy. |
| `Sessions/ZmxLocator.swift` | B | Select `zmx.exe` and the Windows installation root. |
| `Sessions/ZmxSessionLauncher.swift` | B | Keep session/backend policy shared, but extract local process execution, shell invocation, quoting, path layout, hooks, and remote execution. |
| `SupportDirectory.swift` | B | Absolute Windows overrides are treated as relative (`C:\...` becomes `<home>/C:/...`). Define platform roots and use URL path classification. |
| `TerminalLayoutStore.swift` | A | Foundation JSON I/O. |

## Compiler and behavior evidence

### Portable domain

`investigation/spikes/swift-portable` compiles 31 domain files on Windows and tests:

- graph JSON round-trip with `C:\Projects\GraphCode Demo`
- settings JSON round-trip

Both tests pass.

### Current path behavior

`investigation/spikes/swift-paths` reproduces:

```text
registryAcceptsPath=false
supportOverrideResolved=<home>/D:/GraphCodeState
persistenceFileName=C:\Projects\GraphCode Demo.json
```

### Important correction to the original handoff

`PTYProcessSession` is not only an old interactive PTY path. `ZmxSessionLauncher`,
Copilot/Codex probes, remote probes, label reads, sends, kills, and presence queries use
it as a general subprocess runner. Windows therefore needs:

1. a pipe-based cross-platform `ProcessRunner` for non-interactive commands; and
2. ConPTY inside zmx for persistent interactive sessions.

Trying to make all those short-lived control commands use ConPTY would preserve an
accidental macOS implementation detail and add unnecessary complexity.

## Recommended first extraction

1. `DaemonConnection` with `send(Data)`, lifecycle, and stable identity.
2. `ByteStream` framing independent of POSIX descriptors/HANDLEs.
3. `ProcessRunner` for direct executable argv, cwd, environment, output, timeout, and cancellation.
4. `ShellStrategy` for zsh, `cmd.exe`, PowerShell, and remote POSIX shells.
5. `PlatformPaths` for support/bin/hooks/session/log locations and safe persistence keys.
6. `SessionService` separating shared zmx/backend policy from OS command construction.

`graphcoded` can remain Swift, but not “entirely shared except its socket main.” Its
orchestration can remain shared; transport host, startup, process/shell services, paths,
and remote forwarding require explicit platform implementations.

## Platform implementation baseline

The first production platform seam now lives in `GraphcodeKit/Sources/Platform`:

- `WindowsPlatformPaths` and `DarwinPlatformPaths` provide canonical local paths,
  support/bin/hooks/session roots, and versioned SHA-256 persistence keys.
- `FoundationProcessRunner` preserves direct argv, working directory, environment,
  standard input/output/error, timeout, and cancellation behavior without mutating the
  parent process.
- `WindowsShellStrategy` classifies native executables, `.cmd`/`.bat`, and `.ps1`
  launches without translating arguments through an incidental shell.

`investigation/spikes/swift-full` compiles these production sources and runs their Windows
tests. Use `pwsh Tools/windows/validate.ps1 -Task swift-production` for focused
validation; `-Task all` includes it.
