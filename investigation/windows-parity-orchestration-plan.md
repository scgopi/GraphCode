# Windows parity: orchestration plan

This is the working plan for closing the Windows parity gaps quickly, without the
regressions and overclaimed evidence of earlier iterations. It covers how the
work is split, which models run each role, and how every change is reviewed and
tested before it merges.

The ledger, [ui-parity-matrix.md](ui-parity-matrix.md), stays the source of
truth for status. The issues carry the acceptance criteria and the priority.

## Ground rules (decided 2026-10-13)

- **macOS is the ground truth.** A requirement macOS does not have is not
  parity. Such items have been narrowed or closed, and anything still in doubt
  goes to the next macOS ground-truth capture.
- **Visual fidelity is part of parity.** Layout, hierarchy, density,
  components, typography, spacing, colour and wording must match the macOS
  capture. Only platform chrome may differ.
- **Priority order:**
  1. **`P1 layout`**: broken or messy layout, clipping, overlap and wrong
     content.
  2. **`P2 feature`**: macOS features Windows lacks.
  3. **`P3 polish`**: fonts, anti-aliasing, palette and general polish.

  Within a priority, foundations come first (shared frameworks before the
  screens that use them).
- **One session = one issue = one PR.**

## Wave 1 (started 2026-10-13)

| Lane | Issue | Model |
| --- | --- | --- |
| A | #768 | `gpt-6.1-sol`, high, long_context; STUCK at 23:27 (the capture harness failed 4 times), escalated to `claude-sonnet-5.5`, xhigh, long_context; 2nd escalation on 2026-10-14 at 02:45 (2 substantive rubber-duck rejections) to `claude-opus-5.5`, max, long_context |
| B | #773 | `gpt-5.4-mini`, high; escalated at 22:50 to `gpt-6.1-sol`, high, long_context (#789 merged; now on #764); #764 escalated on 2026-10-14 at 04:45 (2 substantive code-review rejections) to `claude-sonnet-5.5`, xhigh, long_context |
| C | #767 | `gpt-6.1-sol`, high, long_context; PR #800 escalated on 2026-10-14 at 04:53 (2 session-caused exact-head CI failures) to `claude-sonnet-5.5`, xhigh, long_context |
| D | #774 | `gpt-5.4-mini`, high; switched at 23:25 to `gpt-6-luna`, high (operator decision) |
| E | #776 | `gpt-6.1-sol`, high, long_context (#788 merged); follow-up PR #792 escalated on 2026-10-14 at 02:50 (2 substantive source-review rejections of the scrollbar hover fix) to `claude-sonnet-5.5`, xhigh, long_context |

**Wave 1 outcome (closed 2026-10-14 at 07:40).**
- **Merged:** #788 and #792 (jump palette, #776 closed) and #789 (right loop
  panel, #773).
- **Stopped by operator decision and restarted under the fixes below:** #768,
  #764, #767 (PR #800), #774 (PR #787) and #778. Their PRs were closed unmerged,
  their branches deleted, and their findings kept on the issues.

**What went wrong, and the fix for each:**

