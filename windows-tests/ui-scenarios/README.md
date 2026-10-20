# Offline UI scenario contracts (G1)

These schemas and `Tools\windows\Test-UiScenario.ps1` validate **data**, not UI.
There are deliberately no real product scenarios or claim declarations here.
The functional tests create explicitly synthetic claims in disposable scratch.
A schema-only or empty scenario directory fails with `EmptySelection`.

## Issue-owned authority

Before new UI work starts, the issue owner/coordinator assigns stable IDs such
as `768-C3`, immutable acceptance statements, allowed proof classes, and state
applicability. Every claim records `success`, `empty`, `error`, `disabled`,
`persistence-after-relaunch`, and `keyboard` as required or not applicable,
with a reason. Scenario authors cannot rename, weaken, split away, or close
those claims. A changed meaning requires explicit supersession and a new ID.
This convention does not retroactively add states or obligations to previously
approved wave-2 work.

The caller supplies a frozen **external** authority snapshot and an independently
trusted SHA-256. There is no default PR-head registry. The coordinator must
compare the export against the issue-owned declaration and provide the expected
hash through a trusted channel; a future CI caller must not obtain both inputs
from the PR head. `claim-authority.schema.json` is an input format, not authority
created by adding a file to this directory.

The snapshot binds `repository`, `issueNumber`, `sourceUrl`, `sourceCommentId`,
`sourceUpdatedAt`, `sourceBodySha256`, and nonempty claims containing `id`,
`criterion`, `criterionSha256`, `proofClass`, and all six `states`. URLs identify
a comment on the same `scgopi/GraphCode` issue, and IDs have that issue's numeric
prefix. The validator checks criterion hashes and snapshot byte identity.
It does not fetch the comment, verify its body hash, authenticate GitHub roles,
or establish human approval. Changing applicability/revision invalidates the
old snapshot hash, but a caller who also changes the trusted hash changes the
trust input. There is no `approvedBy`, `reviewed`, or verdict field.

Digests are lowercase SHA-256 over exact UTF-8 bytes. Criterion digests use
the decoded string's UTF-8 bytes; document digests use the actual file bytes.
No newline normalization, BOM removal, or canonical JSON reserialization is
performed. Documents must be UTF-8 without a BOM.

| Proof class | Evidence boundary |
| --- | --- |
| `semantic-uia` | Future passing production UIA observations/actions can support the exact semantic component, not rendering or physical input. |
| `visual` | Local screenshot review against macOS is required; v1 rejects visual scenarios. |
| `input` | Requires explicit transport and end-state evidence; posted/injected keys are not physical input. V1 accepts component data only. |
| `mixed` | UIA/input components cannot close the whole claim without its visual, physical-input, or other required evidence. V1 accepts component data only. |

`complete-semantic` is only a declaration of complete **state coverage in data**
for a `semantic-uia` claim; every required state must have a case. `component`
may leave required states uncovered. Reports list uncovered states and non-UIA
proof obligations for mixed/input claims. The exact criterion, not a generic
class label, determines which external evidence is actually required.

## Scenario v1

Use one `issueNumber-Cn.json` file per claim directly under `ScenarioRoot`.
Only the three exact schema filenames at that root and the `fixtures` subtree
are excluded from scenario JSON discovery. Unexpected JSON is not ignored.
Optional `-ClaimId` values select exact IDs; unknown, duplicate, empty, missing,
or mislabeled selections fail. All discovered scenario documents are parsed
and schema/file-identity checked even when not selected; cross-document
authority, fixture, and coverage checks apply to selected claims.

A scenario contains only `schemaVersion`, `claimId`, `authoritySha256`,
`coverage`, `fixture` (`id`, `version`, `manifestSha256`), and nonempty `cases`.
It cannot repeat editable acceptance text, proof class, approval, or a verdict.
Each case contains a unique `id`, applicable `state`, `tier` (`uia` or
`interactive`), `preconditions`, ordered `steps`, `expected` end states,
`timeoutMs`, and `cleanup`.

- Preconditions declare `profile: owned-isolated`, `process: owned-production`,
  a named `readyRoot`, nonempty typed `initial` assertions, and `timeoutMs`.
  Readiness/healthy-root anchors must be an `owned-root` `Window`.
- Targets contain literal case-sensitive `automationId`, exact UIA
  `controlType`, `scope` (`owned-root` or `owned-modal`), and `matchCount: 1`.
  There is no wildcard, regex, index, Name fallback, or ancestor substitution.
  V1 accepts ASCII literal IDs (letters, digits, `_`, `.`, `:`, `-`).
- Operations are `invoke`, `toggle`, `select`, `focus` (target/deadline),
  `set-value` (also typed `value`), `wait-for` (typed `expected`/deadline),
  `relaunch` (`readyRoot`/deadline), or `send-keys`
  (target, `keys`, `transport`, deadline). Send-keys requires `interactive`,
  including `post-message`; `send-input` is also injected, not physical input.
  Keyboard cases require send-keys; persistence cases require relaunch.
- Assertions are exact `property` (`IsEnabled`, `IsSelected`,
  `HasKeyboardFocus` as booleans; `Name`, `Value` as strings), `pattern`
  (`Toggle` with `On`, `Off`, `Indeterminate`), or `absent` with a distinct
  positive `healthyRoot` anchor. Explicit empty Name/Value is valid; a missing
  value is not an empty-text observation.
- Cleanup requires `intent: owned-processes-and-fixture` and a deadline.
  No cleanup-disable field exists. This validates intent, not execution.

Every object rejects unknown fields. Types, enums, required arrays, duplicate
and case-confusable properties (recursively), and versions are strict. The
draft-07 schemas use only local definitions and are the structural source of
truth; PowerShell implements cross-document semantics, not a second schema.
No command/script, private gate message, coordinate, screenshot, image,
golden/pixel baseline, visual tier, or arbitrary setup path is accepted.

| Bound | V1 limit |
| --- | --- |
| UTF-8 JSON document / nesting | 1 MiB / depth 32 |
| Cases per scenario | 1-16 |
| Steps per case / assertions per assertion array | 1-128 / 1-128 |
| Ordinary step, wait, precondition deadline | 1-10000 ms |
| Relaunch readiness / cleanup deadline | 1-30000 ms / 1-15000 ms |
| Case budget / sum of scenario case budgets | 1-60000 ms / at most 180000 ms |

