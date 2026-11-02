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
`UiaOwnedStreamCapture` uses it for native membership. Both are linked by
the host-owned packaging and UIA adapters; merely compiling these files does
not establish that integration. Streaming uses `AutoFlush`, which flushes bytes
without prematurely flushing an encoder containing half a surrogate pair.
The host must await `HoldRetainedResourcesAsync()` in its outermost `finally`.
Retained references alone do not suffice: process exit closes a kill-on-close
job even if the garbage collector never finalized anything.
Both independent readers watch the exact retention sentinel incrementally,
including split chunks, CRLF and terminal EOF. A live signal immediately roots
the original lease and cancels only the controller's wait, never the readers.
The cleanup coordinator refuses termination, proof waits and close on that
latch; native kill/close boundaries also recheck it under the same lock.
The host can therefore enter its terminal retention hold without waiting for
the workload timeout to kill the very resources it is required to preserve.
The supervisor's `OwnedByteStreamCapture` persists original pipe bytes before
strict decoding and never autodetects or consumes a BOM. Raw EOF is a separate
proof from successful text decoding: invalid UTF-8 is rejected only after the
raw reader has continued to EOF and retained every byte. The live sentinel
observer reads the raw ASCII line boundary independently, including after a
decoder error. `UiaOwnedStreamCapture` remains the distinct production
text-reader API; its re-encoded text logs are not original-byte evidence.

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

The 76 managed and eleven controlled-native cases are individually registered
with exact-count manifest guards. The typed peer implements the complete
request/response/publication/control core from `Stub-Daemon.ps1:29-294`; it is
the implementation used by the compiled real-pipe fixture, not a passing fake.
Its presence does not claim that the old PowerShell stub has been rewired.

Six focused protected PowerShell families now preserve 45 actual assertions:
receipt producer seven, capture ownership fourteen, tree four, provider four,
pre-UIA isolation ten, and end-to-end retention six. They use actual production
functions from the integrated repository, not the exported runner. The adapter
transport is the host's authoritative held-job supervisor. Scope, ScriptMethod,
ErrorRecord identity, information streams and missing-versus-empty environment
membership remain PowerShell assertions.

The full mixed family remains mandatory and `Incomplete`; it cannot be
replaced by the compiled helper tests.
`source-correspondence.json` records every one of
the immutable mixed source's 126 invocation templates and 192 assertion
commands, with stable source IDs and zero claimed execution. Those source
occurrences are not runtime counts. The mixed eight-mode capture/cleanup
negative controls remain required.

The three mixed source-boundary assertions now have actual protected
PowerShell source checks. Six newly reconciled startup/tree units also run:
thirteen complete helper-presence checks (source evidence), three bounded file
diagnostic cases, one retained report case, and the advisory PID-reuse
negative control. These eighteen checks are not a native product startup
walkthrough. The two actual gate-owned controlled-tree obligations now run
against the linked production gate, as do all eight original bounded-capture
modes, including inherited writers, original timeout classification, and
primary/cleanup-only persistence failures. Two separate source-and-loader
checks establish packaging/UIA linkage without executing the packaging suite
merely to obtain a type.

The original-byte regression was first reproduced by two valid-BOM children:
the old reader consumed UTF-8 BOM bytes and autodetected UTF-16. In-memory
malformed-byte/raw-EOF separation was then established before executing the
actual malformed child. The four controlled byte fixtures now assert exact
original log bytes, strict UTF-8 rejection, positive owned cleanup, and a
supplementary scalar straddling a 4096-byte read boundary.
