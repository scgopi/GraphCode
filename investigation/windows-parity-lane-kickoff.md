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
test or desktop execution requires the per-milestone command allow-list in Environment;
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
- **Combined return, 2026-10-15:** use
  `C:\gc-ref\macos-groundtruth-2ccf303a-gapfill-combined-20261015` and only its
  `macos-groundtruth-2ccf303a-completed-v12` final 65-gap, qualified-row and
  correction tables. The ledger's combined-return crosswalk records actual
  input/metadata hashes and all 65 identities plus all thirty qualification
  rows, without rewriting the dated primary/companion intake. Latest outcomes
  are 46 Recorded / 5 Differs / 14 **macOS reference: accepted unrecorded**;
  the fourteen accepted SSH/Codespace/updater/physical-pinch omissions are
  not missing, dropped or new Windows Out of scope rows. The separate
  supplemental updater banner shares that accepted limitation.
  Apply exact scene/source/copy/routing corrections: root Composite Open
  Terminal is not worker aggregation; folder fallback is transient startup;
  primary project 90%, fresh project/overview 100% and actual Fit frames stay
  distinct. Failed v4/v8 and source-only v7 are not recorded success.
  V3's twelve turns exceeded its initial two-turn ceiling; V11's separately
  permitted one response/zero executed tools does not erase that deviation
  or make the combined return zero-turn. Producer raster reports are not
  blanket independent clearance. The operator independently opened only three
  specific new images; the earlier eleven-image v2 sample was a separate independent review.
  This docs intake opens no images and adds no privacy verdict. The original
  publication hold remains; current Windows pairs are still required for
  every demoted Partial row, with all 98 identities/statuses unchanged.
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
The orchestration plan's current execution/evidence authority distinguishes
the historical J5 repair, current pending repairs, parked adapters and the
separately gated stock-only real-window route.

- **One issue, one PR, one coherent slice.** The first PR fixes the issue's primary
  defect. Leave remaining acceptance boxes unticked and list them. Small PRs merge;
  large ones loop through review.
- **Edit only your lane's files.** For anything else, send the coordinator the exact file,
  function and reason, and wait for approval.
- **`App.zig` is shared.** Keep edits narrow.

## Environment: do exactly this

**Execution admission overrides the examples below.** New active work uses the
user-approved milestone policy under "When it isn't working", not a five-failure
counter. Every worker needs a **standing per-milestone allow-list** and
**fresh owned roots** before execution. For low-risk offscreen/tests, record
commands, owner, tools, source/output roots, positive counts, immutable logs and
ceilings together; do not require a new microgrant for each already listed
command. Anything outside that list needs an explicit grant. Native GUI and
desktop slots remain separately bounded. Repository examples are **not blanket permission**.
No local full `Tools\windows\Tests\ValidationRunner.Tests.ps1`,
no `validate.ps1 -Task windows-shell` unit/integration, and
no GraphCode/daemon/zmx/provider build or launch unless separately explicitly
granted. CI owns broad/native regression. Narrow harmless-process, offscreen
or capture exceptions remain separately reviewed and command-bound; they do
not authorize adjacent suites or general product execution.