The case budget must cover precondition, all step, and cleanup deadlines.
Cleanup is included in case and scenario budgets, not omitted from the sum.
These are data bounds, not cancelable UIA/COM or wall-clock execution guarantees.

## Fixture v1

The only manifest location is `fixtures\id\manifest.json` under `ScenarioRoot`.
`fixture.schema.json` requires `schemaVersion: 1`, matching `fixtureId` and
positive `fixtureVersion`, and 1-128 `files` with relative `path` and `sha256`.
The scenario's manifest digest and every referenced data-file digest must match.
Fixture versions are identities, not a declaration that a future adapter
supports their execution.

File paths may use either slash separator; they are normalized for
case-insensitive Windows duplicate detection. Absolute, empty-segment,
traversal, device, alternate-stream, trailing-dot/space, invalid Windows
character, missing, directory-as-file, and reparse-point paths fail. No
reparse-point ancestor is accepted, including for authority or scenario paths.
Caller paths also reject UNC/device/alternate-stream syntax after normalization,
and mapped network drives before reading their contents.
The caller must supply owned, privacy-safe packaged data and keep it stable
during validation. Static path checks and hashes are not protection against a
concurrent hostile filesystem mutation, filesystem attestation, or proof that
data was ever installed in a production profile. The validator only reads;
it performs no fixture setup or mutation.

## Commands and results

Use PowerShell 7.5 or newer (built-in `Test-Json`, `System.Text.Json`, and
string-preserving `ConvertFrom-Json -DateKind String`; no packages installed).
For a future real, human-reviewed scenario set:

```powershell
pwsh -NoProfile -File Tools\windows\Test-UiScenario.ps1 `
  -ScenarioRoot windows-tests\ui-scenarios `
  -AuthorityPath C:\trusted-authority\818.json `
  -AuthoritySha256 $trustedHash -ClaimId 818-C1
```

`pwsh -File` supports a single claim argument here; it does not turn a
comma-separated native argument into an array. To select multiple claims,
invoke the script from PowerShell with an actual array:

```powershell
& .\Tools\windows\Test-UiScenario.ps1 `
  -ScenarioRoot windows-tests\ui-scenarios `
  -AuthorityPath C:\trusted-authority\818.json `
  -AuthoritySha256 $trustedHash -ClaimId @("818-C1", "818-C2")
```

This repository currently has **zero** real scenarios, so that production
discovery cannot pass. Do not use synthetic functional fixtures as UI evidence.
Run the offline contracts instead:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiScenario.Tests.ps1
pwsh -NoProfile -File Tools\windows\Tests\ValidationRunner.Tests.ps1
bash Tools/ci/tests/classify-changes.test.sh
pwsh -NoProfile -File Tools\tdd\Tests\TddEvidence.Tests.ps1
```

The validator exits 0 only for nonempty valid data, emitting one JSON summary
with `status: valid-data`, schema/authority/scenario/fixture hashes, selected
IDs, positive document/case/assertion counts, fixture file counts, and coverage.
Assertion counts include initial, end-state, and wait-for declarations. It
never emits a UI verdict or dumps arbitrary input. Invalid data exits nonzero
with a bounded refusal code, without echoing input contents.

Refusal codes identify parsing (`InvalidJson`, `DocumentRoot`, `DocumentSize`,
`DuplicateProperty`), schema (`SchemaInvalid`, `UnsafeSchemaReference`),
binding (`ClaimAuthorityMismatch`, `DuplicateClaim`), discovery/selection
(`ScenarioRoot`, `EmptySelection`, `UnknownClaim`, `DuplicateRequest`, `MissingScenario`,
`ScenarioFileIdentity`, `DuplicateClaimFile`), fixtures (`UnsafePath`,
`UnsafeFixturePath`, `DuplicateFixtureFile`, `FixtureMismatch`,
`FixtureFileMismatch`), coverage (`ProofClassMismatch`, `StateNotApplicable`,
`IncompleteSemanticCoverage`, `HealthyRootRequired`, `InputTierRequired`,
`KeyboardStepRequired`, `RelaunchStepRequired`), or budgets
(`CaseBudgetExceeded`, `ScenarioBudgetExceeded`). `ValidationError` denotes
an unexpected tooling/I/O failure, never a success-shaped fallback.

The executable test suite invokes the actual validator in bounded child pwsh
processes, prints named results and one `UiScenario` structured count. The
existing ValidationRunner requires that child to exit successfully with positive
executed/passed counts and zero failures. Path classification tests only confirm
existing ancestor classification; they do not discover or execute scenarios.

## Not verified and later work

G1 establishes no human approval, runtime selector uniqueness/ownership,
current PID/HWND/generation, UIA pattern behavior, input, pixels, rendering,
cleanup completion, persistence, cross-platform parity, or issue closure.
Missing required UIA must not later be replaced by coordinates or private
commands. Cleanup failures cannot become successful claim verification.

G2 verifier/preflight and G3 replay/opt-in/result transport need separately
approved plans and leases. G1 installs no WinApp tool, creates no canonical
project root or lock, launches no product, changes no gate/workflow/TDD rule,
and adds no screenshot pipeline. Literal canvas IDs observed under a future
fixed project root are not portable across roots. Actual scenario authoring
waits for independent production verification and human review.

## G2-R1 capture-core repair and offline real-launch rehearsal

`Tools\windows\UiCaptureDriver.psm1`, `Invoke-UiCapture.ps1`, and
`Invoke-UiCaptureWorker.ps1` promote the **same A/cap driver lineage**, not a
second capture engine. The module embeds only the required native fragments
with source hashes and the repository's FSL-1.1-MIT provenance. Import compiles
declarations; it does not invoke a desktop operation or the old live gate.
Both real process-launch binders accept an empty argument array. The supervisor
attempts `lease-release.json` from `finally`, including refused malformed leases,
and preserves primary, cleanup, serialization, and write failures separately.
A blocked receipt write remains a nonzero tooling failure, not successful release.

Live native admission uses `Get-CapRequiredNativeBindingNames` from the module's
P/Invoke declarations, shared with the actual export resolver. Fully qualified
method signatures distinguish overloaded declarations. The supervisor's
`Assert-CapLiveNativeBindings` requires exact, case-sensitive name-set equality
and a resolved entry point for every binding; missing, duplicate, renamed,
unknown-extra and unresolved bindings refuse admission. There is no fixed
native-binding count to become stale when declarations change.

The focused contracts execute the actual supervisor non-rehearsal branch and
its production guard function without launching the capture command or using
the desktop:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -NativeBindingsContractOnly -ScratchRoot C:\owned\fresh-native-bindings
```

