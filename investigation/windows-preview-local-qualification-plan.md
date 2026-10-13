# Windows preview — local candidate and release plan

## Audience and purpose

This plan is for a new agent running in the GraphCode repository on the current
development machine.

It owns:

- candidate selection and source audit;
- any permission-free preparation PR;
- exact local tag, build, package, checksum, and verification;
- creation of the self-contained Dev Box handoff bundle;
- review of the returned Dev Box evidence;
- coordination of any defect PRs and candidate rebuilds;
- tester packet review and final publication, only after Approval B.

It does **not** install the candidate for qualification, drive native UI,
authenticate a backend, mutate destructive fixtures, capture a process dump, or
publish before Approval B.

## Repository context

- Repository: `scgopi/GraphCode`
- Windows product: `graphcode-windows/`
- Windows tooling: `Tools/windows/`
- Shared Swift: `GraphcodeKit/`
- Release plan: `investigation/windows-preview-release-plan.md`
- Parity ledger: `investigation/ui-parity-matrix.md`
- Dev Box plan: `investigation/windows-preview-devbox-qualification-plan.md`
- Repository rules: `CONTRIBUTING.md` and `AGENTS.md`

The baseline when these plans were prepared was main
`e1023ad7cfb151f664080537c38887e669864c48`. Do not assume it is still current.

## Non-negotiable rules

1. Use the repository-pinned Windows bootstrap and toolchains.
2. Never use `-AllowTagMismatch`.
3. Do not push the local qualification tag.
4. Do not publish in the candidate-build phase.
5. Every retained observation is `Passed`, `Failed`, or `NotExecuted`.
6. Empty results and zero executed counts are never PASS.
7. Do not retain credentials, tokens, cookies, or private corporate data.
8. A candidate identity change invalidates all downstream evidence.
9. Every commit/PR follows DCO, TDD evidence, and repository-template rules.
10. Publication requires a separate Approval B naming the exact tag and ZIP.

## Required user decisions: Approval A

Stop before creating the candidate unless these values are filled:

