# Compiled ownership contracts

`OwnedChildSupervisor.RunAsync(ProcessStartInfo, TimeSpan, string,
CancellationToken)` is the shared child executor. `ArgumentList` is mandatory;
the executable must be an existing absolute path. The artifact directory must
already exist. The supervisor creates a suspended root with an explicit standard
handle list, assigns the held root to a non-breakaway job, verifies membership,
starts independent readers, and only then resumes execution.

The original monotonic deadline covers launch, root exit and both readers.
Teardown has one separate five-second budget shared by the root, job and both
readers. `StopAsync` supports early controlled teardown. A failed cleanup tags
the original exception, writes a create-new bounded receipt, and retains the
lease rather than releasing an unproved kill-on-close job or reader. Neither
CIM observations nor reopening a PID supplies termination authority.

`StandaloneProcessJob` is the complete native job implementation, including
membership, accounting, bounded census and packaging diagnostics.
`UiaOwnedStreamCapture` uses it for native membership. Both must be linked by
the host-owned packaging and UIA adapters; merely compiling these files does
not establish that integration. Streaming uses `AutoFlush`, which flushes bytes
without prematurely flushing an encoder containing half a surrogate pair.

`OwnedFixture.TryRunAsync(args)` must run before ordinary host argument parsing.
It recognizes only `--ownership-fixture`. The compiled fixture tests native
root/job/descendant/stream behavior, real fragmented named pipes, and exact
argv/empty-versus-absent environment/Unicode/cwd. These are controlled fixtures,
not evidence of an actual GraphCode product walkthrough.

## Coverage correspondence

The source oracle is the immutable Cards export with manifest SHA-256
`CC8ED5141AE38CB425F4E41AB7F2E4EF1F07F5AE4CAD7FA969A68645B07A0A2F`
and root-runner SHA-256
`202D260A846670E314163F9D2565D07B1E0AD27A4D61F41EA99D67624FF6C869`.
The old runner is never executed, embedded or extracted for execution.

The 59 managed and seven controlled-native cases are individually registered
with exact-count manifest guards. The typed peer implements the complete
request/response/publication/control core from `Stub-Daemon.ps1:29-294`; it is
the implementation used by the compiled real-pipe fixture, not a passing fake.
Its presence does not claim that the old PowerShell stub has been rewired.

Twelve separate mandatory units retain the original seven ownership/mixed root
families, three mixed source-boundary assertions, and two shared-production
linkage obligations. Until explicit host-owned PowerShell integration adapters
preserve the actual scope, ScriptMethod, ErrorRecord identity, streams and
mocking assertions, those units report `Incomplete`, never a synthetic pass.
The six-case retention boundary and mixed eight-mode capture/cleanup negative
controls remain mandatory. Source occurrences of `Assert-MultiCase` and
`Invoke-MultiCase` are not runtime counts.
