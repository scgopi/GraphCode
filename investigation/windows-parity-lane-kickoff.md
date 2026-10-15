# Windows parity lane kickoff (canonical)

Every Windows parity worker reads this file. Read it from `origin/main`, in full, before
anything else.

## Two workers per issue: plan first, then implement

Each issue gets two workers, in order (operator decision, 2026-10-14):

1. **A planning worker** investigates the issue fully and writes the implementation plan.
   It doesn't change product code. Model: `gpt-6.1-sol`, high, long_context.
2. **The coordinator reviews the plan**, approves or corrects its file scope, and records the
   approval on the issue.
3. **An implementation worker** then executes the approved plan.
   - It doesn't redo the investigation.
   - When the plan turns out wrong, it says so: it sends the coordinator a lease-scope question,
     with the evidence. It doesn't improvise a different design.

### If you are the planning worker

Produce the plan from evidence, not memory. Read-only on the repository. Build,
test or desktop execution requires the per-issue command grant in Environment;
planning permission alone authorizes none of them.

1. **Read** the issue, its comments (including earlier attempts' findings), the ledger rows,
   the macOS captures and the macOS source.
2. **For every acceptance box**, write down:
   - the exact macOS behaviour, with `file:line`;
   - the current Windows behaviour, with `file:line`;
   - the gap and its root cause. Name the function and the reason; "looks wrong" is not a cause.
3. **Choose the slice** for the first PR: the primary defect first, small enough to review in
   one pass. List the boxes it closes and the boxes it leaves.
4. **Write the implementation steps**, each with:
   - the file and function to change;
   - the change itself;
   - the test that proves it. Name the test, its root file, its assertion, and what it shows
     on `main`, which is the expected RED.
5. **List the file scope** the implementation needs. Mark everything outside the lane's lease,
   so the coordinator can approve it up front.
6. **List the risks:**
   - shared files and other lanes' open PRs;
   - edits to the gate or harness;
   - DPI or theme interactions;
   - known environment traps (see "Environment" below).
7. **Rate the complexity:** `standard` or `highly complex`, with the reason. Highly complex means a new shared
   framework or mechanism used by many surfaces, or architecture spanning several lanes' files. The
   rating picks the implementer: `gpt-6-luna` for standard, `gpt-6.1-sol` for highly complex.
8. **List the evidence plan:**
   - the exact surfaces and states to capture;
   - the fixture data needed;
   - the macOS capture to pair each one with.
9. **Publish the plan** as one issue comment titled `Implementation plan (wave 2)`, using
   `gh issue comment`. Then message the coordinator `PLAN READY #<n>` with the comment URL.
   Don't start implementing.

### If you are the implementation worker

Your issue block links the **approved** plan. Follow it step by step; the gate below still
applies to every step. Record in the PR any deviation from the plan, with the reason.

The coordinator's kickoff message adds only an issue block:
- the issue number;
- the lane letter and session id (for example `c4`);
- the file lease;
- the implementer and reviewer models;
- any decisions already made.

Everything else is here, so lanes don't depend on hand-copied instructions.
This file was introduced after wave 1 (2026-10-14), where copied kickoffs drifted.
That drift caused validation roots that were too long, wrong `Refs` lines and
wrong reviewer models.

Read also:
- `AGENTS.md`;
- `investigation/windows-parity-orchestration-plan.md`, for the per-PR gate and the escalation rule;
- `investigation/ui-parity-matrix.md`, the ledger;
- the issue and its comments: `gh issue view <n> -R scgopi/GraphCode --comments`.

## Ground truth

The shipping macOS app is the reference. Match what macOS shows: information, actions,
layout, hierarchy, density, components, typography, spacing, colour and wording. Only
platform chrome may differ: the title bar, window buttons, menu-bar location and native
file pickers. Read the macOS **source** first (`graphcode/Sources/...`) and cite `file:line`;
captures confirm it. Don't add Windows-only extras. Don't remove a Windows action unless
the macOS path to the same result exists on Windows; if it doesn't, keep the action and
record it as a deliberate extra.

References on this machine:
- **Primary macOS reference:** the coordinator-provided, read-only ground-truth
  bundle from source `2ccf303a04f995184aae1d4b738a9eca0f71b79e`. Read its
  `README.md`, item index and complete privacy report before opening the applicable
  `@1x-srgb.png` images. `Recorded` is an observation, not a conformance verdict;
  `Exists, not recorded` is not absence. Match the actual selection and state.
  Fitted canvas pixels are not authored card dimensions or 100% zoom.
- **Publication hold:** consult the local notice
  `C:\gc-ref\macos-groundtruth-2ccf303a.DO-NOT-PUBLISH.txt` by path only; do not
  open or quote its contents. Held originals
  `issue-722\722-menus-split-round3@1x-srgb.png` and
  `issue-722\722-menus-split-round3@2x.png`: **NEVER open, copy or upload**.
  Every other image needs individual visual privacy
  clearance before upload. A sample review, correct masks or matching hashes do not
  clear unreviewed images, especially masked terminal captures.
- **Companion, not replacement:** `C:\gc-ref\macos-groundtruth-2ccf303a-gapfill-v2`,
  same source, adds exact empty-global/project, project/overview 100%, native
  Open Folder/Project Settings, inline Reclaim/Keep and Goal/Composite/menu
  splits. Retained metadata reports 543 files / 178 PNGs / 542 verified payload
  hashes / zero backend turns. Independent clearance covers only 11 sampled
  images; 167 unsampled remain independently uncleared. The thirty-row pairing
  worksheet records 6 sampled components / 3 recorded unsampled / 21 none;
  all 30 need current Windows evidence and none is promoted. The primary
  `764-final-fixtures-fitted` remains project 90%, not global/intrinsic 100%.
  Preserve the ledger's dated original intake, with this additive qualification.
- **Historical macOS fallback:** Run A is secondary, only for a state the primary
  lacks. Keep its source, fixture and evidence limits distinct.
- **Windows beta26 "before" captures:** `C:\GraphCode-DevBox-Return\media\`.
  Label them **Windows beta26 (pre-wave-1)**, not current main or a wave-2 head.
  They can support a historical pair; current behavior requires current evidence.
- **Side-by-side review:** `C:\gc-logs\visual-parity-review.md`.
- **macOS source audit:** `C:\gc-logs\parity-extras-audit.md`.
- **Privacy:** never upload or quote `734/*.zip` contents or `721-needs-you-chip-clicked`.

## Scope

The batched coordinator reconciliation records merged A/#808, E/#816, B/#814,
D/#815 and C/#817 source slices, not whole issue closure. #768/#778/#764/#774/#767
remain open, full B8/C6/D2/E4 criteria stay unchecked and B/C/D/E visual
acceptance is NotExecuted (#826). Preserve all 98 ledger identities/order and
**6 Validated / 89 Partial / 3 Out of scope**; thirty demoted rows stay Partial.
The orchestration plan's current execution/evidence authority governs J5,
parked adapters and the separately gated stock-only real-window route.

- **One issue, one PR, one coherent slice.** The first PR fixes the issue's primary
  defect. Leave remaining acceptance boxes unticked and list them. Small PRs merge;
  large ones loop through review.
- **Edit only your lane's files.** For anything else, send the coordinator the exact file,
  function and reason, and wait for approval.
- **`App.zig` is shared.** Keep edits narrow.

## Environment: do exactly this

**Execution admission overrides the examples below.** Every worker needs a
**per-issue exact local command allow-list** and **fresh owned roots** before
execution. Repository bootstrap/build/test examples are **not blanket permission**.
No local full `Tools\windows\Tests\ValidationRunner.Tests.ps1`,
no `validate.ps1 -Task windows-shell` unit/integration, and
no GraphCode/daemon/zmx/provider build or launch unless separately explicitly
granted. CI owns broad/native regression. Narrow harmless-process, offscreen
or capture exceptions remain separately reviewed and command-bound; they do
not authorize adjacent suites or general product execution.

No source changes in flight; keep failures immutable and positive executed
counts (zero-executed is not a pass). At five failures of the same kind, stop
and escalate to the operator; no owner rotation, root rename or reset without
an explicit user decision. Routine approval waits use a coordinator message and idle,
not a blocking `ask_user`. Check live `awaiting_input` before starting a capture
lease clock: message acceptance is not admitted permission.
No manual screenshots, screenshot/golden/pixel-baseline CI or fallback.
Unrelated-product PRs excluding all four capture-core files may receive at most
two failed-job reruns per exact head, globally across workflows, citing
[#826](https://github.com/scgopi/GraphCode/issues/826) and preserving failures.
The four files are `Tools\windows\UiCaptureDriver.psm1`,
`Tools\windows\Invoke-UiCaptureWorker.ps1`, `Tools\windows\Invoke-UiCapture.ps1`
and `Tools\windows\Tests\UiCaptureDriver.Tests.ps1`; core-changing repairs
do not get this exception.

The following root/tool setup applies **only when the exact commands are
separately granted**; do not bootstrap, seed or build merely to start a lane.
Replace `<id>` with your lane id, for example `c4`.

| What | Where |
| --- | --- |
| Scratch, logs, caches | `C:\gcs\<id>\` |
| Tools | `C:\gct\<id>\` |
| Providers | `C:\gcp\<id>\` |
| Validation root | `C:\gc<id>`: a real folder (not a junction), **7 characters at most** in total, because the UIA live-gate preflight has an 81-character path budget |

1. **Seed** Zig from `C:\gc-cache\zig\` into `C:\gct\<id>\`. Clone `winghostty` and `zmx` from
   `C:\gc-cache\git\*.git` into `C:\gcp\<id>\`. Check out the pins in
   `graphcode-windows/provider-pins.json`, and set `origin` to GitHub.
2. **Bootstrap:** `pwsh -NoProfile -File Tools\windows\bootstrap.ps1 -ToolRoot C:\gct\<id> -ProviderRoot C:\gcp\<id>`,
   then dot-source the `environment.ps1` it writes.
3. **Use pinned tools only:** `$env:GRAPHCODE_ZIG0152` and `$env:GRAPHCODE_SWIFT633`, never PATH.
   - For Zig, pass `--cache-dir` and `--global-cache-dir` under `C:\gcs\<id>`.
   - Set `TEMP` and `TMP` process-only.
   - Pester 5.7.1 is at `C:\v5modules`; prepend it to `PSModulePath` for that process only.
4. **Profiles and fixtures:**
   - Use a process-scoped scratch profile. A stale delete-pending
     `%LOCALAPPDATA%\GraphCode\zmx-validation-ee\logs\zmx.log` breaks the default-profile guard.
   - Seed `onboarding-seen` (and fixture data such as `quick-chats.json`) in the fixture's
     `GRAPHCODE_SUPPORT_DIR`, not under `LOCALAPPDATA`.
5. **Tests:**
   - A `--test-filter` that matches nothing exits 0. Quote the executed count, which must be positive.
   - Register new Zig test roots in `Tools/windows/Tests/WindowsShell.Tests.ps1`.
   - Hidden-window or native UIA labels do not exempt a command from admission;
     native suites belong to CI unless explicitly granted.
6. **GitHub, done by you.** Use the GitHub access described in your issue block. Account and credential details are
   deliberately not kept in this repository.
   - Push your branch and create one draft PR using the app-native PR tool.
     Report tool failure rather than silently switching creation paths.
     The coordinator owns admission, readiness and merge; do not self-approve.
   - Sign off every commit (`git commit -s`) and add the trailer
     `Co-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>`.
7. **Rebase hygiene:**
   - Rebase onto `origin/main` before every push.
   - After every rebase, read `git diff origin/main...HEAD`. Every hunk must be yours and
     intended. A conflict resolution that keeps your branch's copy of code another PR changed
     silently reverts that PR; wave 1 lost #789's geometry helpers this way.
8. **Shared gate script (`Tools/windows/uia-live-gate.ps1`):**
   - Edit it only with approval.
   - Assert on **named** elements; don't count broad sets. In wave 1 a canvas held loop cards,
     worktree cards and a banner.
   - Add positive and negative functional cases within an approved file lease.
     Full local ValidationRunner execution is not authorized by a script edit;
     any focused exception needs its exact command approved first.

## Order of work (the per-PR gate)

Report each step's result, or NotExecuted with the reason.

1. **Boxes.** Copy from the approved plan which acceptance boxes this PR satisfies and which it leaves.
2. **RED.**
   - Write the failing test first, and keep its output.
   - Layout criteria are testable as geometry: rects lie inside the client area and above
     the footer, text bounds come from the container, and nothing overlaps.
   - A compile error is not RED.
3. **GREEN.** Run only admitted focused commands and quote the positive executed count.
4. **Push a draft PR; exact-head CI owns broad/native regression.**
   - Execute locally only the approved exact allow-list. A focused root, script
     edit or hidden-window label grants no exception. No visual-baseline task.
   - Report nonempty exact-head run/job inventories and failures honestly.
     Configured path skips are not executed tests; a dispatch is not a PR check.
     Cite actual regression commands/results, not predicted CI outcomes.
5. **Code review.**
   - Start a `rubber-duck` agent with the reviewer model named in your issue block. It must be
     from a different vendor than you.
   - Give it the diff (`git diff origin/main...HEAD`), the PR body and the log paths.
   - It must open each log it cites, confirm every RED, GREEN and REGRESSION line, check that
     no unrelated file changed, and check the rebase diff.
   - Fix or answer every finding.
6. **Capture is gated, not an instruction to run.** Follow the orchestration
   plan's current #826/#822 authority. B/C/D/E visual acceptance is
   **NotExecuted (#826)**. A merged code slice is not visual acceptance.
   A later real-window route needs core merge, reviewed plan and exact commands;
   only an admitted dedicated LAST slot of at most 15 minutes may be used.
   No inherited lease, manual capture, automatic neighbouring-screen expansion
   or fallback follows this gate.
7. **Privacy review precedes paired visual review/publication.** Admitted actual
   images may undergo initial individual privacy review/scan. Paired visual
   review and publication use only individually privacy-cleared actual images;
   the held issue-722 originals remain NEVER open/copy/upload and outside scope.
   Visual review remains local and scoped, not CI. A different-vendor
   reviewer records the exact paired surfaces/criteria and leaves every
   unsupported box unticked. An offscreen result is
   **real paint path, offscreen component render**, not window, popup, native-control, terminal, input,
   accessibility, physical-input or persistence evidence. Its first scene hides
   the right panel; later surfaces need separate approval. Never bind historical
   pixels to current source using conversion-time hashes.
8. **Hand over.**
   - Fill in `.github/PULL_REQUEST_TEMPLATE.md`, add a **Not verified** list, and use `Refs #<n>`,
     never `Fixes`.
   - Check the body with `pwsh -NoProfile -File Tools\tdd\Test-TddEvidence.ps1 -BodyPath <file>`.
   - Message the coordinator with the draft PR URL, exact head and bounded
     evidence/NotExecuted summary. Wait idle for admission; don't mark ready or merge.

## Evidence honesty

- Say exactly what ran. Distinguish compile failures from behavioural ones, and injected
  input from physical input.
- A green build, unit test or UIA readback doesn't prove rendering, layout, input or parity.
- An empty result is not a pass.
- Keep failed attempts. Label harness failures separately from product failures.

## When it isn't working

- A failed iteration is one of:
  - a fix attempt after which the same test still fails;
  - a substantive review rejection;
  - an exact-head CI failure that you caused.
- After **5 failed iterations of the same kind**, stop and send `STUCK` with a handoff note:
  what you tried, the failing output, the reviewer findings, and what's worth keeping.
- Before that, iterate only within admitted commands. Waiting for approval,
  desktop, CI or review is not a failure; it grants no execution permission.

## Communication

Message the coordinator only for:
- `PLAN READY` (planning worker);
- `LEASE REQUEST` and `LEASE RELEASED`;
- a lease-scope question (outside-lane files or a scope decision);
- `STUCK`;
- `PR READY`.

Don't send progress messages.
