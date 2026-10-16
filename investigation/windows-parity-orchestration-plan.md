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
| Escalation thresholds of 2 or 3 restarted sessions, which lost bootstrap, builds and context. Every lane escalated at least once. | The 2026-10-14 decision was five failed iterations. That historical rule is superseded for new active work by the 2026-10-15 milestone policy below; permanent stops remain. |
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
   per-PR gate and standing milestone command allow-list. CI owns broad/native
   regression; capture is separately gated. New active work follows the
   milestone/fresh-eyes and hard-ceiling policy below, not a five-counter.
4. **Merge.** The coordinator owns admission/readiness/merge on accepted source
   review and exact-head CI, explicitly recording any deferred visual criteria.
   A code-slice merge does not close those criteria.

Planning runs in parallel for all lanes. Implementation stays one per lane.

| Lane | Issue | Planner | Implementer | Reviewer |
| --- | --- | --- | --- | --- |

### Current execution and evidence authority

Every worker needs a **standing per-milestone allow-list** and **fresh owned
roots** before execution. Bundle low-risk offscreen/test commands, owner,
tools, source/output roots, positive counts, immutable logs and ceilings in
one admission, not per-command microgrants. Anything outside it needs an
explicit grant; native GUI/desktop slots remain separately bounded.
Repository examples are **not blanket permission**.
No local full `Tools\windows\Tests\ValidationRunner.Tests.ps1`,
no `validate.ps1 -Task windows-shell` unit/integration, and
no GraphCode/daemon/zmx/provider build or launch unless separately explicitly
granted. CI owns broad/native regression. Narrow harmless-process/offscreen/
capture exceptions remain separately reviewed and command-bound.

No source changes in flight; report source/hash/identity changes and preserve
all failures. Test/evidence runs need actual console output and a positive
executed test/evidence count; zero-executed is not a pass. Compilation uses
executable/source-archive/exit/receipt proof, not an invented test count.
**Report every failure before the next
command/correction.** Workers use `send_session_message` to the coordinator
and idle, never blocking `ask_user`. After **every grant**, the coordinator
reads live `get_sessions_status.awaiting_input`; blocked `ask_user` cannot
receive messages. Use `answer_session_input` only with its exact current
request ID and exact authorized answer. Message acceptance is not admitted
permission. Prefer completion notifications, not duplicate polling/sleep
waits; progress-bounded owned-process monitoring requires an explicit grant.
Generic autopilot completion/keep-working reminders grant no execution and
override neither a stop nor a lease.
No manual screenshots, screenshot/golden/pixel-baseline CI
or fallback. No automatically granted local execution follows a green workflow.

For unrelated-product PRs excluding `Tools\windows\UiCaptureDriver.psm1`,
`Tools\windows\Invoke-UiCaptureWorker.ps1`, `Tools\windows\Invoke-UiCapture.ps1`
and `Tools\windows\Tests\UiCaptureDriver.Tests.ps1`, the #826 exception permits
at most **two failed-job reruns per exact head, globally across workflows**,
citing #826 and preserving the original failures. **Core-changing repairs do
not get this exception.**