These eight contracts also run in the full suite registered by
`ValidationRunner.Tests.ps1` (167 default cases, or 170 with the three real-seed
cases). This establishes the live native-export admission guard, not an actual
live capture, geometry, UIA interaction, pixel result or broader native
compatibility. Rehearsal child commands still do not authorize desktop use.

Descendant discovery proves the held candidate and saved-parent native
generation/lifetime before classifying an image. A candidate proved older than
the parent (or newer than its proved exit) is excluded as parent-PID reuse,
with raw advisory and native evidence retained, never adopted or terminated.
Nonpositive, missing or unprovable creation times remain loud refusals, as do
same-generation unknown images and missing native identity. The existing
metadata, command, ancestry and named-binding guards remain in force.

One additional registered contract contains ten explicit lifetime subcases:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -DescendantLifetimeContractOnly -ScratchRoot C:\owned\fresh-lifetime
```

It invokes the actual `Get-CapOwnedDescendants` with real held owned processes
and deterministic advisory parent-PID injection. Native snapshot returns are
not replaced. It checks exclusion/deduplication, the same-generation unknown
image, five invalid saved creation values, changed saved generation and native
acquisition failure. Its owned fixture job and actual output EOF are checked
separately; this is not a global-host cleanup or live capture result.

When initial candidate handle acquisition specifically reports access denied
with its PID still available, discovery may also exclude a strictly older
**advisory CIM** creation time against the saved parent's **held native**
generation. This narrow exclusion does not prove that the candidate exited,
identify its image, adopt it or authorize termination. Raw CIM fields, the
original native failure/code, timestamp sources and parent snapshot are retained.
Equal/later, missing, unparseable, timezone-unspecified or nonpositive candidate
times, unproved/changed native parents, missing identity and other native errors
still refuse loudly. Advisory time never replaces job-zero or actual EOF proof.

The additional grouped contract invokes actual `Get-CapOwnedDescendants` with
an injected candidate getter failure and fourteen explicit exclusion/refusal
subcases, including a real live owned candidate that remains untouched:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -AdvisoryOlderContractOnly -ScratchRoot C:\owned\fresh-advisory-older
```

The original hosted access-denied artifact did **not** establish an exit race.
This advisory-only exclusion is a distinct rule, not an invented native
absence/recycled-generation observation. All earlier native metadata,
named-binding and native-lifetime contracts remain registered.

Run the offline regression with existing PowerShell 7.5+ and installed MSVC:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -PrepareFixturesOnly -ScratchRoot C:\owned\fresh-prebuilt
$prebuiltManifestHash = (Get-FileHash C:\owned\fresh-prebuilt\fixtures.json -Algorithm SHA256).Hash
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -ScratchRoot C:\owned\fresh-suite `
  -PrebuiltFixtureManifest C:\owned\fresh-prebuilt\fixtures.json `
  -PrebuiltFixtureManifestSha256 $prebuiltManifestHash
```

The scratch directory must be fresh and caller-owned. The test embeds the
complete harmless console target source, uses the installed Visual Studio
compiler without installing anything, and retains compiler/source/executable
hashes, exact commands, logs, real process identities, and release receipts.
`-LaunchContractOnly` selects the two real empty/nonempty argument tests;
without it, the suite also checks offset-qualified UTC/90-second cleanup reserve,
malformed/expired/future/overlong leases, target failure/timeout, guarded rollback,
and real primary-plus-cleanup/receipt-write failures. The frozen five-scene,
two-phase mocks remain **component regressions only**, with zero actual images.
Their permissive app substitute is not launch evidence.

The suite invokes this exact supervisor command shape in bounded child processes:

```powershell
pwsh -NoProfile -File Tools\windows\Invoke-UiCapture.ps1 `
  -OwnedRoot C:\gcs\your-worker\case `
  -OutputDirectory C:\gcs\your-worker\case\output `
  -ExecutionMode NO_DESKTOP_REAL_LAUNCH_REHEARSAL `
  -JobPath C:\gcs\your-worker\case\job.json -JobSha256 $jobHash `
  -LeaseReceiptPath C:\gcs\your-worker\case\lease.json `
  -LeaseReceiptSha256 $leaseHash
