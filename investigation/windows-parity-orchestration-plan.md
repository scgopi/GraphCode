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
| A | #768 | `gpt-6.1-sol`, high, long_context; STUCK at 23:27 (the capture harness failed 4 times), escalated to `claude-sonnet-5.5`, xhigh, long_context |
| B | #773 | `gpt-5.4-mini`, high; escalated at 22:50 to `gpt-6.1-sol`, high, long_context |
| C | #767 | `gpt-6.1-sol`, high, long_context |
| D | #774 | `gpt-5.4-mini`, high; switched at 23:25 to `gpt-6-luna`, high (operator decision) |
| E | #776 | `gpt-6.1-sol`, high, long_context |

**Desktop lease.** Integration validation (the UIA live gate), Windows Sandbox
runs and screenshots of a running shell all take the desktop. One session
holds it at a time, and the coordinator hands it out. Unit validation and
`zig test` run in parallel, each in its own scratch roots.

**Short validation root.** The UIA live-gate preflight refuses sandbox paths
longer than 81 UTF-16 characters, and `validate.ps1` appends
`<GUID>\temp\gu-<GUID>` to the root. Pass `-ShellValidationRoot C:\gc-<lane>`,
where `C:\gc-<lane>` is a **real** short directory owned by the lane. Do **not**
use a junction. A junction makes fixture paths differ between the alias and the
resolved path. That breaks the `WorktreeGitProcess` unit fixtures, and very
probably caused local `ScrubbedShellStartup` `registered-project` failures that
exact-head CI did not reproduce.

**Desktop for unit tests too.** Some App and WindowsNativeDialogs unit roots
call `ShowWindow`, `SetForegroundWindow` or `SetFocus`. So the **full unit
part** also runs inside the desktop lease. Only focused hidden-window
`zig test` runs freely.

**Captures.**
- Seed `onboarding-seen` in the fixture's `GRAPHCODE_SUPPORT_DIR`;
  `WindowsOnboarding.Store` reads it there, not from `LOCALAPPDATA`.
- Windows Sandbox clamps the guest screen to about 1520x823 and failed
  `EnumDisplaySettings` with vGPU disabled. Use it for clean-install and
  first-run flows, not for 1440x900 visual captures.

**Creating PRs.** Use `gh pr create` as `coneilen`. The app's PR tool tries a
fork push and fails.

**Provider checkouts.** Seed `winghostty` and `zmx` under the lane's
`-ProviderRoot` from the read-only local mirrors in `C:\gc-cache\git\*.git`.
Check out the pinned commit, point `origin` back at GitHub, then run
bootstrap: it verifies the pin.