- Candidate source SHA:
- New prerelease version:
- Local unpushed annotated tag:
- Microsoft Dev Box definition/image and Windows build:
- Remote client/version:
- Minimum viewport at 100% scaling (no other scaling on a Dev Box; see #749):
- Screenshot permission; video permission:
- Accessibility scope: UIA + keyboard, or named screen reader/version:
- Keyboard layout (US English; IME and international layouts are outside
  parity scope, see #747):
- Clipboard mutation/restoration:
- Named disposable fixture roots and destructive/Recycling permission:
- Backend kind/model/attended permission mode (version: whatever the Dev Box
  has installed, recorded with its hash at run time):
- Backend credentials provisioned outside chat:
- Hard ceiling: exactly two turns / USD 5 equivalent:
- Build a distinct predecessor package for upgrade/rollback: yes / no:
- #560 decision: defer/guard Worktrees, or authorize dump-backed fix:

## Phase L0 — refresh and audit current main

1. Read `CONTRIBUTING.md`, `AGENTS.md`, the release plan, and parity ledger.
2. Fetch current main:

   ```powershell
   git fetch origin main
   git status --short
   git rev-parse origin/main
   ```

3. Require a clean candidate worktree and record:

   - candidate SHA;
   - commit parents;
   - submodule/provider pins;
   - `Package.resolved`;
   - pinned Swift/Zig/provider versions;
   - open PRs that touch candidate-critical files.

4. Reconcile Approval A's candidate SHA with the fetched SHA. Stop on mismatch.
5. Record the ledger counts and open preview issues without changing status.

## Phase L1 — permission-free preparation

Use **zero or one PR**. Do not build a new evidence framework.

Only address confirmed preparation gaps:

1. Reconcile any stale terminal-sizing documentation with current source without
   claiming runtime behavior.
2. Clarify that installed Git may be a declared runtime prerequisite for
   Git-backed features, while install/start/onboarding must not depend on Git,
   the checkout, Swift, Zig, SDKs, or developer environment variables.
3. Reuse `Tools/windows/Tests/PreviewCore.Qualification.ps1`.
4. Add only manifest/checklist fields that the three-run process demonstrably
   needs.

If no code/doc change is required, record `NotNeeded` and continue.

## Phase L2 — create the exact local candidate

### 1. Bootstrap

```powershell
pwsh -NoProfile -File Tools\windows\bootstrap.ps1
. .\.graphcode-tools\environment.ps1
```

Verify exact pinned identities:

- Swift 6.3.3
- shell Zig 0.15.2
- zmx Zig 0.16.0
- Winghostty `6286560d0aa3103e068b2b7afa81eac373d870c9`
- zmx `785b3fd15dcafd1882b495c831a10f98c201b908`

Stop if provider worktrees are dirty or pins differ.

### 2. Create a local unpushed tag

```powershell
git tag -a <approved-tag> <candidate-sha> -m "GraphCode Windows preview candidate"
git rev-parse "<approved-tag>^{commit}"
```

Require the peeled commit to equal the candidate SHA. Do not push the tag.

### 3. Build the unpublished package

```powershell
pwsh -NoProfile -File Tools\windows\release.ps1 -Tag <approved-tag>
```

Do not pass `-Publish` or `-AllowTagMismatch`.

Preserve the release command log and exact output directory.

### 4. Verify the candidate

Use the repository packaging documentation and the generated
`GraphCode-Setup.ps1` to verify the ZIP and extracted package.

Require:

- exactly one package verification PASS;
- positive nonzero manifest file count;
- source/tag/version equality;
- ZIP SHA-256;
- exact provider/tool identities;
- explicit `UNSIGNED (not code signed)` state;
- no pushed tag or uploaded asset.

Any mismatch is FAIL and stops the handoff.

## Phase L3 — create the Dev Box handoff bundle

Create:

```text
GraphCode-DevBox-Handoff\
  candidate\
    graphcode-windows-x86_64.zip
    graphcode-windows-x86_64.zip.sha256
    candidate-manifest.json
  source\
    GraphCode-source-custody.zip
    GraphCode-source-custody.zip.sha256
  plans\
    windows-preview-devbox-qualification-plan.md
  approvals\
    approval-a.json
  hashes.sha256
  README-FIRST.md
```

### Candidate manifest minimum fields

- schema version;
- candidate SHA and parents;
- version and local tag;
- ZIP filename, size, and SHA-256;
- payload manifest hash/count;
- package unsigned state;
- provider/toolchain identities;
- Dev Box plan SHA-256;
- source custody ZIP SHA-256, embedded candidate/tag identity, and LFS
  object/file counts;
- Approval A values;
- creation UTC and operator.

### Source custody

Create a deterministic custody ZIP containing the candidate's annotated tag,
Git bundle, exact candidate-tree LFS objects, integrity manifest, and standalone
restore script:

```powershell
pwsh -NoProfile -File Tools\windows\source-custody.ps1 -Command Create `
  -Repository . -Candidate <candidate-sha> -Tag <approved-tag> `
  -Artifact GraphCode-source-custody.zip
pwsh -NoProfile -File Tools\windows\source-custody.ps1 -Command Verify `
  -Artifact GraphCode-source-custody.zip
```

Do not substitute a bare Git bundle. Git bundles do not contain LFS media, and a
bundle file is not a valid Git LFS standalone-file remote. The custody verifier
requires the bundle, annotated tag, candidate SHA, restore script, and every
manifested LFS object to agree. The source custody ZIP is for evidence scripts
and source inspection on the Dev Box. The installed product must still run from
the package installation, not the checkout.

### Handoff integrity

1. Hash every file after it is finalized.
2. Write `hashes.sha256`.
3. Verify every hash once before transfer.
4. Transfer through an approved corporate mechanism.
5. Do not include credentials, tokens, existing session logs, private source,
   or unrelated artifacts.

`README-FIRST.md` tells the Dev Box agent to begin with the Dev Box plan and
stop on any hash mismatch or missing Approval A value.

## Phase L4 — wait for the Dev Box return bundle

Do no publication work while the Dev Box plan is running.

Expected return:

```text
GraphCode-DevBox-Return\
  result-summary.md
  manifest.json
  hashes.sha256
  logs\
  identities\
  uia\
  media\
  readbacks\
  cleanup\
  dumps-local-only\   # omitted unless separately authorized
```

Verify:

- returned candidate SHA/tag/ZIP hash match the handoff;
- all evidence hashes validate;
- every gate step is `Passed`, `Failed`, or `NotExecuted`;
- no empty result is marked PASS;
- cleanup status is explicit;
- dump files were not transferred unless separately approved.

## Phase L5 — triage results

### If a required step failed

1. Do not reinterpret it as partial success.
2. Attribute the failure to product, driver, environment, or missing
   authorization.
3. Open one bounded issue/PR per root cause.
4. Use TDD, DCO, exact-head CI, and honest evidence.
5. If candidate code changes, create a new candidate SHA/tag/ZIP and restart
   both plans. Do not mix evidence across candidates.

### If an item was NotExecuted

Confirm the tester packet excludes that behavior. If it is required by an alpha
gate, the preview remains blocked.

### #560

- If Worktrees was deferred/guarded, verify the supported preview cannot invoke
  the starving path and keep #560 open.
- If a dump-backed fix was authorized, keep raw dump data on the Dev Box only.
  Receive only the sanitized stack/child-state conclusion unless raw transfer
  was separately approved.

## Phase L6 — tester packet and Approval B

Prepare a tester packet with:

- exact supported Windows/Dev Box profile;
- exact backend/version/model;
- ZIP SHA-256 and verification steps;
- unsigned/SmartScreen/organization-policy warning without bypass advice;
- one supported workflow;
- install, reinstall, uninstall, recovery, and data paths;
- known limitations and every `NotExecuted` behavior;
- privacy-safe issue/report route.

Review all seven gates:

| Gate | Required evidence |
|---|---|
| Exact artifact | Local candidate custody |
| Clean installation and recovery | Dev Box install + lifecycle |
| Production core flow | Dev Box core fixture |
| Useful agent terminal | Dev Box two-turn backend |
| Reachability and lifecycle | Dev Box native/profile checks |
| Safe mutations | Dev Box destructive fixture |
| Honest tester handoff | Tester packet review |

## Approval B — publication

Do not proceed unless the user explicitly names:

- exact tag to push;
- exact ZIP SHA-256;
- GitHub release destination;
- prerelease/latest behavior;
- confirmation not to overwrite `v0.1.77`.

Only after Approval B:

1. re-verify candidate/tag/ZIP identities;
2. push the exact tag;
3. run `release.ps1 -Publish`;
4. verify uploaded asset metadata and checksum;
5. retain rollback/withdrawal instructions.

## Local plan completion checklist

- [ ] Approval A complete
- [ ] current main audited
- [ ] preparation PR merged or NotNeeded
- [ ] local tag created and not pushed
- [ ] candidate ZIP built and verified
- [ ] handoff hashes validated
- [ ] Dev Box return hashes validated
- [ ] failures resolved or scope explicitly reduced
- [ ] all seven gates reviewed
- [ ] tester packet complete
- [ ] Approval B received
- [ ] exact release published and verified