```

The generated job binds the harmless executable hash and exact argument vector;
the separate rehearsal-only lease binds the job and control-source hashes.
It explicitly denies desktop authorization. The same supervisor, worker,
lease, real app-starter/wrapper/core, ownership, stream, and release paths run
without mocks. Fresh output is initialized from explicit owned arguments
**before** parsing lease data; an untrusted lease ID cannot choose a path.
Refusal before a worker starts is `REFUSED_NO_WORKER`/`NO_WORKER_STARTED`,
not an empty zero-survivor proof. Once launched, success requires actual kernel
exit and bounded stdin/stdout/stderr completion. A failure preserves nonzero
status even when cleanup succeeds.

`ValidationRunner.Tests.ps1` registers exactly one child invocation and rejects
missing/duplicate summaries, zero executed tests, mismatched pass counts, or
nonzero failures before its final PASS. A run of that added block alone is
**not** a run of the full ValidationRunner.

This repair verifies no product UI, HWND/EDIT behavior, UIA, PrintWindow, pixels,
input, native compatibility, WinApp tool, backend turn, parity claim, production
scenario, or issue closure. Those paths are `NotExecuted` in the rehearsal.
The existing live B capture guards remain separately lease/preflight-gated;
these offline receipts grant no capture permission. Actual desktop use,
broader G2 verification, and G3 replay remain separately approved work.

The shared fixture-admission predicate derives the rewritten fixture hash from
the exact lease-bound mapping and hashes the actual rewritten file. Both live
callers retain the source hash, two-graph/ten-node contract, and per-graph owned
project-path checks; copying the old fixture bytes to another root is not a
relocation. Offline positive and negative data tests cover a fresh owned root,
stale mapping hashes, mismatched fixture bytes, wrong mapping destinations,
foreign embedded project paths, and refusal of preserved cap/lane roots.
This does not create or approve a canonical production root.

The harmless rehearsal target opts into redirected/closed stdin. GraphCode
and peer launches do not explicitly redirect stdin, but the worker clears
inheritance on its own STD handles first. Unchanged inherited-stdin behavior
for these live launches is not established; it remains a runtime watch.
The contained zmx
launcher uses a private stdin gate and closes the normal seed's redirected stdin.
Trace-write I/O failures are retained as explicit errors, never successful
evidence, and cannot bypass guarded cleanup or the final release attempt.

The supervisor's real lease-deadline/worker-kill branch, its standalone
`-TimeoutProbe`, and native compatibility beyond declared-export resolution
remain `NotExecuted` by this offline suite. The target-timeout case proves a
guarded target stop, not that distinct worker-deadline branch. The repaired
report gate checks control hashes, case identities, and positive counts in
lease-bound **report data**; it does not independently bind a product head or
fixture, perform native compatibility checks, or establish approval. Those
obligations remain with the separately authorized capture admission and
WinApp/native-compatibility work. Existing hosted runner-contract step budgets
are unchanged; the full runner plus child must fit those limits.

The frozen B fixture's prefix must be rewritten at **every** JSON position,
including node `worktreeBinding.path` values, not only the two project paths.
Admission checks every drive-qualified string against the owned project root
and compares the whole fixture with the source's complete prefix substitution.
A partially rewritten witness is refused even if its mapping hash was supplied.

Worker manifests and release receipts preserve separate cleanup failures and
unreturned launch records (PID, creation time, executable, role and rollback
errors). Missing, null, scalar, or nonempty worker cleanup/pending arrays make
release `CLEANUP_UNPROVEN`; an empty returned-run list cannot prove zero
survivors while an unreturned launch remains. The regression executes the
actual release data guard, without creating an unsafe child or mocking the
real launch path.

A guarded termination waits on the retained kernel handle even when
`TerminateProcess` fails because a process is already exiting. A positively
signalled handle is distinguished from a requested termination. Normal guarded
termination and genuinely exited handles run in the offline suite; the exact
access-denied exit race is not forced and is not claimed as runtime-proven.

### D same-core Quick Chat adapter

`D_QUICK_CHAT_V1` adds closed D scene, fixture and action branches to the same
module, supervisor and worker. Scene-marked no-desktop jobs validate the actual
scene and relocated fixture in both processes before the harmless console target.
They do not execute D scenes, a peer, zmx, product, live UIA or images.

The declared future inventory is ten scenes per phase, twenty images total:
populated chats, primary chat, restored history Shell, graph destination,
sidebar, overview, project, expanded/collapsed normal panels and route-away.
The client is 1440x952 at measured 96 DPI, with measured frame/work-area placement.
Runtime DPI-awareness remains unverified; jobs requiring it refuse.

One exact project, two loops, two dated chats, two metric samples and three
schema-2 layouts are bound to complete owned-prefix relocation and peer bytes.
Only the two exact chat sessions use System32 cmd.exe with
`/Q /K echo D_OFFLINE_QUICKCHAT_FIXTURE`. The peer acknowledges only the exact
fixture project's metadata-only normal-loop `resumeSession`; unapproved
verbs/payloads/identities fail. No backend attaches or receives input.

`d-chat-history-roles` describes actual restored Shell, not saved Agent/Split
labels. Those labels and missing-bound-chat live fallback remain **NotExecuted**
with component-only predicates; jobs requiring them live refuse. No extra seeds,
failed listing, fabricated trees/images, timing race or product hook substitutes.
Current job containment, typed closed-file output proof, numbered journals,
identity, UTC, lease and official release guards are retained; file closure is
not raw stdout/stderr EOF.

Focused child selection uses `-DAdapterContractOnly` (37 distinct cases).
`-DAdapterCase SceneContract`, `ActualAdmission` or `FixtureDirectory` selects one named case.
Prepare owned fixtures with `-PrepareFixturesOnly`, then supply the exact
`-PrebuiltFixtureManifest` and `-PrebuiltFixtureManifestSha256` for launch cases.
Default child registration includes inherited92 plus new37, exact129.
Declared counts are not execution evidence. Component predicates, harmless
launches and passing counts establish neither real scene behavior nor parity.
A future live run still needs current product/build admission, accepted B release,
applicable native evidence and a separately granted slot with90 seconds reserved.

## Issue 834 job ownership: source candidate, not native qualification

The job-based pivot is an operator-delegated design decision for later user
review, not a design personally reviewed or approved by the user. This source
candidate is an M1-only change. It does not authorize running this harness,
using a desktop, publishing a PR, or claiming the historical failure repaired.

The supervisor owns a noninherited KILL_ON_CLOSE job. The worker waits on
private stdin until assignment, held-generation attestation, and immutable
`worker-gate.json` publication have completed. This contains all subsequent
worker app, peer, daemon, and compiler descendants. Its accounting is queried
before its owner handle is closed; real worker stdout/stderr readers must
also finish successfully. A failure before assignment never releases the gate.

Each zmx seed uses an additional job and a source-bound embedded PowerShell
launcher. The launcher is assigned and its exact generation/job is registered
in the existing numbered journal before its gate is released. It starts zmx
normally with `ProcessStartInfo.ArgumentList`, not a suspended/custom native
process launch. The original target handle supplies post-start identity and
exit receipts. This does **not** establish zmx identity before execution.
All live job members are censused using held handles and membership checks;
readiness still requires a positive daemon/cmd count. Unknown member roles
are contained, not adopted from executable names or PIDs alone.

The launcher copies the target's private raw pipes into owned byte files
using unbuffered file streams. These are **not direct target file handles**.
Termination may interrupt a daemon's final private-pipe tail; completeness
of that tail is not claimed. After job termination and bounded Active=0,
the worker compares retained file pins against writer-excluding readers and
records their lengths and SHA-256 hashes. The final reader reopens and verifies
those same bytes while holding writer-excluding readers. This proves the
recorded owned bytes are stable at those checks, not foreign-writer absence.
Target-file closure is never labelled target pipe EOF. Launcher and worker
pipe EOF remain separate, actual reader-task observations.

An umbrella member seen before the final safety-net stop is exempt only when
it is the exact live held worker generation, not merely a matching PID or
process name. Every other observed member records a typed `SAFETY_NET_KILLED`
recovery receipt with PID-only membership evidence and an explicit cleanup
failure. The existing release gate then reports `CLEANUP_UNPROVEN`, even if
the worker supplied an otherwise clean terminal proof. Job emptiness is not
allowed to turn that missing per-member cleanup evidence into a clean release.

The worker and embedded launcher call GetStdHandle/SetHandleInformation on
their own STD handles before target launches, refusing invalid handles/API
failures. This does not prove behavior of runtime-cached or duplicated
handles. Generic J4 identity/refusal functions and J5 binding, publication,
and hash-chain function text remain unchanged; the final receipt validator
adds a job/file-output branch without weakening generic raw-pipe receipts.

The source-owned inventory is 26 P/Invoke declarations / 24 unique APIs:
the original 16/15 plus the minimal job adapter's 10/9. The adapter reuses
managed held-process acquisition and the existing CapNative snapshot rather
than duplicating OpenProcess, GetProcessTimes, or image-query declarations.
There is no job-open/duplication/recovery API, escape flag, external helper
source file, imported test runtime, or live-path mock.

Test definitions retain the original 59 cases (the native export contract is
updated to 26), adding three contained harmless normal/nonzero/timeout cases,
one STD source-ordering check, and N1's full numbered-final-proof synthetic
output-descendant accept/refusal fixture, plus one negative umbrella safety-net
release assertion, lease-path and receipt-IO groups, prebuilt binding, journal-phase timing, first-Open, buffered-observation, selector-refusal and identity-acquisition contracts: 92 expected cases. N1 is not real
seed evidence. `-RequireRealSeed` additionally defines three actual-command
cases: two real zmx phases before a normal, nonzero, or timed-out harmless
target, for 95 expected cases. It requires explicit `-RealSeedZmxPath` and
`-RealSeedZmxSha256` inputs admitted against the pinned provider; there is no
PATH or stale-candidate fallback. Without those cases, the repaired report
gate refuses live admission even if the 92 offline cases pass.

None of these new native cases ran during M1. Parse/compile-only evidence
does not establish job nesting, gate timing, output transport, native STD
inheritance, real zmx readiness, cleanup, GUI behavior, or parity. The accepted
historical RED is run `cdba36a51f144798b40fd78bdb50251b`: a seed exited while
its daemon retained worker pipes, leaving cleanup/EOF/final binding unproved.
It must not be unsafely reproduced. A separate explicit M2 release and
independent source review are required before any native qualification.

### Short zmx state paths and the B invocation limit

Each phase's zmx state now uses a fresh five-hex directory directly under
the **actual owned root**, separate from nested run artifacts. Creation
without `-Force` refuses a collision rather than adopting old state; the
existing owned-path/reparse checks and private owner ACL remain in force.
The same `Roots.Zmx` feeds the seed and live B app environment, including
normal and actions phases.

Before seed launch, the guard mirrors pinned zmx's lowercase hex encoding
of UTF-8 session bytes and computes
`ZMX_DIR\ipc\SID\hex(session).endpoint.lease`. It accepts at most **240**
characters; 241 raises `PathTooLongException` with
`CapCaptureCode=ZmxLeasePathTooLong`. Diagnostics expose SID length, not the
SID value. A live app's harness-session shape is guarded before app launch.

**A new LIVE_CAPTURE B invocation requires a fresh owned root of at most
five characters**, for example `C:\b1` only if independently allocated,
absent and coordinator-authorized. Its longest actual harness session is
78 characters / 156 UTF-8 hex characters. With the observed 52-character
SID and five-hex leaf, that root gives a 240-character lease. A longer B
owned root is refused before worker launch with
`CapCaptureCode=BCaptureRootTooLong`; there is no prefix truncation,
foreign-parent allocation or fallback.

The historical `C:\gccp\capture-coordinator-b1` owned root is 30 characters:
a five-hex runtime leaf would give a **265-character** B-actions lease.
That layout is infeasible and remains read-only history; do not relocate,
reuse or delete it. The seven-character root used for a seed-only contained
rehearsal is a separate case: its nested case-owned root and 46-character
seed session are measured against the same actual-path guard.

Retained failures had `ipc\SID` directories present but empty, while both
endpoint and lease files were absent at inspection; their long lease paths
measured 264-265 characters. Successful diagnostic A retained both files at
173 characters. This is the operator's path-length attribution pending the
new contained runtime result, not a claim that current absence proves every
historical event or that a compile-only check establishes repair.

### Bounded receipt-file IO contracts

The private production target/exit receipt reader snapshots an opened file
with `FileShare.ReadWrite | FileShare.Delete`. It retries only sharing
violation `IOException` (native code32), file/path not-yet-published (2/3),
and incomplete or invalid JSON/schema, within the caller's existing deadline.
The existing missing-file/held-launcher exit refusal remains. Unrelated IO,
access/security errors and valid foreign identity are not retried.
Complete records must bind jobId/specSha256 and positive PID/creation time;
an exit receipt must also match the previously accepted target generation.
No record is returned after the deadline. Exhaustion is a typed
`TimeoutException` with `CapCaptureCode=ReceiptDeadlineExceeded`; a valid
foreign binding is `InvalidDataException` with `ReceiptIdentityMismatch`.
The existing immutable writer already flushes/closes a temporary file and
renames it into place; its publication protocol is unchanged.

Run only the focused file contracts, without a compiler fixture, provider,
real target or full capture suite:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -ReceiptContractOnly -ScratchRoot C:\owned\fresh-receipt-contracts
```

