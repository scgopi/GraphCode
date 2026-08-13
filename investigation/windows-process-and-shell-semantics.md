# Windows process and shell semantics

## Spike result

`investigation/spikes/swift-process` uses Swift Foundation `Process` on Windows 11.

Observed:

```text
direct.arguments=["space value", "quote\"value", "雪"]
direct.environment=inherited
swift-process direct-exe-argv-cwd-environment: ok
swift-process direct-cmd-launches=true
swift-process direct-ps1-launches=false
swift-process cmd-hosted-shim: ok
swift-process powershell-hosted-shim: ok
```

Conclusions:

- `Process` is sufficient for direct `.exe` launches with argv, Unicode, cwd, and environment.
- On this toolchain, `.cmd` launches directly and preserves a spaced argument, but GraphCode should still classify executable extensions explicitly rather than rely on undocumented dispatch behavior.
- `.ps1` does not launch directly. It needs `powershell.exe` or `pwsh.exe`.
- POSIX shell strings and quoting must not be translated mechanically to Windows.

## Proposed launch policy

| Input | Windows launch |
|---|---|
| `.exe`, extensionless native executable | Direct suspended `CreateProcessW` launch, assigned to a Job Object before resume; `STARTUPINFOEXW` restricts inheritance to the three stdio handles |
| `.cmd`, `.bat` | Noninteractive `cmd.exe /d /q /s /c` with a parser-escaped command argument; no stdin banner or prompt |
| `.ps1` | Prefer `pwsh.exe -NoLogo -NoProfile -File`; optionally fall back to Windows PowerShell |
| npm shim | Resolve the actual `.cmd`/`.ps1`/`.exe` and apply the matching rule |
| shell predicate | Explicit configured shell; PowerShell should be the native default |
| remote command | Local `ssh.exe` argv plus an explicitly POSIX-quoted remote command |
| WSL command | Explicit `wsl.exe -- <argv>` mode, never implicit path conversion |

Every Windows `CreateProcessW` command line begins with the quoted, backslash-normalized
executable path as `argv[0]`, including when `lpApplicationName` is supplied. This preserves
native executable argument conventions while keeping the noninteractive `cmd.exe` transport
compatible with paths containing spaces.

## Required tests

- executable and working-directory paths with spaces
- quotes, backslashes, empty arguments, Unicode, and trailing backslashes
- `.exe`, `.cmd`, `.bat`, `.ps1`, npm shims
- `pwsh.exe`, Windows PowerShell, `cmd.exe`, and optional WSL
- environment removal/addition without mutating the parent process
- cancellation and process-tree termination
- stdout/stderr draining without deadlock
- timeout and ambiguous completion behavior
- native process-group/job containment before the child can spawn descendants
- Windows successful-root cleanup terminates and closes the Job Object before pipe draining
- Darwin successful-root cleanup terminates background group members before releasing pipes
- Windows junction/symlink final targets are resolved before filesystem-root rejection; extended
  UNC prefixes and trailing dot/separator variants are normalized even when resolution fails
- concurrent Windows launches do not cross-inherit pipe handles

## Source consequences

- Replace `ZmxSessionLauncher.loginShellInvocation` with platform command builders.
- Replace hard-coded `/bin/zsh` in `ShellPredicateEvaluator`.
- Split POSIX hook generation in `PresenceHooks` from lifecycle policy.
- Resolve `ssh` from PATH/System32 rather than `/usr/bin/ssh`.
- Preserve direct argv whenever possible; use shell text only when shell evaluation is the feature.