| Cause | Fix |
| --- | --- |
| Every lane's full unit and integration runs went through the one desktop, and were re-run each time a head moved. The queue dominated elapsed time. | Exact-head CI owns broad/native regression. Historical screenshot-slot instructions are superseded by the execution/capture gates below. |
| Escalation thresholds of 2 or 3 restarted sessions, which lost bootstrap, builds and context. Every lane escalated at least once. | Escalate only after 5 failed iterations (operator decision; see "Abandon and escalate"). |
| Kickoffs were hand-copied per lane, and drifted: an 8-character validation root that failed the 81-character preflight, a wrong `Refs` line, the wrong reviewer model. | One canonical kickoff, `investigation/windows-parity-lane-kickoff.md`. The coordinator sends only an issue block. |
| Environment traps were rediscovered lane by lane: a junction root, the root length, a stale profile log, `onboarding-seen`, `CopyFromScreen` capturing the wrong app, the `ActivateWindow` Alt tap (#797), `zmx` daemons left running, `vcvars`, the PR tool failing on forks. | They are listed once, in the kickoff's "Environment" section. |
| The coordinator relayed every PR creation and body edit. | Lanes create and edit their own PRs, using the access details in their issue block (not kept in the repository). |
| A rebase conflict resolution silently reverted #789's geometry helpers. | After each rebase, the lane and its reviewer read `git diff origin/main...HEAD`. |
| Broad new assertions in `uia-live-gate.ps1` (counting every canvas card) failed CI twice. | Gate edits assert on named elements, with scoped contract cases; full local ValidationRunner is no longer authorized by a script edit. |
| Screenshots were taken before review, then retaken after each fix. | Review first; any future capture requires separate admission. Manual screenshots and visual CI were canceled. |

**Coordinator rules (added 2026-10-14):**
- **Verify before ruling.** Check a scope or parity ruling against the macOS
  source before sending it. Two wave-1 rulings were reversed (a historical
  baseline pin, and a Restart button macOS does show).
- **Do not treat a harness edit as execution permission.** #802 merged with a
  known local failure, and #805 had to fix it. A local reproduction now needs a
  per-issue exact command grant; CI owns broad/native regression.
- **Answer actionable lane messages promptly.** Routine approval waits use
  message plus idle. Check live awaiting-input and execution admission before a
  lease clock; delivery of a grant is not evidence that it was admitted.

## Wave 2 (started 2026-10-14)

Every worker uses `investigation/windows-parity-lane-kickoff.md`. Each issue goes
through four steps:

1. **Plan.** A planning worker (`gpt-6.1-sol`, high) investigates the issue and
   publishes `Implementation plan (wave 2)` on it. It doesn't edit product code or
   use the desktop.
2. **Approve.** The coordinator checks the plan against the macOS source,
   approves its file scope (including any out-of-lease files, up front), and
   records `Plan approved` on the issue.
3. **Implement.** An implementation worker (`gpt-6-luna`, high; `gpt-6.1-sol`, high, long_context, for highly complex features) executes the approved plan under the
   per-PR gate and exact command allow-list. CI owns broad/native regression;
   capture is separately gated, and five failures trigger an operator stop.
4. **Merge.** The coordinator owns admission/readiness/merge on accepted source
   review and exact-head CI, explicitly recording any deferred visual criteria.
   A code-slice merge does not close those criteria.

Planning runs in parallel for all lanes. Implementation stays one per lane.

| Lane | Issue | Planner | Implementer | Reviewer |
| --- | --- | --- | --- | --- |

### Current execution and evidence authority

Every worker needs a **per-issue exact local command allow-list** and
**fresh owned roots** before execution. Repository bootstrap/build/test examples
are **not blanket permission**. No local full `Tools\windows\Tests\ValidationRunner.Tests.ps1`,
no `validate.ps1 -Task windows-shell` unit/integration, and
no GraphCode/daemon/zmx/provider build or launch unless separately explicitly
granted. CI owns broad/native regression. Narrow harmless-process/offscreen/
capture exceptions remain separately reviewed and command-bound.

No source changes in flight; keep failures immutable. Zero-executed is not a
pass. At five failures of the same kind, stop for the operator;
no owner rotation, root rename or reset without an explicit user decision. Routine approval waits
use a coordinator message and idle, not blocking `ask_user`. Check live
`awaiting_input` before starting any capture lease clock:
message acceptance is not admitted permission.
No manual screenshots, screenshot/golden/pixel-baseline CI
or fallback. No automatically granted local execution follows a green workflow.

For unrelated-product PRs excluding `Tools\windows\UiCaptureDriver.psm1`,
`Tools\windows\Invoke-UiCaptureWorker.ps1`, `Tools\windows\Invoke-UiCapture.ps1`
and `Tools\windows\Tests\UiCaptureDriver.Tests.ps1`, the #826 exception permits
at most **two failed-job reruns per exact head, globally across workflows**,
citing #826 and preserving the original failures. **Core-changing repairs do
not get this exception.**

**Capture core.** [#826](https://github.com/scgopi/GraphCode/issues/826) remains
open, no longer under its former blocked-title/no-new-owner ruling. The
[explicit user override](https://github.com/scgopi/GraphCode/issues/826#issuecomment-6186430845)
appoints J5 (GPT-6.1 Sol/high) as sole owner of only the two Phase A fixture
defects: validAbsentWQL and StrictMode whole-array wrapping, with a fresh
five-failure budget. Phase A requires accepted static review, the exact positive
5-case decision driver followed by the 51-case direct suite (original 49 plus
2), and accepted current-head CI. Execution commands remain separately granted;
these gates are not worker-progress or runtime-acceptance claims.
This is not authority for other edits. J4's fifth failure
(**5 executed / 3 passed / 2 failed**) stays frozen historical evidence, not an
accepted lifecycle repair. The pure 12-row decision matrix and three mutant
distinctions are not a full endpoint pass. Phase B immutable numbered journal
work may be planned only after Phase A review plus green CI is accepted, then
requires its own plan/review before implementation. Cap and the D adapter stay
parked until #826 merges and explicit ordered resumption; no automatic capture
authority follows a core merge.

**Offscreen route.** The seven-file first project scene requires controlled
post-C source freeze/review, separate exact native, codec and converter grants,
and an actual source-bound run. It is **real paint path, offscreen component render**:
two idle cards, one edge, 1280x720; the first scene hides the right panel.
Admitted actual images may undergo individual privacy review; claims require
individually privacy-cleared actual images and different-vendor paired review.
Actual artifact status is linked from the [issue/receipt](https://github.com/scgopi/GraphCode/issues/822),
not hardcoded as worker progress here. No PNG/pass or current whole visual/parity
acceptance is predicted or established by this policy.
Only actual in-frame card/edge/panel/layout pixels can support a later scoped
claim, never window/composition, popups, terminal, native controls, input,
accessibility, physical input or persistence. Do not rebind old dirty
`4fafbfb2` pixels with conversion-time current hashes. Sidebar, right-panel and
NativeForms slices need separate later approvals after the first proves out.

**Selected real-window option 1: stock-only route, execution separately gated.**
The [earlier proposal](https://github.com/scgopi/GraphCode/issues/822#issuecomment-6186605912)
records route provenance, not execution authority. The selected route requires
#826 merge, an accepted current plan and separate exact implementation, native,
install and capture grants. A reviewed plan alone is not an execution lease;
ungranted execution is **UNAPPROVED**. The operator steer prohibits any fork,
patch or derivative of WinAppCli or another external
repository: **stock pinned WinAppCli 0.5.0 only**. Restore/foreground are
acceptable and must be recorded inside the dedicated **LAST, at most 15-minute**
desktop slot when explicitly granted; they are not forbidden in that route.
Backend may remain unattested. Correct-pixel fallback may be admitted only
with all postchecks: per-capture success, target DWM-frame dimensions within
DPI rounding, a single window with no non-target owned popups/composite,
nonblank variance, unchanged pre/post roster and identity, privacy review and
then local vision review. Variance proves neither backend nor absence of fallback.
The first proposed slice is only the GraphCode main window plus authentic Clone
dialog, with minimal GraphCode profile generalisation only if source hardcodes
require it. No implementation, install, probe or execution before #826 merges,
plan review and explicit new commands. Menus retain semantic HMENU evidence;
terminal/tray remain deferred. This is not a new visual CI or manual-capture grant.

**Merged slices, deferred claims.** A/#808, E/#816, B/#814, D/#815 and C/#817
are all merged; accepted main for this reconciliation is
`24209d2a70efee78be2a8214edf013e9b787ccd0`. The ledger's merged-slice table
records their exact merges and bounded source progress. #768/#778/#764/#774/#767
remain open; full B8/C6/D2/E4 criteria stay unchecked, and B/C/D/E visual
acceptance is NotExecuted (#826). A's historical 26 assets are text-prompt
evidence, not a NativeForms/policy-overflow repair. The 98 canonical identities,
order and statuses remain **6 Validated / 89 Partial / 3 Out of scope**, including
all thirty demoted rows still Partial. No worker may promote rows from code,
unit/UIA/native-menu/offscreen capability or macOS-only references.

**Short validation root.** The UIA live-gate preflight refuses sandbox paths
longer than 81 UTF-16 characters, and `validate.ps1` appends
`<GUID>\temp\gu-<GUID>` to the root. Pass `-ShellValidationRoot C:\gc<lane>`,
where `C:\gc<lane>` is a **real** directory owned by the lane and **at most 7
characters** long (for example `C:\gcc2`). `C:\gc-c` passed and `C:\gc-c2` failed by
one character on 2026-10-14. Do **not**
use a junction. A junction makes fixture paths differ between the alias and the
resolved path. That breaks the `WorktreeGitProcess` unit fixtures, and very
probably caused local `ScrubbedShellStartup` `registered-project` failures that
exact-head CI did not reproduce.

**CI and desktop separation.** Hosted exact-head workflows own broad/native
regression. Report a nonempty run/job inventory, actual positive executed counts
and configured skips separately; a manual dispatch is not a PR required check.
Some App/WindowsNativeDialogs unit roots show or focus windows: "unit" or
"hidden" does not establish harmlessness or authorize local execution.
Only the separately admitted final capture route can consume a desktop slot;
the old screenshot queue does not grant a lease.

**Historical capture environment notes, not execution permission.**
- Seed `onboarding-seen` in the fixture's `GRAPHCODE_SUPPORT_DIR`;
  `WindowsOnboarding.Store` reads it there, not from `LOCALAPPDATA`.
- Windows Sandbox clamps the guest screen to about 1520x823 and failed
  `EnumDisplaySettings` with vGPU disabled. Use it for clean-install and
  first-run flows, not for 1440x900 visual captures.

**Creating PRs.** Workers create one draft with the app-native PR tool and the
complete repository template; report failure rather than switching creation
paths. The coordinator owns readiness, admission and merge. Access details
remain outside the repository.

**Provider checkouts, only when command-granted.** Seed `winghostty` and `zmx` under the lane's
`-ProviderRoot` from the read-only local mirrors in `C:\gc-cache\git\*.git`.
Check out the pinned commit, point `origin` back at GitHub, then run
bootstrap: it verifies the pin.

**Toolchain, only when command-granted.** Each session bootstraps its own tool, provider and scratch
roots: `C:\gct\<lane>`, `C:\gcp\<lane>` and `C:\gcs\<lane>`. To skip the
slow Zig download, seed the tool root from the checksum-verified, read-only
cache in `C:\gc-cache\zig`.

## Work queue

### P1 layout (wave 1)

| Order | Issue | Surface | Lane |
| --- | --- | --- | --- |
| 1 | [#768](https://github.com/scgopi/GraphCode/issues/768) | Dialog/sheet framework: size to content, never clip (absorbs #760) | A |
| 2 | [#773](https://github.com/scgopi/GraphCode/issues/773) | Right loop panel: text cut at fixed x=1200 (`GraphCanvas.zig:2308`) | B |
| 3 | [#774](https://github.com/scgopi/GraphCode/issues/774) | Quick Chat workspace shows the previous loop's bar and panel | D |
| 4 | [#764](https://github.com/scgopi/GraphCode/issues/764) | Canvas loop cards: layout, pills, roles, colours, flow layout | B |
| 5 | [#765](https://github.com/scgopi/GraphCode/issues/765) | Edges quiet at rest, never over cards (absorbs #759) | B |
| 6 | [#766](https://github.com/scgopi/GraphCode/issues/766) | Attention rail, toolbar chips, status line (absorbs #761) | B (the rail draws in `GraphCanvas.zig`) |
| 7 | [#767](https://github.com/scgopi/GraphCode/issues/767) | Sidebar tree and window layout, 452 pt minimum width | C |
| 8 | [#776](https://github.com/scgopi/GraphCode/issues/776) | Jump palette in-window and dark | E |
| 9 | [#777](https://github.com/scgopi/GraphCode/issues/777) | Worktrees sheet grouped layout, no clipping | A |

Row trackers that close as these land: #720, #721, #727, #728 and #740.

### P2 feature (wave 2; may start in lanes that P1 has freed)

| Issue | Surface | Lane |
| --- | --- | --- |
| [#769](https://github.com/scgopi/GraphCode/issues/769) | New Loop sheet per type (Main, Templates, Test, chips, cadence, composite steps) | A |
| [#778](https://github.com/scgopi/GraphCode/issues/778) | Context-menu item set (Export/Import, Change to…, edge header) | E |
| [#722](https://github.com/scgopi/GraphCode/issues/722) | Missing menu commands and enablement | E |
| [#771](https://github.com/scgopi/GraphCode/issues/771) | Settings structure (agents, Templates) | A |
| [#772](https://github.com/scgopi/GraphCode/issues/772) | Loop workspace chrome (loop bar, tabs, split controls, pane headers) | D |
| [#770](https://github.com/scgopi/GraphCode/issues/770) | Edge form uses titles, not GUIDs; Edit Details decision | A |
| [#779](https://github.com/scgopi/GraphCode/issues/779) | Fifth onboarding page | E |
| [#780](https://github.com/scgopi/GraphCode/issues/780) | Update: "Other workspaces are open" check | E |
| [#758](https://github.com/scgopi/GraphCode/issues/758) | Leftover `.GraphCode-rollback-*` after an in-app update | F |
| #723, #724, #726, #730, #732, #734, #736, #745, #746, #748 | Remaining implementation gaps (each narrowed to macOS scope) | per surface |
| #556, #729, #733, #735, #739, #742, #743, #744 | Testing gaps: verification only, lane F | F |

### P3 polish (wave 3)

[#775](https://github.com/scgopi/GraphCode/issues/775) (terminal look),
[#781](https://github.com/scgopi/GraphCode/issues/781) (grid and zoom metrics),
#750, #751, #752 and #753.

### Hardware only (not on the critical path)

#726 (touchpad and touch) and #749 (mixed-DPI monitors) need physical hardware.
They don't need a Dev Box.

## Lanes (parallel) and file leases

Agents collide when they edit the same large files at the same time, so lanes
are cut by file ownership. Within a lane, work is **sequential**; across lanes
it is **parallel**. A session may touch another lane's files only with a narrow,
named change agreed by the coordinator, and must rebase immediately before its
PR.

| Lane | Owns | Notes |
| --- | --- | --- |
| A: Forms and dialogs | `NativeForms.zig`, `Forms.zig`, `WindowsNativeDialogs.zig`, `WindowsProductSettings.zig` | #768 first; every later form builds on it |
| B: Canvas | `GraphCanvas.zig`, `DesignTokens.zig` | #773, then #764, then #765, then #766, then #781 |
| C: Sidebar and window | `Sidebar.zig`; the window procedure and min-size handling in `App.zig` | #767; the toolbar-chip part of #766 needs a narrow, coordinator-approved edit |
| D: Workspace and terminal chrome | `TerminalSurface.zig`; workspace layout code in `App.zig` | #774, then #772, then #775 |
| E: Menus and commands | `GraphContextMenu.zig`, `JumpPalette.zig`, `WindowsOnboarding.zig`; menu construction in `App.zig` | #776, then #778, then #722, then #779, then #780 |
| F: Verification | no product files | Sandbox runs, testing gaps and candidate qualification |

At most **five implementation sessions** run at once: one per lane A–E. Lane F
runs as a single session, because only **one Windows Sandbox can run per host**
(see Local testing).

## Model selection

These choices come from a model survey (published benchmarks, prices and
context sizes as of October 2026). They aim at the **cheapest, fastest model
that does the job**, they are not Anthropic-only, and the reviewer is always
from a **different vendor** than the implementer, so the two don't share blind
spots.

| Role | Model, effort, context | Fallback | Why |
| --- | --- | --- | --- |
| **Investigation and planning (every issue, before implementation)** | `gpt-6.1-sol`, high, long_context | `gpt-6-sol`, high, long_context | Operator decision (2026-10-14): a separate high-reasoning worker investigates each issue and writes the implementation plan (see `investigation/windows-parity-lane-kickoff.md`), so the implementer executes a reviewed design instead of discovering it under the per-PR gate. |
| **Implementation (default)**: every issue unless the plan rates it highly complex | `gpt-6-luna`, high, default | `gpt-5.6-luna`, high (operator-chosen fallback) | Operator decision (2026-10-14). With an approved plan from a high-reasoning planner, the implementer executes a reviewed design, so the fast model is the default. Wave 1 used it unplanned on #774. |
| **Implementation (highly complex features)**: new shared frameworks or mechanisms used by many surfaces, or architecture spanning several lanes' files (for example #768) | `gpt-6.1-sol`, high, **long_context** | `claude-sonnet-5.5`, high, long_context | Operator decision (2026-10-14). The coordinator records the complexity rating and the model choice in the issue's `Plan approved` comment. A 1.05M-token window suits `App.zig`-scale files. |
| Polish (P3) | `mai-code-1.1-flash`, medium, default | `claude-haiku-5.5`, medium | The cheapest model with a published coding score and a screenshot-to-code benchmark. |
| Rubber-duck review (code and evidence) | `claude-sonnet-5.5`, high, default | `grok-4.7`, high | A different vendor from the OpenAI implementers. If an Anthropic model implemented the change, review it with `grok-4.7` or `gpt-6.1-sol`. |
| Visual sign-off (paired screenshots) | `claude-sonnet-5.5`, high, default | `claude-opus-4.8`, high, only if Sonnet's verdict is disputed | Must open every image it cites. Opus 4.8 has the best-documented vision, but costs more. |
| Test runs and reporting | `claude-haiku-5.5`, low (medium when results are contested) | `gpt-5-mini`, low | Mechanical execution with very large logs. It must quote raw output, not summarise success. |
| Coordinator | `gpt-6.1-sol`, high, long_context | — | Operator decision (2026-10-14). Owns the ledger, merges, file leases, plan approvals and the desktop queue. |

**Calibrate before scaling.** Run one P1 issue per implementation model first,
and measure:
- the CI first-pass rate;
- the number of reviewer findings;
- the rework rounds.

Promote or demote models on that data, not on benchmarks alone.

### Abandon and escalate a struggling session

Escalating restarts the work in a new session: bootstrap, provider builds and
context are lost, and in wave 1 that restart cost more than the iterations it
saved. Every lane escalated at least once on thresholds of 2 or 3, and three
product PRs merged in about ten hours. So, by **operator decision**
(2026-10-14), a session is abandoned **only after 5 failed iterations** of the
same kind:

| Trigger (each counts as one failed iteration) | Threshold |
| --- | --- |
| The same RED test or validation step still fails after a fix attempt | 5 attempts |
| The rubber duck or the visual sign-off rejects the PR with substantive findings (not wording) | 5 rejections |
| Exact-head CI fails for a reason the session caused | 5 times |

This threshold is a **stop/operator gate**, not permission to rotate owners or
reset roots/counters. The following handoff procedure requires an explicit user
decision before appointing a replacement; it does not automatically restart work.

Everything else is **corrected in place, not escalated**:
- A contradicted evidence claim (overclaiming) is fixed in the PR body, and the
  reviewer re-checks it.
- An edit outside the lane lease is reverted or approved.
- A long idle or busy period gets a status question from the coordinator, not a
  restart. Waiting for the desktop, CI or review doesn't count as a failed
  iteration.

**Abandoning is not deleting.** The coordinator:
1. stops the session and keeps its branch and evidence;
2. closes any open PR it made, unmerged, with a short "superseded by" note;
3. writes a **handoff note** on the issue, covering:
   - what was tried, and which approaches failed and why;
   - the failing test and its output;
   - the reviewer's findings;
   - any parts of the diff worth keeping;
4. starts a **new session** with a fresh branch from current `main`, the
   handoff note in its kickoff, and the **next model on the escalation ladder**.

The new session may reuse the old branch's commits only by deliberately
cherry-picking them, and must name them in its PR.

**Escalation ladder** (for implementation; reviewers stay a different vendor
from the implementer at every step):

| Step | Small, well-scoped fixes | Lane implementation and polish |
| --- | --- | --- |
| Start | `gpt-6-luna`, high | `gpt-6.1-sol`, high, long_context (polish: `mai-code-1.1-flash`, medium) |
| 1st escalation | `gpt-5.6-luna`, high (operator-chosen fallback) | `claude-sonnet-5.5`, xhigh, long_context |
| 2nd escalation | `gpt-6.1-sol`, high | `claude-opus-5.5`, max, long_context |
| 3rd escalation | `claude-sonnet-5.5`, xhigh | `gpt-5.6-sol`, max, long_context (or `claude-opus-4.8` when the work is mainly visual) |
| After that | Stop. The coordinator escalates the issue to the operator, with all the handoff notes. It is probably mis-specified or needs a design decision. | Same |

**Reviewer for each step.** When the implementer is an Anthropic model, review
with `gpt-6.1-sol` at high effort, or with `grok-4.7`.

**Record every escalation** in the issue (old model, trigger, new model) and in
the calibration data. A model that needs escalating on two issues in the same
lane is demoted for that lane.

## Per-PR gate (mandatory)

Every implementation session follows these steps in order. A step that can't be
done is reported as **NotExecuted** with the reason; it is never skipped
silently.

1. **Read the macOS reference first:** the issue's acceptance criteria and the
   paired macOS capture. Write down which boxes this PR will satisfy and which
   it won't.
2. **RED.** Where the requirement is testable in code, write a failing test
   first, and keep the failing output. Layout criteria are testable as geometry:
   - every control's rect lies inside the client area and above the footer;
   - text bounds come from the container, not a constant;
   - no two control rects overlap.

   Use the existing `RealShellWindow` and form-geometry test patterns.
3. **Implement**, then run only the admitted focused commands and paste actual
   output counts. Assert a positive executed-test count, because a filter that
   matches nothing still exits 0.
4. **Broad/native regression is exact-head CI.** Local execution is limited to
   the admitted per-issue exact allow-list; script changes, focused/hidden roots
   and packaging changes do not grant new commands. No visual-baseline task.
   `windows-spikes` is a CI workflow job, not a `validate.ps1` task.
   Every exact-head workflow must be green before merge. Report every failure, including
   flakes, with the rerun result next to it. Never replace a failing log with a
   passing one.
5. **Visual evidence is separately gated.** No manual screenshots or automatic
   neighbouring-screen batch. The current authority above controls any future
   final desktop slot. B/C/D/E visual acceptance is **NotExecuted (#826)**,
   not silently waived by merge. Record exact paired scenes, source binding and
   limitations only after an admitted run; historical pixels cannot acquire
   current provenance during conversion.
6. **Source/evidence review, before any admitted capture.** A reviewer from a
   different vendor receives the diff, PR body and evidence folder. Only an
   admitted capture proceeds to a final privacy-cleared image pass. It checks:
   - every RED/GREEN/REGRESSION line matches a log it opened;
   - every screenshot it cites shows the claimed state;
   - no criterion is claimed from a UIA readback or unit test alone;
   - no unrelated file changed;
   - neighbouring-surface evidence within the admitted scope, explicitly
     listing unexecuted checks rather than manufacturing a new capture grant.

   Its findings are fixed or answered in the PR before merge.
7. **Privacy review, then visual sign-off.** Admitted actual images may undergo
   individual privacy review/scan first. Paired visual review and publication
   use only individually privacy-cleared actual images; held originals remain
   outside admission. Only accepted pairs can support the named criteria;
   otherwise leave boxes unticked with a reason. Offscreen component evidence
   cannot stand in for whole-window/native behavior.
8. **Merge.** Only the coordinator merges, after exact-head CI is green, using
   `gh pr merge --squash --match-head-commit <sha>`. Ledger rows change only in
   a coordinator ledger PR, after the evidence is accepted.

### Evidence honesty (copied into every kickoff)

- Distinguish compile failures from behavioural ones, and injected input from
  physical input.
- A green build or unit test does not prove rendering, layout, input,
  accessibility or parity. Say exactly which path ran.
- An empty result is not a pass. Assert non-zero counts for tests, UIA nodes
  and log matches.
- Keep failed attempts, and label harness failures separately from product
  failures.
- PR bodies list **Not verified** items explicitly. A row or criterion with
  incomplete evidence stays `Partial` or unticked.

## Local testing (no Dev Box)

This table describes evidence classes, **not executable permission**. CI owns
the broad/native rows. Any local exception needs the exact allow-list and
fresh owned roots above; manual screenshots remain canceled.

| Lane | What it proves | How |
| --- | --- | --- |
| L0: unit | Pure logic and geometry | `zig test` on the touched roots, with a positive count asserted |
| L1: shell validation | The whole shell, including the UIA live gate and daemon round trip, on this machine | `validate.ps1 -Task windows-shell -SkipTrayLive` with pinned toolchains, in the session's own scratch roots |
| L2: Windows Sandbox | Clean-machine install and first run, the packaged flow, before/after screenshots, UIA and focus order | A `.wsb` with `<vGPU>Disable</vGPU>`, a read-only input folder (package and script) and a writable output folder. `LogonCommand` runs the script, which installs via `GraphCode-Setup.ps1`, builds the fixture, drives the app and captures evidence. Proven on 2026-10-13 for #556: install, connected onboarding, all four pages by keyboard, relaunch. |
| L3: computer use | Exploratory and visual checks; driving surfaces that UIA can't reach | Once the operator enables computer-use tooling, an agent drives the **Sandbox window** from the host. Whether its input reaches the guest as non-injected is unverified until a `WH_KEYBOARD_LL` check shows `LLKHF_INJECTED` clear. |
| L4: physical input | Native keyboard and mouse claims (#556 Phase B, the reachability gate) | The operator types into the Sandbox window, or into the installed app on this PC, with the guest-side key logger running. |
| Hardware | Touch and touchpad (#726), mixed-DPI monitors (#749) | Real devices only |

**Sandbox rules.**
- Only one Sandbox can run per host at a time, so lane F owns a **single queue**,
  and sessions request a Sandbox slot through the coordinator.
- Stop a Sandbox **by PID** (`WindowsSandboxRemoteSession` and
  `WindowsSandboxServer`) when its run ends.
- If a launch fails with "too many sessions established to that server", clear
  stale Sandbox processes and use `<vGPU>Disable</vGPU>`.
- Keep the shell's close-to-tray behaviour in mind: use File > Exit, not
  Alt+F4, to end a run.

## macOS ground truth

The local ground-truth recording from source
`2ccf303a04f995184aae1d4b738a9eca0f71b79e` has returned. It is the primary
reference ahead of Run A, not a conformance verdict or a committed image bundle.
Its 354 items are 244 `Recorded`, 4 `Differs from request`, 3 `Absent on macOS`
and 103 `Exists, not recorded`. An unrecorded updater, workspace, input or
type/state combination is not an absent feature. Source-confirm an absence's
precise scope before narrowing an issue or planning a Windows-extra removal.

The bounded different-vendor intake opened 12 primary and 3 comparison images
and checked 5 metadata negative controls; it did not visually clear all 784 images.
Observe the local publication-hold notice referenced by the canonical worker
kickoff. Every image needs its own privacy clearance before upload; hashes,
OCR and correctly black mask rectangles do not prove that adjacent content is
safe. Never commit the bundle, its hold notice or a wholesale copy.

Use the `@1x-srgb` copies after reading the privacy report, item notes and
capture metadata. Distinguish native backing scale, copy scale and canvas zoom.
The `764-final-fixtures-fitted` images show the **ParityRef project canvas at
90%**, not the global graph claimed by stale metadata. They remain useful for
the recorded cards, not global-graph, overview-start or lane-caption evidence.
Use the separately recorded global overview for that context. Likewise, a
disabled global menu command is not evidence that a similarly named workspace
bar button is disabled.

### Additive companion qualification (2026-10-15)

The original primary remains `C:\gc-ref\macos-groundtruth-2ccf303a`.
`C:\gc-ref\macos-groundtruth-2ccf303a-gapfill-v2` is additive, not a
replacement or blanket clearance: **543 files / 178 PNGs / 542 verified payload
hashes / zero backend turns** in the retained metadata. Independent review
cleared only **11 sampled images**; **167 unsampled remain independently
uncleared**. This documentation reconciliation reads metadata/hashes only and
adds no image privacy verdict. The primary's two held issue-722 originals and
path-only hold notice remain governed by the canonical kickoff.

New macOS references include exact empty global/project scenes, separate
project/overview 100% scenes, native Open Folder/Project Settings, inline
Reclaim/Keep, Goal/Composite and menu splits. The primary fitted-project 90%
frames are not relabelled as global or intrinsic 100%. The read-only thirty-row
worksheet records 6 sampled components / 3 recorded but independently unsampled /
21 without a new exact recording; all 30 require current Windows evidence,
with zero promotions. Worksheet and spotcheck metadata hashes are retained in
the ledger. Preserve its dated 2026-10-14 table as historical observation;
companion qualification is a later update, not retroactive provenance.

The ledger's dated intake recovers all 30 previously unassessed row identities.
Pair only exact states that were actually recorded. The retained Windows
bundle is **Windows beta26 (pre-wave-1)**; a historical pair is not a verdict
on current main. Missing current pairs are qualification gaps, not invented
product failures, and do not satisfy the ledger's `Validated` gate.

Keep this reference intake separate from final A-E reconciliation on merged
heads. Existing approved slices are not reopened unless the source or recording
contradicts them. Partial slices, source/UIA checks and new macOS images do not
close whole claims. Any extra removal needs its own bounded approval and an
audit of reachable equivalent actions. No screenshot, golden-image or pixel
baseline CI lane is revived by this intake.

## Cadence

- **Wave 1 (P1).** Lanes A–E start in parallel. Calibrate the models on the
  first issue in each lane.
- **After each wave:** review the accepted source slices, exact-head hosted
  regression and outstanding criteria. Candidate builds, local L1/L2 execution
  and paired capture each require their own explicit commands and admission;
  they do not run automatically. Promote ledger rows only after complete
  accepted evidence, and publish a prerelease only with operator approval.
- **Wave 2 (P2)** and **wave 3 (P3)** follow the same loop. The testing-gap
  verification in lane F runs throughout.