The five positive contract cases cover an exclusive holder released while
the actual production reader waits, an exclusive hold past its typed
deadline, partial JSON followed by atomic complete publication, foreign
job identity, and foreign PID/creation. Bounded in-process runspaces drive
the actual module-private reader; live launch/lease/release paths have no
test override. Retry trace observations assert actual sharing/parse retries.
`-ReceiptExclusiveOnly` with that focused mode selects just the exclusive
release case for discriminating RED/GREEN evidence.

These five contracts are registered as one full-suite case within the current
92/95 prospective counts above. Focused reports are named
`UiCaptureReceiptContracts` and cannot stand in for a complete capture
preflight. A file-IO GREEN is not native lifecycle or job-zero GREEN.
The strict outer job-zero gate remains unchanged; there is no vctip exemption.

### Native fixture precompilation and journal phase diagnostics

The controller now prepares **both native C fixtures** (capture-target and
CIM-race-target) before creating/assigning the added suite job. It invokes
the existing two builders in `-PrepareFixturesOnly` mode, retaining compiler/
preparation-host identities, command, exit, raw logs and provenance. This
means outside the **added suite job**, not machine-jobless or zero surviving
parent telemetry children. The parent may be in an ambient job. Per-process
PowerShell `Add-Type` compilation remains in process; it is not prebuilt here.