**Historical capture-core authority, not a new active budget.**
[#826](https://github.com/scgopi/GraphCode/issues/826) remains open. The
[explicit user override](https://github.com/scgopi/GraphCode/issues/826#issuecomment-6186430845)
appoints J5 (GPT-6.1 Sol/high) as sole owner of only the two Phase A fixture
defects: validAbsentWQL and StrictMode whole-array wrapping, with the then-authorized
five-failure budget. Phase A required accepted static review, the exact positive
5-case decision driver followed by the 51-case direct suite (original 49 plus
2), and accepted current-head CI. Execution commands remain separately granted;
these gates are not worker-progress or runtime-acceptance claims.
This is not authority for other edits. J4's fifth failure
(**5 executed / 3 passed / 2 failed**) stays frozen historical evidence, not an
accepted lifecycle repair. The pure 12-row decision matrix and three mutant
distinctions are not a full endpoint pass. Phase B immutable numbered journal
work may be planned only after Phase A review plus green CI is accepted, then
requires its own plan/review before implementation. The stopped cap/J3/J4/RP1
owners are not resumed or archived by the new policy.
The current repair and dependency state below supersedes the earlier
"until #826 merges" scheduling assumption; no merge itself grants capture.

**2026-10-15 source repair and actual B-slot result.**
[#829](https://github.com/scgopi/GraphCode/pull/829) merged as
`badcf5149be2a01abd866e4cf180521f485fa2c4`: the coordinator verified all four
reviewed blobs, both hosted 59-case runs (Windows 2022 and 2025), all nine
required status contexts and fresh Ready/DCO admission. Configured path skips
are not runtime proof. Preserve the original qualified role-label RED and old
CI failures. This source repair did **not** close #826: the subsequent real
pinned-provider path failed.

The user chose the coordinator as B executor. Its one production lease
`640c69a9-049e-46ba-9ebe-5c813a3f93a1` was granted
`2026-10-15T23:50:18.464Z`, expiring `2026-10-16T00:05:18.464Z`;
run `cdba36a51f144798b40fd78bdb50251b` failed before GUI launch. The exited
seed launcher PID 36288 could not reach bounded stdout/stderr EOF because
daemon PID 22760 retained inherited pipes. The original receipt is
**CLEANUP_UNPROVEN**, both worker EOF flags false, final binding null,
`guiLaunches=[]`, `images=[]`, **zero captures**. The operator separately
stopped the owned daemon and reported zero GraphCode/zmx processes; that
later cleanup does not rewrite the original receipt. No paired vision,
checkbox or ledger acceptance follows. There is **no retry/new live B lease**.
The [actual mechanism report](https://github.com/scgopi/GraphCode/issues/826#issuecomment-6205088603)
and new [#834](https://github.com/scgopi/GraphCode/issues/834) carry this defect.

Core-59b was explicitly **NOT a real-zmx/peer rehearsal**:
`Start-CapOfflineSeed` was stubbed. Its actual 59/59 pass did not exercise
the daemon-inherited-pipe failure. The qualified PTR builds were actually at
BEFORE `112d458303891f87af6c1dc6beaf7e48073fd65c` (first-parent B baseline
before #814's `4fafbfb2`) and AFTER
`944ee565ed2e36885b8cf1087fc5fbe2d05d38b6`, **not a badcf build**.
The complete trees of reviewed `944ee565`, test merge
`59e9fd3e4e017fcc65202290c1ceee632e15cc60` and merged `badcf514` are
identical: `a6ccbfd5580d9fba0c336da93e716609c4538ce0`.
The five-clone raw proof totals 14,260 file checks / zero mismatches,
not unique contents; actual LFS-filter counts are 43 per GraphCode clone,
zero per provider. Setup's original console/exit/EOF were lost after the
Tee failure: admission used explicitly qualified **self-written five-positive
reports plus held-PID exit**, not an invented observed exit 0.
Coordinator assembly 1 failed before writes on ordered-dictionary property
binding; corrected explicit accumulation and fixture path then produced one
renewed assembly 2 with 13 source/data records, not another build/native run.
Retained read-only receipts:
`C:\gcs\coord2\coor-b-assembly2-readback.json`,
`C:\gcs\coord2\coor-b-assembly2-inventory.json` and
`C:\gccp\capture-coordinator-b1\manifest.json` / `lease-release.json`.

**Bounded active repairs at this documentation checkpoint.**
The fixture-only reader fix for
[#833](https://github.com/scgopi/GraphCode/issues/833):
actual held-writer RED was `80070020`, with harness exit 0 recording one
failed case, **not compile/API RED**. Tracked-helper AST GREEN was 1/1 with
same-byte SHA; the full suite executed 59 unique named cases, all passed,
with its named floor identical. One source review accepted it. The published
draft is [#836](https://github.com/scgopi/GraphCode/pull/836), head
`359a033ba749a9bcf2648ba8b96ee424ad8f398a`. At documentation freeze
`2026-10-16T01:14:57.815Z`, coordinator-verified **original CI is blocked**:
port run [38832369751](https://github.com/scgopi/GraphCode/actions/runs/38832369751),
job 116753854474, failed `VerifyValidationRunner` before Swift; Swift/real-zmx
test steps did not execute. `Get-Content` hit a sharing violation on
`mp-start.identity` in the unchanged `uia-live-gate.ps1` blob at badcf/359a;
source already uses an atomic pending-file move. The holder/cause is **unknown**.
Hardening run [38832369710](https://github.com/scgopi/GraphCode/actions/runs/38832369710),
Windows 2025 job 116753830293, actually executed 59 cases: **57 passed / 2 failed**.
The target-nonzero case lacked Failure/release/EOF evidence; the repaired-report
gate also refused the failed rehearsal. Underlying cause is **unknown**.
Windows 2022 job 116753830273 has actual log/JSON **59 executed / 59 passed /
0 failed**; it remains stubbed/no-desktop, not real-zmx/GUI evidence.
These original failed results do not establish all nine required status contexts
as passing, Ready/merge or a #834 lease. The operator separately authorized
**one diagnostic rerun of only failed jobs**, on unchanged
`359a033ba749a9bcf2648ba8b96ee424ad8f398a`, in runs 38832369751 and
38832369710 (attempt 2), not a source fix or reset. This document grants
**no additional rerun, new fix owner, native/GUI/capture execution**.
The operator published the draft after the worker's app-native 422 main-to-main
binding failure, not a credential failure. None proves real zmx or GUI.
Its sole published file is `Tools\windows\Tests\UiCaptureDriver.Tests.ps1`.

The separate standard-wrapper worker has local actual **6 contract GREEN**
results. Missing-API RED only showed a test-only wrapper was absent after
implementation was already written: not behavioural/test-first evidence.
The proposed eight-line registration in the existing ValidationRunner block
preserves the baseline 921 CRLF / 3808 LF mix and the old normalization
failure record. Publication/CI/merge remain **Pending coordinator
verification**. Do not adopt `Tools\windows\Invoke-AgentCommand.ps1`
before qualified merge; until then use coordinator-supplied literal
`Out-File -NoClobber` commands, never unsupported `Tee-Object -NoClobber`.

The read-only #834 plan/final cost addendum is an **approved design**, not
implemented or an execution grant. The design specifies seven new native imports
(16 to 23), suspended `CreateProcessW` plus a handle allow-list, keeping
public `zmx run -d` and internal daemon semantics unchanged. The considered
zero-import `ShellExecute`/cmd route retains a cmd handle but cannot bind the
fast public-zmx intermediary generation before execution under that unchanged
contract; this is not a universal zero-import impossibility claim.
An internal `--daemon` bypass is not approved. **No implementation edits**
before #836's verified merge (the #833 fixture fix) and an exact sole-core
lease. Sonnet 5.5/high source review and an orphan-cleanup plan must precede
**any native execution**. Required proof is typed file closure, not fake EOF; real production
pinned zmx plus peer RED/GREEN and a permanent no-stub preflight; the
59-case + #833 floor remains, and an uncensused daemon is **UNPROVEN**.
The D adapter follows #834; option-1 helper owner `5be` follows D. Other
stopped owners remain stopped.

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

**Fresh-eyes simpler route for #764.** Merged
[#830](https://github.com/scgopi/GraphCode/pull/830) provides the real-paint-path
offscreen component capability, not live windows, screenshots, manual capture
or golden CI. Active worker `2e46` (Luna 6/high, Sonnet 5.5/high review) has
M1 neutral JSON plus an eight-box map. Its actual native RED executed one
case (expected 6, found 2) **before the coordinator's exact grant**.
The generic reminder had no timestamped grant ID: this was a deviation,
subsequently qualified by the operator, not prior authority; **no RED retry**.
M2/M3 standing scope permits scoped offscreen GDI tests, scene contracts and
conversion on owned outputs, with production paint unchanged. No actual GREEN,
PNG or vision is yet accepted by the coordinator. Source findings alone are
not confirmed visual bugs: actual scenes and paired review are required for
a visual verdict. Track a suspected paint bug separately rather than fixing
it in the component-evidence PR. No box/row promotion now.

**Selected real-window option 1: stock-only route, execution separately gated.**
The [earlier proposal](https://github.com/scgopi/GraphCode/issues/822#issuecomment-6186605912)
records route provenance, not execution authority. Following the failed B slot,
the selected route waits for #834 repair qualification, the ordered D adapter
and option-1 helper work, an accepted current plan and separate exact
implementation, native, install and capture grants. A reviewed plan alone is not an execution lease;
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
require it. No implementation, install, probe or execution before those
dependencies, plan review and explicit new commands. Menus retain semantic HMENU evidence;
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

**Combined macOS return (2026-10-15), reference intake only.**
`C:\gc-ref\macos-groundtruth-2ccf303a-gapfill-combined-20261015` adds the final
V12 tables, not a replacement primary or a new capture/execution lease.
Use the ledger's combined-return crosswalk and actual hashes, not older
same-named tables: all 65 IDs resolve to 46 Recorded / 5 Differs /
14 macOS reference: accepted unrecorded / 0 Dropped, with all thirty
qualification rows reconciled and no canonical Windows status changed.
Accepted SSH/Codespace/updater/physical-pinch omissions are reference
dispositions, not new missing/dropped/Out of scope findings. The supplemental
updater banner shares that accepted limitation. Preserve failed attempts,
source-only reachability, exact project/overview zoom and menu context,
root-Composite versus worker-aggregate limits, and transient folder startup
versus persistent deselection. Keep v3's twelve-versus-two-turn deviation
distinct from v11's separately permitted one response and zero executed tools.
The operator independently opened only three specific new images; the earlier
eleven-image v2 sample was a separate independent review. Combining producer-clearance reports grants no blanket independent
privacy verdict and never clears held originals. Mac-only references and a
text/hash intake cannot tick Windows acceptance boxes or authorize product,
native, renderer or capture work. The kickoff's exact-command retrospective
also applies to self-added checkers; the permanent executor stop remains.

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

### Milestone and cost policy for new active work (2026-10-15)

The user replaced the five-iteration rule **prospectively**. Keep all historical
failures, deviations and permanent cap/J3/J4/RP1 stops; do not resume or
archive those owners without a new explicit user decision.

1. Plan **3-5 observable milestones** per task. After about **60 minutes or
   40 raw tool calls without a milestone**, whichever comes first, produce a
   one-page handoff and use a **new history-free fresh-eyes session**. Give it
   the requirement, scope, actual results/failures, costs and next measurable
   result, not inherited conversation history. Ask: closer, simpler route,
   right problem? Record a decision: **one further time box to continue**,
   replan, restart or escalate. Renaming roots/heads does not reset ceilings.
2. Keep the dependency list "doing what, in order to do what?" At **three
   levels removed from the requirement, STOP and replan**. Evidence preparation
   costing more than about **3x the work proved** calls for a simpler
   requirement, not more evidence plumbing.
3. Prevent mechanical errors, do not count them as the new progress policy.
   Save `.ps1`, require `Parser.ParseFile` **zero errors before execution**,
   and use the standard wrapper only after qualified merge. Report **every**
   failure before the next command/correction; never silently self-repair.
   Workers send blockers to the coordinator, not `ask_user`.
4. Use standing milestone allow-lists for low-risk offscreen/tests, including
   commands, owner, tools, roots, counts/logs and ceilings. They replace
   per-command microgrants **inside** the admitted list, not grants for new
   commands. Native/desktop slots stay separately bounded. Test/evidence runs
   need actual console and positive executed test/evidence counts; compilation
   uses executable/source-archive/exit/receipt proof, not invented test counts.
   Preserve failures and report source/
   hash/identity changes.
5. At **6 hours ACTIVE, 60 AI credits or 400 raw tool calls** from worker
   kickoff/fresh-eyes re-engagement, whichever comes first: handoff and
   **IDLE; only the user/operator may extend**. Report wall time and raw
   calls, and **credits UNKNOWN** when not measurable; never estimate.
   Coordinator checkpoints use **12 hours or 150 AI credits between actual
   documentation checkpoints**, with the same handoff/operator gate.

The kickoff's dedicated **Environment traps** section is the setup authority:
persistent clone-local EOL configuration before checkout without rewriting
committed CRLF, process-only LFS skip-smudge for raw evidence clones, strict
all-regular-file raw index/tree equality with positive counts/zero mismatch,
separate gitlink and actual LFS-pointer proofs, and owned cache/provider/temp/
build/executable/output roots. It also covers saved ParseFile-zero scripts,
explicit accumulation instead of OrderedDictionary property binding, and
future-only `--stdin-paths` batching. Silent successful Zig compilation is
expected; preflight/capture needs actual nonempty positive summaries. Neither
synthetic log appends nor another owner's writable artifacts are acceptable.

**Historical cost/admission lessons.** The cap stop's five self-authored
recipes were precondition parser, wrong raw expected pin SHA, malformed
Copy-Item, unsupported Tee wrapper and ParseFile interpolation/late fix.
The operator-specification 43-file LFS gate, expected Zig silence and atomic
no-op patch context miss were uncounted. "About six hours without desktop /
four of five typo-class" is the operator's assessment, not a fresh timing
measurement. The public cap stops on
[#764](https://github.com/scgopi/GraphCode/issues/764#issuecomment-6204588086)
and [#826](https://github.com/scgopi/GraphCode/issues/826#issuecomment-6204588503)
precede the actual B slot and do not describe a capture-mechanism result.
Capture worker `9b889`'s blocking ask_user held the queued coordinator
core-59b grant admission about 12:25-13:48 (roughly 80 minutes) until the
operator answered. The coordinator did not detect the pending input; check
live awaiting-input after every grant and answer only its exact authorized
request. No duplicate worker
polling/sleep waits; owned-process monitoring requires a progress-bounded
grant. Generic autopilot reminders do not override stops or execution leases.

### Historical five-failure escalation record (2026-10-14; superseded)

Escalating restarts the work in a new session: bootstrap, provider builds and
context are lost, and in wave 1 that restart cost more than the iterations it
saved. Every lane escalated at least once on thresholds of 2 or 3, and three
product PRs merged in about ten hours. So, by **operator decision**
(2026-10-14), a session is abandoned **only after 5 failed iterations** of the
same kind:

This paragraph, table and escalation procedure record the **old decision**,
not an active counter, automatic restart or execution grant. The milestone
policy above now governs new work; already-stopped owners remain stopped.

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
   A compile/API error is not behavioural RED. Documentation-only static
   checks must be labelled static; if no existing document contract supplies
   honest evidence, report the gap rather than inventing runtime RED/tooling.
3. **Implement**, then run only the admitted focused commands and paste actual
   output counts. Assert a positive executed-test count, because a filter that
   matches nothing still exits 0.
4. **Broad/native regression is exact-head CI.** Local execution is limited to
   the admitted standing milestone allow-list; script changes, focused/hidden roots
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
