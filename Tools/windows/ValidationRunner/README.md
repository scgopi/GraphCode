# Compiled Windows validation runner

The canonical validation contract is a normal C# console program, not
`Tests\ValidationRunner.Tests.ps1`. The old monolith is never an executable
payload of this runner.

## Build and run

Use the repository Windows bootstrap and its process-local environment first.
The SDK is pinned by this directory's `global.json`. SDK selection depends on
the command's working directory, not on the project path:

```powershell
Push-Location Tools\windows\ValidationRunner
try {
  if ((dotnet --version) -cne "10.0.403") { throw "Pinned SDK 10.0.403 is required" }
  dotnet build -c Release
  if ($LASTEXITCODE -ne 0) { throw "Compiled validation build failed" }
} finally { Pop-Location }

& .\Tools\windows\ValidationRunner\bin\Release\net10.0-windows\ValidationRunner.exe `
  --repository-root $PWD.Path --artifact-root .ci-validation-runner
if ($LASTEXITCODE -ne 0) { throw "Compiled validation was not complete" }
```

The host requires .NET 10 and Windows Desktop runtime support. Shared production
bindings target `net8.0-windows`; ordinary PowerShell production consumers use
the same file-backed assembly on PowerShell 7.4 or newer. Exclusive-directory
and controlled test fixtures have separate `netstandard2.1` assemblies. Fakes
are not compiled into the production binding library.

`Build-CompiledValidationRunner.ps1` is a convenience for PowerShell consumers.
CI builds the project and runs the normal executable directly.

## Proof and diagnostic modes

A successful full invocation exits zero, writes `coverage.json`, and emits
exactly one each of:

```text
CompiledValidationRunner: PASS
VALIDATION_RUNNER_EXECUTED=1
```

Consumers must also require `complete=true`, `fullInvocation=true`, a positive `requiredCount`, and
`passedCount == requiredCount`. Exit zero alone is insufficient:
`--self-test` and the explicitly controlled fixture modes are not full runs.

Repeat `--suite exact.suite.id` to run a bounded set in one process. Mandatory
unselected units remain incomplete, and a selected invocation cannot emit full
success markers even if it happened to select every unit. These reports are useful for debugging,
but a union of separate reports is not a full invocation.

The three required manifests are read from the current repository, independently
of executor registration. Missing, duplicate, unknown, skipped, unimplemented,
empty, or insufficient-count units cannot produce a complete report. A suite
may return evidence only for its own declared IDs.

The mixed-family composite checks all 126 original source templates against
their independently declared dependencies and exact expanded counts. It derives
proof only from validated results of the current invocation. Its derived
465-case proof is **not** counted again in `actualExecutedCount`;
`derivedProofCount` reports derived proofs separately.

## Production and process boundaries

Production C# files are linked into `WindowsValidationBindings.csproj` once.
UIA, packaging contracts, shell ownership, and managed/native tests consume those
same implementations. The loader verifies the exact file/type, worktree,
current source and compiler-reference fingerprints, and loaded module identity.
After changing a compiled input, rebuild; do not reuse an old loaded type.

Named PowerShell adapters retain actual PowerShell scope, mocks, environment
presence, ErrorRecord identity, streams, and exit-code behavior. They do not
extract or execute old monolith functions. Child output is retained in owned
artifacts; root console summaries do not forward arbitrary child text.
The capture suite alone admits its exact path-bound, deliberately injected
negative-control diagnostics, while still requiring all 182 cases and the
14 named groups.

Each host-supervised child starts suspended in a held, non-breakaway job before it can execute.
Original monotonic deadlines, independent stream EOF, primary errors, live
retention signals, and original authority govern cleanup. Raw protocol bytes
are preserved before strict decoding. An actual UNKNOWN ownership result
retains the original resources and prevents host exit, including when reporting
fails. It is not a reason to close a job or terminate an inferred PID.

Native rendezvous fixtures use exclusive short scratch directories on the
repository's volume. Receipts point to retained scratch and stream evidence;
the long worktree or report path is not substituted for the native path budget.