The prebuilt manifest binds the exact two recipes and fourteen artifacts:
each source, EXE, OBJ, provenance, compile.cmd, stdout and stderr log, plus
the current control-source hashes. The actual suite requires its explicit
manifest path and SHA-256, checks names/lengths/digests/provenance, and refuses
missing, foreign or altered input. There is **no compile fallback inside the
suite job**. The controller records the manifest/all fourteen references in
its configuration and final result and rehashes after the suite. Core per-case
lease/identity/cleanup bindings are unchanged. A focused synthetic-byte
positive/missing/tampered binding contract is registered in the full suite.

MSVC redirects to retained `compile-stdout.raw.log` / `compile-stderr.raw.log`.
The existing share-tolerant reader returns its same captured byte array,
length, observation time, text and SHA. Preparation requires a positively
present raw file and non-null captured bytes/hash, then publishes those exact
bytes with CreateNew under the canonical `compile-stdout.log` / stderr names.
It never re-encodes text, rereads raw bytes to manufacture the snapshot, or
overwrites a published snapshot. The fourteen-file manifest binds these
immutable snapshots; provenance also binds the raw path, snapshot time/SHA/
length and compiler exit/held command-host identity. Raw log EOF and complete
stream closure remain **UNPROVEN**, not silently converted to immutable-file
or parent-host EOF. The focused contract holds a sharing writer, changes its
raw file after capture, and proves publication preserves the original exact
bytes (including BOM/newlines/non-UTF8 bytes).

Preparation has a two-minute host bound within the same runtime window.
The controller checks at least seventeen minutes of suite/cleanup headroom
again after precompilation and immediately before assignment/gate release.
If that reserve is gone, it refuses to start the suite; no implicit extension.
Any member (including vctip) inside the suite job still fails its strict zero
gate. Old PID31840's ownership in the no-breakaway job was established; its
specific compiler parent was not recorded. Moving the two MSVC fixture
compiles is the authorized scope, not a retroactive parent attribution.

Journal diagnostics add cumulative measured Open/Copy milliseconds and total
transaction elapsed time to observations and JournalUnavailable messages.
Unattempted phases remain null/`UNOBSERVED`, not invented zero. Open and Copy
throw paths retain measurements; there is no flushed observation between
successful CopyTo and its first deadline check.

The numbered-object reader's **1000ms I/O budget starts once at its first
Open attempt inside `Read-CapJournalObject`**, after caller preparation and
path construction, not at transaction creation or sequence discovery. This is
the explicit #851 revision to the #829 creation-started clock contract.
The absolute UTC lease/transaction deadline remains hard even before Open;
the first I/O budget is clipped to its remaining time. Subsequent reads,
sequence advancement and retries never restart that clock or reset the
**seven global retries / eight Open attempts per sequence**. Final manifest
reads explicitly retain their creation-started 1000ms transaction budget.
No late success, schema or identity checks are relaxed. The two-minute fixture
context does not replace either one-second I/O/manifest budget.

Only failure messages and failure observations add `preOpenMs` and `firstOpen`.
After an attempted Open, `preOpenMs` is the frozen measured interval from
transaction creation to the first attempt. If the absolute deadline expires
first, it is actual elapsed creation-to-refusal time, with
`firstOpen=NOT_ATTEMPTED`; no Open or phase duration is invented. Successful
observation counts and ordering are unchanged. A failed deadline
observation in `Assert-CapJournalTime` retains the primary `JournalUnavailable`,
with an explicit secondary diagnostic. This does not change or establish
primary-error preservation in the existing OpenFailed, CopyFailed or
FinalManifestOpenFailed observation paths. The focused first-Open groups exercise an actual >=1500ms caller
delay followed by a valid held-file read, absolute pre-open refusal, clipping,
once-only clocks/counters, legacy manifest timing and observer failure.
Both new caller-delay tests sleep until the assertion's own clock measures
at least 1500ms, with a 5000ms harness cap checked even after the final sleep.
Their report details retain the measured delay, including assertion failures.
Host-load/foreign-build causation of the old N1 timeout remains unproved.

Non-failure observations, including `ReadVerified` and
`AcceptedLiveSequenceOnly`, use OS-buffered `Flush()`, not disk-durable
`Flush(true)`. **Durability is terminal-only**, not inferred from a failure
label: `DeadlineExhausted` and `CopyFailed` end the read and flush durably.
The numbered and manifest Open callsites explicitly request terminal durability
only for non-retryable HRESULTs or exhausted retry/attempt limits.
`OpenFailed` and `FinalManifestOpenFailed` with retryable HRESULTs
`80070002`, `80070003`, `80070020` or `80070021` remain buffered while a retry
is available. All successes and unknown decisions stay buffered even if a
terminal switch is mistakenly supplied. The 1000ms budget, retries,
first-Open boundary and absolute deadlines are unchanged.