**Toolchain.** Each session bootstraps its own tool, provider and scratch
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
| Small, well-scoped fixes (one function or dialog: #774, #779, #758) | `gpt-6-luna`, high, default | `gpt-5.6-luna`, high (operator-chosen fallback if `gpt-6-luna` underperforms) | Operator decision (2026-10-13), replacing `gpt-5.4-mini`. In wave 1, `gpt-5.4-mini` was escalated on #773 (no visual evidence or review after more than 2 hours) and struck on #774 (a self-caused CI failure and an unproven "unrelated" claim). The survey found no published agentic-coding benchmark for `gpt-6-luna`, so calibrate it on its first issue. |
| Lane implementation (#768, #764, #765, #767, #769, #778, #722, #771, #772) | `gpt-6.1-sol`, high, **long_context** | `claude-sonnet-5.5`, high, long_context | Same price tier as Sonnet 5.5, with a 1.05M-token window for `App.zig`-scale files. Long context is only needed here. |
| Polish (P3) | `mai-code-1.1-flash`, medium, default | `claude-haiku-5.5`, medium | The cheapest model with a published coding score and a screenshot-to-code benchmark. |
| Rubber-duck review (code and evidence) | `claude-sonnet-5.5`, high, default | `grok-4.7`, high | A different vendor from the OpenAI implementers. If an Anthropic model implemented the change, review it with `grok-4.7` or `gpt-6.1-sol`. |
| Visual sign-off (paired screenshots) | `claude-sonnet-5.5`, high, default | `claude-opus-4.8`, high, only if Sonnet's verdict is disputed | Must open every image it cites. Opus 4.8 has the best-documented vision, but costs more. |
| Test runs and reporting | `claude-haiku-5.5`, low (medium when results are contested) | `gpt-5-mini`, low | Mechanical execution with very large logs. It must quote raw output, not summarise success. |
| Coordinator | the current coordinator session | — | Owns the ledger, merges, file leases and the Sandbox queue. |

**Calibrate before scaling.** Run one P1 issue per implementation model first,
and measure:
- the CI first-pass rate;
- the number of reviewer findings;
- the rework rounds.

Promote or demote models on that data, not on benchmarks alone.

### Abandon and escalate a struggling session

A session that is going in circles costs more than starting again on a stronger
model. The coordinator watches each implementation session, and **abandons it**
when **any one** of these conditions holds.

| Trigger | Threshold |
| --- | --- |
| The same RED test or validation step still fails after successive fix attempts | 3 attempts |
| The rubber duck or the visual sign-off rejects the PR, each time with substantive findings (not wording) | 2 rejections |
| Exact-head CI fails for a reason the session caused | 2 times, after its own local validation said green |
| An evidence claim is contradicted by the reviewer (overclaiming) | once, on a second offence |
| No new passing test or accepted acceptance box | 90 minutes of busy time |
| The session edits files outside its lane lease, or asks to widen the scope | once, unless the coordinator approves |

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
3. **Implement**, then run the focused Zig tests and paste their output
   counts. Assert a positive executed-test count, because a filter that matches
   nothing still exits 0.
4. **Full validation**, run by a test-runner agent:
   `Tools\windows\validate.ps1 -Task windows-shell -SkipTrayLive`, plus
   `-Task packaging` when packaging changes, plus `-Task windows-spikes` when
   `DesignTokens.zig`, palette, font or contract files change. That task runs
   contracts the shell suites don't, such as `PaletteParity.Tests.ps1`. Report
   every failure, including
   flakes, with the rerun result next to it. Never replace a failing log with a
   passing one.
5. **Visual evidence (local).** Build in the session's own worktree, run the
   shell in a Windows Sandbox (see Local testing) with the shared reference
   fixture, and capture the surface **before and after** at 100%. The PR
   includes a table: macOS capture, Windows before, Windows after, and the
   acceptance boxes each pair shows.
6. **Rubber duck.** A reviewer from a different vendor receives the diff, the
   PR body and the evidence folder. It must check:
   - every RED/GREEN/REGRESSION line matches a log it opened;
   - every screenshot it cites shows the claimed state;
   - no criterion is claimed from a UIA readback or unit test alone;
   - no unrelated file changed;
   - the behaviour of neighbouring surfaces didn't regress (it opens their
     captures as well).

   Its findings are fixed or answered in the PR before merge.
7. **Visual sign-off.** The visual model ticks each acceptance box with a crop
   reference, or leaves it unticked with a reason.
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

The next macOS run uses the ground-truth prompt template:
- the agent records what macOS does;
- statuses are `Recorded`, `Differs from request`, `Absent on macOS` and
  `Exists, not recorded`;
- inventory is checked against source first;
- the fixture is corrected (spaced titles via UI rename, `--check` on turn
  loops, a cycle-only component, and a UI-created guarded edge);
- menus are read in the same selection state on both platforms;
- the privacy scan covers archive contents.

It must cover the 30 rows the side-by-side review could not assess, plus:
- the edge sheet;
- Project Settings;
- the update dialogs;
- populated Quick Chats;
- the RUNNING and BLOCKED card states;
- whether macOS shows a sidebar Needs-you section.

## Cadence

- **Wave 1 (P1).** Lanes A–E start in parallel. Calibrate the models on the
  first issue in each lane.
- **After each wave:**
  1. cut a local unpublished candidate;
  2. run the L1 and L2 qualification;
  3. re-run the paired captures on the surfaces that changed;
  4. promote ledger rows only where the gate evidence is complete;
  5. publish a prerelease only with operator approval.
- **Wave 2 (P2)** and **wave 3 (P3)** follow the same loop. The testing-gap
  verification in lane F runs throughout.
