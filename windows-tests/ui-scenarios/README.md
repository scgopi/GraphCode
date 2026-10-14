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

Run the offline regression with existing PowerShell 7.5+ and installed MSVC:

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -ScratchRoot C:\gcs\your-worker\capture-rehearsal
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

Only the harmless rehearsal target opts into redirected/closed stdin; live
GraphCode, zmx seed, and peer launches keep their inherited stdin behavior.
Trace-write I/O failures are retained as explicit errors, never successful
evidence, and cannot bypass guarded cleanup or the final release attempt.

The supervisor's real lease-deadline/worker-kill branch, its standalone
`-TimeoutProbe`, and `Test-CapNativeBindings` (16 declared export bindings)
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