Each record carries an `observationTransactionId` GUID and an attempted
`observationOrdinal`, bound to its existing run ID. **`previousObservationWriteMs`
is explicitly lagged**: it measures the previous completed observation's
serialization, Open, Write, selected Flush and Dispose, not the current record.
`previousObservationOrdinal` identifies that completed write in the same
transaction/run. Both fields are null on the first record. A failed write
reserves an ordinal but does not update the last-completed pair; gaps are
intentional, not a fictional N-1 reference. The current completed duration
remains in transaction memory for the following record and failure diagnostics.
There are no extra success records or rewrites to serialize self-duration.
The new contract uses a transparent FileStream subclass, substituting only the
actual writer's unique Open constructor and restoring that writer in `finally`.
Its slow durable-flush seam must not delay a successful read; additional real
Flush/Dispose delays and a failed write check completed-duration/ordinal binding.
This compiles a C# seam in-process, not a native fixture or target.
The same group extends that seam with two **injected** typed sharing HRESULTs
followed by a real nonempty file Open. This is controlled retry evidence, not
proof of kernel sharing violations. A separate probe verifies that configured
sequence and resets counters before the timed actual reader. On the old policy,
the first slow durable retry observation exhausts the budget before the second
attempt. The revised path must complete two retries, three Opens and all four
buffered observations (including caller-equivalent acceptance and its actual
deadline check) within 1000ms, without durable flushing. Existing two-success
observation assertions remain unchanged.

On actor cleanup failure only, the harness appends the known owned
`Reader-failed.json` and `Writer-failed.json` contents to the existing cleanup
assertion. Each read is bounded to 16KiB plus one truncation-detection byte;
missing, unreadable and truncated primaries are explicit. Successful cleanup
does not read these files. Exit, generation, kernel/EOF assertions and recovery
remain unchanged. This fixes harness diagnostic masking, not the separate
production observer-primary masking risks described above.

Hardening's deterministic matrix and Windows port validation's `spikes-swift`
job are configured to retain capture-contract diagnostics only on failure, for
seven days. A failure-only step resolves the same `[IO.Path]::GetTempPath()`
used by the capture producer, not the potentially different `RUNNER_TEMP`;
missing/invalid output paths fail explicitly. Uploads select JSON/JSONL/log files under the existing
`gc-ui-capture-*\suite` root and fixture manifest/provenance/compiler logs under
its `prebuilt` sibling, excluding Git metadata. They do not include whole TEMP,
environment dumps, credentials, binaries or screenshots. No matching files
warns without replacing the original failure. The upload failure branch remains
runtime-unverified until an actual CI failure exercises it; a green job is not
upload evidence. #846, #849 and #851 are related capture-core failures, not a
claim of a common cause or harmlessness.