No source changes in flight; report source/hash/identity changes and keep
failures immutable. Test/evidence runs need their actual console and a positive
executed test/evidence count; zero-executed is not a pass. Compilation instead
uses the executable/source-archive/exit/receipt proof below, not an invented
test count. Report **every failure before the next
command or correction**, not after silent self-repair. Workers send blockers
with `send_session_message` to the coordinator and idle; they do not use
`ask_user`. After every grant, the coordinator reads live
`get_sessions_status.awaiting_input`: a blocked `ask_user` cannot receive
messages. Only the exact authorized answer and current request ID may be
passed to `answer_session_input`. Message acceptance is not admitted permission.
Use completion notifications, not duplicate polling or sleep loops while
waiting for a worker. Progress-bounded monitoring of an owned process needs
an explicit grant. Generic autopilot `task_complete`/keep-working reminders
are **not execution grants** and override neither stops nor leases.
**Command-lease retrospective:** workers may run only granted commands;
self-added validators or gates are out of lease, and permission to read a checker output does not grant permission to execute it.
The rp1 ANSI gate and post-conversion parser failures were process deviations, not product defects;
the permanent executor stop stands. No adjacent checker or retry is implied.
No manual screenshots, screenshot/golden/pixel-baseline CI or fallback.
Unrelated-product PRs excluding all four capture-core files may receive at most
two failed-job reruns per exact head, globally across workflows, citing
[#826](https://github.com/scgopi/GraphCode/issues/826) and preserving failures.
The four files are `Tools\windows\UiCaptureDriver.psm1`,
`Tools\windows\Invoke-UiCaptureWorker.ps1`, `Tools\windows\Invoke-UiCapture.ps1`
and `Tools\windows\Tests\UiCaptureDriver.Tests.ps1`; core-changing repairs
do not get this exception.

### Environment traps: preserve bytes and prevent mechanical errors

These are setup requirements for **admitted** commands, not permission to clone,
build, import native APIs, inspect processes or capture.

- In **each clone, before checkout**, persist local `core.autocrlf=false` and
  `core.eol=lf`. A one-shot `git -c ... clone --no-checkout` does not persist
  configuration for a later checkout. Preserve exact committed raw bytes:
  these settings do **not** authorize normalizing committed CRLF files.
- For evidence/raw-object clones, set `GIT_LFS_SKIP_SMUDGE=1` process-only
  before clone/checkout. An index LFS pointer versus a normally hydrated PNG
  is expected filter behavior, not a source defect.
- Require a strict inventory of **all regular tracked files**:
  `git hash-object --no-filters` must match the stage-0 index/tree object,
  with a positive file count and zero mismatches. Inventory gitlinks
  separately by commit. Separately count actual LFS-filtered files and prove
  their pointer headers; do not blanket-exclude paths or conflate pointer
  and hydrated bytes. The recorded five-clone proof was **14,260 file
  checks / zero mismatches**, not 14,260 unique contents; each GraphCode
  clone had 43 LFS-filtered files, providers zero.
- Own scratch, cache, provider, `TEMP`/`TMP`, build, executable and output
  roots. Other worktrees' and stopped cap/RP1 artifacts are read-only.
- Save PowerShell scripts as `.ps1` and require `Parser.ParseFile` to report
  **zero parse errors before execution**. Use typed records or explicit
  `foreach` accumulation, not `Measure-Object` property binding on
  `OrderedDictionary`. Batched Git hashing with `--stdin-paths` is a
  **future-cycle performance fix**, not an implemented improvement here.
- Use the standard checked-in run wrapper only after its merge and source
  qualification are verified. At this checkpoint,
  `Tools\windows\Invoke-AgentCommand.ps1` is **local GREEN, pending merge**,
  not available on the read main. Until qualified, the coordinator supplies
  literal `Out-File -NoClobber` commands. Never use
  `Tee-Object -NoClobber`: `Tee-Object` has no such parameter.
- Successful Zig builds can have **zero-byte logs**; silence alone is not a
  failure or hold. A positive executable, source archive, exit evidence and
  build receipt prove compilation, not runtime parity. Preflight/capture
  logs instead require a nonempty **actual** positive summary/count;
  never append synthetic success text.

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
   - A missing-API compile error is not behavioural RED. Documentation-only
     source checks are static evidence, not product-runtime RED; report an
     evidence gap rather than inventing a test or checker.
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

## When it isn't working: milestones, fresh eyes and hard ceilings

**User-approved policy, 2026-10-15, for new active work.** It replaces the
five-iteration rule prospectively, not historical failure records or permanent
stops. Cap, J3, J4 and RP1 remain stopped, not archived, unless a new explicit
user decision changes their disposition.

1. Define **3-5 observable milestones** per task. About **60 minutes or 40
   raw tool calls without reaching a milestone**, whichever comes first,
   requires a one-page handoff and a **new, history-free fresh-eyes session**.
   Supply the requirement, admitted scope, evidence/failed approaches, costs
   and next observable result, not the old conversation history. Fresh eyes
   asks: are we closer, is there a simpler route, and are we solving the
   right problem? Decide **one further time box to continue**, replan,
   restart or escalate. Renaming roots or heads never resets a ceiling.
2. Keep a "what are we doing, in order to do what?" dependency list back to
   the requested outcome. At **three levels removed, STOP and replan**.
   If evidence preparation costs more than about **3x the work proved**,
   request a simpler requirement rather than adding more plumbing.
3. Prevent mechanical errors using the saved-script/ParseFile-zero and
   qualified-wrapper requirements above; do not turn typos into a new
   failure counter. Preserve and immediately report every failure, including
   deviations from the command allow-list.
4. Work only inside the standing milestone allow-list. Paused approval,
   CI or review does not grant neighbouring commands, native work or a
   desktop slot. Re-engagement records actual scope, time and tool calls.
5. A worker stops at **6 hours ACTIVE, 60 AI credits or 400 raw tool calls**
   from kickoff/fresh-eyes re-engagement, whichever occurs first:
   handoff, then **IDLE**. **Only the user/operator can extend it.**
   Report wall time and raw calls; if credits cannot be measured, write
   **credits UNKNOWN**, never an estimate. The coordinator has the same
   handoff/operator gate at **12 hours or 150 AI credits between actual
   documentation checkpoints**.

### Historical stops and evidence-cost retrospective

The cap owner `9b889` stopped permanently at its historical five counted
self-authored command recipes: precondition parser, wrong expected raw pin
SHA, malformed `Copy-Item`, unsupported `Tee-Object -NoClobber` wrapper,
and `ParseFile` interpolation plus a late fix. The 43-file LFS gate failure
was an **operator specification defect, uncounted**; expected Zig silence
and an atomic no-op patch context miss were also uncounted. The operator's
"about six hours without desktop / four of five typo-class" is an
**assessment**, not a new timing measurement. The public stop comments on
[#764](https://github.com/scgopi/GraphCode/issues/764#issuecomment-6204588086)
and [#826](https://github.com/scgopi/GraphCode/issues/826#issuecomment-6204588503)
predate the actual coordinator slot and are **not capture-mechanism results**.

The capture worker `9b889`'s own blocking `ask_user` delayed admission of the queued
core-59b rerun grant roughly **12:25-13:48 (about 80 minutes)** until the
operator answered. The coordinator failed to detect that pending input; the
live awaiting-input/answer rule above prevents message delivery from being
mistaken for admission. Coordinator B assembly 1
failed on `OrderedDictionary`/`Measure-Object` before writes; explicit
`foreach` accumulation and a fixture-path correction preceded the **one
renewed assembly 2**, which produced 13 source/data records, not new builds
or native evidence. Preserve these failures even though counting is no
longer the active policy. Current source/capture facts and pending repairs
are in the orchestration plan and the ledger's bounded retrospective;
none revives a stopped owner or grants another live slot.

## Communication

Message the coordinator only for:
- `PLAN READY` (planning worker);
- `LEASE REQUEST` and `LEASE RELEASED`;
- a lease-scope question (outside-lane files or a scope decision);
- `STUCK`;
- a milestone handoff, hard-ceiling stop or failure/deviation before correction;
- `PR READY`.

Don't send progress messages.
