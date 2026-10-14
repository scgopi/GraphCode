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