Run the focused synthetic prebuilt binding and actual file-IO timing/observation
contracts without a native fixture compiler or target (the observation seam
compiles C# in-process):

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -FixtureContractOnly -JournalTimingContractOnly -JournalFirstOpenContractOnly `
  -JournalObservationContractOnly `
  -ScratchRoot C:\owned\fresh-setup-contracts
```

The two prior #845 setup groups gave the historical 69 offline / 72 real-seed
inventory. The two #851 first-Open groups brought that inventory to 71 offline / 74
real-seed cases. The #852 buffered-observation group brought that inventory
to 72 offline / 75 real-seed cases. The thirteen #848 selector-refusal groups
bring that inventory to 85 offline / 88 real-seed cases. The seven identity-acquisition
groups bring current full-suite expectations to 92 offline / 95 real-seed cases. Historical run counts are not
relabelled by these additions. A focused
setup-contract pass is not a complete capture, native job-zero or parity pass.

`ValidationRunner.Tests.ps1` uses this same two-step PrepareFixturesOnly →
manifest SHA → consuming capture-child flow. Its existing positive-count,
unique-summary and zero-failure checks are unchanged. This CI runner path
does not add a suite job; precompilation there preserves the same input
contract, not a claim of vctip containment. An isolated execution of its
capture-caller slice is not the full ValidationRunner or the separate
real-zmx qualification run.

## Selector refusal diagnostics (issue 848)

An already-refusing direct selector writes one `CapSelectorRefusal` record through the
existing trace sink. Its `parameters.diagnosticJson` string is bounded JSON with
schema `CapSelectorRefusal/1`; consumers parse that string as JSON rather than
treating legacy CLR type names as candidate or PID evidence. The original
exception type, message and ErrorRecord are rethrown unchanged. An observer
failure is surfaced as `CAP_TRACE_FAILURE` and by `Get-CapTraceFailures`, not
substituted for the selector refusal. Successful selectors add no diagnostic
property reads, serialization or writes.

The worker's actual `Wait-CapVisibleElement` is different from a direct selector:
its zero-match refusals are intermediate polls, not terminal wait failures.
Polling retains only the last already-enumerated candidate references and cheap
call context. It does no diagnostic property reads, projection, serialization
or writes. Only after the wait definitively fails does it attempt one
`TERMINAL_LAST_POLL_SNAPSHOT` record, outside the wait budget, without another
tree/window query. The original wait refusal remains primary. This adds no
timeout allowance or retry. With no trace sink, neither the resolver nor the
terminal observer prepares a snapshot/context or performs diagnostic work.
An attempted snapshot cannot emit or report an observer failure twice.

`terminalObservation.lastPollUtc` and `waitDeadlineUtc` bind the retained
references to the wait; `failureObservedUtc` and `propertyReadStartedUtc` mark
the later observation. The properties are deliberately read **after failure**,
not frozen values from the last poll. They may have changed or vanished.
An unavailable `Current` getter is retained as a typed read error and is
propagated to the unavailable candidate fields, never treated as an empty
element or a reason to query again.

`stageCounts` scans the full existing candidate collection, cumulatively in the
original order: process-owned, exact case-sensitive Name, optional exact ID,
optional ordinal prefix, visibility rule, positive bounds. Inactive optional
stages propagate the previous count. With `AllowOffscreen`, `visible` counts
passage through the visibility **rule**, not actually visible elements.
`stageReadErrors` and `stageCountsComplete` distinguish unavailable decision
properties from observed negative matches. A query not reached is
`candidatesObserved=false`, with null counts, not an invented empty result.
Held window/process-generation context comes only from existing call data;
unavailable context/root PID is labelled `NotObserved`.

At most 16 candidates are retained, ranked by deepest passed cumulative stage
then original source index. Total/sample/omitted counts and the sample policy
are explicit. Each Name, AutomationId, ProcessId, IsOffscreen, BoundingRectangle
and ControlType field distinguishes `Value`, `Null`, `Missing` and `ReadError`.
Successfully read `Rect.Empty` remains `Value` with `rectangleKind=Empty`.
Finite rectangle coordinates are JSON numbers; special coordinates are typed
`numberKind` markers (`NaN`, `PositiveInfinity`, `NegativeInfinity`).
`propertyReadSucceeded` distinguishes those real values from failed reads.
The bounds stage uses the original raw null/Width-less-than-or-equal-zero/
Height-less-than-or-equal-zero rejection predicate literally, including its
special-number semantics; it does not replace it with a positive comparison.
ControlType is a scalar programmatic-name string, not a serialized UIA object.
Strings are capped at 512 UTF-16 units (ControlType 128, errors 256, recorded
refusal message 1024), with original-length/truncation metadata. Truncation
never splits a surrogate pair; isolated surrogates are replaced and disclosed.
Only the diagnostic copy of a message is clipped.

`observedProcessIds` is the first 64 **distinct actually read primitive PIDs**
in source order, not a full lossless observed array. Raw observation count,
distinct count, sample count, unavailable count, truncation and completeness
are recorded separately. The expected PID is never substituted as an
observation. Diagnostics do not query a fresh tree/window, retarget, adopt a
foreign candidate, retry, or change selector/deadline/ownership decisions.

The focused thirteen-case group uses synthetic candidates with the actual
resolver and retained trace sink, plus the actual worker wait/deadline
functions extracted by AST and a synthetic query leaf. It uses the real
100 ms polling cadence and compiles/launches no target:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -SelectorRefusalContractOnly -ScratchRoot C:\owned\fresh-selector-contracts
```

The empty-bounds fixture is a **synthetic canonical Rect.Empty numeric shape**,
not an instantiated WPF rectangle or live UIA evidence. Structural
classification uses the four already-read primitive coordinates, without
adding a WindowsBase dependency or changing assembly loading.

All thirteen cases are also registered in the normal suite: currently 92 ordinary
or 95 real-seed cases, preserving all 75 real-seed case names from the merged
journal base. The four timing
subcases and journal success path are unchanged. This diagnostic evidence is
not live UIA, graph-delivery, rendering, input, B-scene or parity evidence;
the live refusal's root cause remains unclassified until separately admitted
retained runtime evidence is available.

### Typed Process identity acquisition

`Read-CapProcessAccess` explicitly invokes `Process.get_Handle()` and
`Process.get_Id()` once each per acquisition boundary. Unlike PowerShell's
adapted property reads, these invocations retain accessor exceptions instead
of passing a null value to the `Snapshot` argument binder. The shared helper is
exported for the bound embedded launcher and supervisor; it does not open or
adopt a different process.

Unavailable, null or invalid access is an `InvalidOperationException` with
`Data.CapCaptureCode=ProcessIdentityUnavailable`, role, callsite, independent
Handle/Id states, and the original accessor exception(s). A valid acquired
PID and a caller's expected PID are separate nullable evidence fields; an
expected PID is never substituted for an unavailable acquired PID. Only an
actual nonzero/non-minus-one `IntPtr` and positive `Int32` reach `Snapshot`.
An acquired/expected PID mismatch refuses ownership. The native snapshot's
PID, creation-time, image and kernel checks remain mandatory.

Image-path attestation is a separate typed boundary after Handle/Id
acquisition. A live retained generation that receives
`QueryFullProcessImageNameW` error 5 is retried at most twice, for three total
attempts with two 50 ms waits. Every attempt explicitly reacquires Handle/Id
and rechecks native PID, creation FILETIME and kernel liveness; a changed
generation refuses immediately. Other image-query errors do not retry.
Exhaustion raises `ProcessImageAttestationUnavailable` with the actual PID,
creation FILETIME, Win32 code and attempt count. Expected or CIM image text is
never substituted for a missing live native image. If the held generation
exits between attempts, existing kernel-exit and both-stream EOF gates still
govern whether it is genuinely gone.

Launch error formatting uses retained acquired PID evidence or the explicit
word `UNAVAILABLE`, not another read of a disposed object. The original typed
attestation error and any secondary rollback error remain observable.
Unavailable rollback retains its pending record, reports kernel exit as
unproven, and refuses unsafe termination. Pending probe failure details remain
typed, with `KernelExited=null`; neither this value, a missing CIM row nor a
getter exception proves exit or bounded stdout/stderr EOF. Existing strict
generation, current metadata, parent/session, deadline and EOF gates remain
in force.

The seven registered focused cases exercise actual not-started/disposed
self-process wrappers, synthetic null/invalid/independent-failure accessor
states, valid self kernel/CIM identity, PID/native mismatches, disposed tracked
assert/stop/wait refusal, and the actual failed-launch handler/rollback/pending
formatting path without starting a child. The valid-self and rollback groups
also cover injected transient/persistent image error 5, generation change,
typed refusal, and cleanup remaining pending/unproven without a kill:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -IdentityContractOnly -ScratchRoot C:\owned\fresh-identity-contracts
```

The original unchanged-source RED reaches the actual initial
`Get-CapProcessIdentity` Snapshot binder with a null Handle; it does not enter
the native method body. The image-attestation RED uses an actual live
self-process kernel generation and injects only the image-query Win32 result:
the one-shot boundary refuses the first error 5 instead of retrying. Controlled
disposal and injected error results demonstrate deterministic contract paths,
not the cause of any historical #849 occurrence. These self-process and
synthetic contracts are not native child-lifecycle, full-suite, UIA, live B or
parity evidence.
