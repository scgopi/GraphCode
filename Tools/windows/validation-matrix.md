# Windows port validation matrix

The Windows port must have runnable commands before implementation fleets begin.

## GraphCode

| Surface | Command |
|---|---|
| Windows investigation spikes | `pwsh Tools/windows/validate.ps1 -Task all` |
| Compiled validation runner contract | `pwsh -NoProfile -File Tools\windows\Invoke-ValidationRunnerContract.ps1` (builds and runs the normal full C# entry; see [runner documentation](ValidationRunner/README.md)) |
| Jump destination observation controls (no desktop/UIA calls) | `pwsh -NoProfile -File Tools\windows\Tests\WindowsShell.Tests.ps1 -JumpDestinationOnly` (16 destination fixtures; also executed by the shell gate and compiled `ui.functional-contracts` adapter) |
| Explicit fixture compiler selection (controlled files and observations; no compiler/GUI execution) | `pwsh -NoProfile -File Tools\windows\Tests\FixtureCompiler.Tests.ps1 -ScratchRoot .build\fixture-compiler-contracts` (fresh directory required; 27 cases; also run by the canonical capture adapter before fresh preparation) |
| Exclusive validation fixture directories (independent filesystem and static wiring contracts) | `pwsh -NoProfile -File Tools\windows\Tests\ValidationFixtureDirectory.Tests.ps1` |
| Isolated 30-key process environment boundary | `pwsh -NoProfile -File Tools\windows\Tests\IsolatedProcessEnvironment.Contracts.Tests.ps1 -Phase REGRESSION` |
| Deterministic visual baseline | `pwsh Tools/windows/validate.ps1 -Task visual-baseline` |
| TDD evidence contract | `pwsh Tools/tdd/Tests/TddEvidence.Tests.ps1` |
| Platform/wire contracts | `pwsh Tools/windows/validate.ps1 -Task swift-contracts` |
| Authenticated remote bridge proof | `pwsh Tools/windows/validate.ps1 -Task remote-bridge` |
| Windows-to-POSIX remote E2E parity | `pwsh Tools/windows/validate.ps1 -Task remote-e2e` |
| Hosted Windows without a WSL distribution | `pwsh Tools/windows/validate.ps1 -Task all -SkipWslRemoteE2E` |
| Production Swift platform package | `pwsh Tools/windows/validate.ps1 -Task swift-production` |
| Deterministic release hardening fixtures | `pwsh Tools/windows/validate.ps1 -Task hardening` |
| Signed catalog integrity and publisher policy | `pwsh Tools\windows\Tests\Packaging.Signing.Tests.ps1` |
| Native SignTool PS1 signature and tamper detection (SDK required) | `pwsh Tools\windows\Tests\Packaging.ScriptSigning.Tests.ps1` |
| Native missing/idle task stop and deletion | `pwsh Tools\windows\Tests\Packaging.Scheduler.Tests.ps1` |
| Failed-upgrade preservation, committed-backup marking, and recoverable rollback | `pwsh Tools\windows\Tests\Packaging.Rollback.Tests.ps1` |
| Uninstall refusal with live sessions/locked files and all-or-nothing removal | `pwsh Tools\windows\Tests\Packaging.Uninstall.Tests.ps1` |
| Standalone setup under PowerShell 5.1 and 7 | `pwsh Tools\windows\Tests\Packaging.Standalone.Tests.ps1` |
| Release publishing: signing gates, asset labeling, workflow contract | `pwsh Tools\windows\Tests\Release.Tests.ps1` |
| Product/investigation provider pin consistency | `pwsh Tools\windows\Tests\ProviderPins.Tests.ps1` |
| Native accessibility provider (MSVC and Windows SDK) | `pwsh -NoProfile -File Tools\windows\Tests\AccessibilityProvider.Native.Tests.ps1` |
| Native accessibility harness failure attribution (mock tools, no native fixture) | `pwsh -NoProfile -File Tools\windows\Tests\AccessibilityProvider.Native.Tests.Harness.Tests.ps1` |
| Native release feed, URL handoff, and allocation safety | `pwsh Tools\windows\Tests\WindowsShell.Tests.ps1 -ZigExecutable $env:GRAPHCODE_ZIG0152` (includes updater tests) |
| Successful-update rollback cleanup, locked retry, and failed-recovery preservation | `pwsh Tools\windows\Tests\WindowsShell.Tests.ps1 -ZigExecutable $env:GRAPHCODE_ZIG0152` (includes `WindowsRollbackCleanup.zig`) |
| Real-product packaging and source/standalone install/upgrade/rollback/uninstall | `pwsh Tools\windows\validate.ps1 -Task packaging` |
| Shared Swift package | `swift test --package-path <shared-package>` once extracted |
| macOS app/daemon/CLI | `make test` |
| macOS format/lint | `make check` |
| DCO commit range | `git log --format=%B <base>..HEAD` plus trailer validation |

### Jump destination acceptance

The finished Goal fixture is the leaf-workspace oracle; the Composite fixture
opens a group and must not stand in for leaf mounting. The destination check
requires exact owned loop-bar, project-toolbar and Show in Graph identities
with visible nonempty bounds, plus the unique selected sidebar loop row.
The 16 in-memory controls exercise the actual production observation helper,
not native navigation. The functional adapter has no compiled-UIA import:
its executed source/managed fixtures do not need a binding assembly, and the
ordinary loader registers real UIA clientside providers. Its existing 64 units
and the new exact-16 unit execute headlessly (65 distinct units, 122 counted
executions). The full registry contains 685 unique units; that is an inventory,
not a full-run result. Shell coverage remains 66 sections across 23/18/25.

The selected canonical invocation is
`ValidationRunner.exe --repository-root $PWD.Path --artifact-root $ownedFreshRoot --suite ui.functional-contracts`
after the normal pinned build. It deliberately exits 1 with `complete=false`
and `fullInvocation=false` because the other required units did not run.
Require all 65 selected unit identities to pass; do not relabel this as the
full CI-equivalent invocation. Full shell units still include native fixtures,
and `-SkipTrayLive` is not headless admission.

### Validation-runner fixture ownership

The untracked Swift-format fixture and `OwnershipSentinel` fixture require a
new directory before entering their cleanup blocks. Admission calls the exclusive
Windows `CreateDirectoryW` primitive, not the FileSystem provider's separate
existence check and idempotent create. Failures retain their Win32 error and
return no ownership receipt. An existing file or
directory causes explicit refusal without overwriting its contents or invoking
cleanup, including a collision at the create boundary. Missing intermediate
parent containers are created separately, but neither new nor existing parents
are recorded as fixture-owned or removed during cleanup. This preserves the
clean-checkout sentinel setup before the contracts preparation task.
The known unformatted
file is acquired with `FileMode.CreateNew` and tracked separately. Cleanup refuses
unexpected children, checks recorded creation timestamps, and rejects reparse
points or changed identities instead of silently removing replacements. It
deletes only recorded owned files, then removes the directory non-recursively;
the empty sentinel requires no file deletion.
If cleanup also fails after a workload error, both exceptions are reported
together rather than allowing cleanup to hide the original failure.
These checks do not claim native-handle or adversarial concurrent-replacement
protection. The independent 28-case fixture suite acquires its own scratch root
exclusively after checking import laziness, and retains that root as evidence
even on success rather than recursively deleting unrecognized test contents.
It uses owned filesystem scratch
and reads runner wiring only as data; it does not execute the validation runner,
its formatter task, native GUI fixtures, or UIA code. Its only explicit native
binding is the filesystem create primitive, loaded lazily rather than on import.
The GDI+ startup, scrubbed startup, and daemon round-trip consumers share the same
exclusive admission helper. Their independent 84-case cleanup/admission suite
substitutes ownership and native boundaries; it does not run the live producers.

The historical 24-case fixture count did not establish the untracked-specific
known-file preflight: the case runner's `$Name` parameter shadowed the loop's
`$name`. The corrected runner uses `$CaseName`; both unexpected-child kinds
assert one owned-file receipt and its preserved hash, and emit distinct
`UNTRACKED_OWNED_FILE_PREFLIGHT_KIND` markers. Require both markers as well as a
positive test count when interpreting that coverage.

### Stable canvas card context menu

The stable canvas card context menu mock contracts execute 16 managed
source-derived cases. The native boundary is substituted, so this does not
establish real hit testing, input, or menu return, nor prove the cause or
resolution of the historical intermittent missing-sheet failure.

### Canvas Goal/Timed retype: bounded memory coverage

Canvas Goal and Timed menus expose the opposing `Change to` action before Rename
in every non-stopped state, including resolved states. Sidebar menus do not gain
this action. Goal-to-Timed requires a new, nonblank trimmed task; sketch promotion
keeps its existing fallback. The captured project, composite, selection and source
type are revalidated. The sender also rejects a disallowed source/Draft-tag pair
before serialization or queue insertion. Queue insertion is not daemon acceptance
or persistence.

The final bounded run executed the following 20 tests, all passing with none
skipped. Run from `graphcode-windows` with the pinned bootstrap environment,
`$include=Join-Path $env:GRAPHCODE_WINGHOSTTY_ROOT 'include'`, and executor-owned
`$cacheLocal` / `$cacheGlobal`. Each command below also received
`--cache-dir $cacheLocal --global-cache-dir $cacheGlobal`.

| Selected command | Executed / passed |
|---|---|
| `& $env:GRAPHCODE_ZIG0152 test src\SketchPromotion.zig --test-filter 'canvas retype context'` | 2 / 2 |
| `& $env:GRAPHCODE_ZIG0152 test src\GraphContextMenu.zig -target x86_64-windows-msvc -lc -luser32 "-I$include" --test-filter 'canvas retype menu'` | 3 / 3 |
| `& $env:GRAPHCODE_ZIG0152 test src\SketchPromotion.zig --test-filter 'canvas retype payload'` | 2 / 2 |
| `& $env:GRAPHCODE_ZIG0152 test src\NativeForms.zig -target x86_64-windows-msvc -lc -luser32 "-I$include" --test-filter 'canvas retype form'` | 2 / 2 |
| `& $env:GRAPHCODE_ZIG0152 test src\DaemonClient.zig -target x86_64-windows-msvc -lc -ladvapi32 "-I$include" --test-filter 'canvas retype sender'` | 8 / 8 |
| `& $env:GRAPHCODE_ZIG0152 test src\SketchPromotion.zig --test-filter 'sketch promotion builds only the target decision with macOS cadence defaults'` | 1 / 1 |
| `& $env:GRAPHCODE_ZIG0152 test src\GraphContextMenu.zig -target x86_64-windows-msvc -lc -luser32 "-I$include" --test-filter 'sketch promotion real menu plan exposes only three eligible target actions'` | 1 / 1 |
| `& $env:GRAPHCODE_ZIG0152 test src\NativeForms.zig -target x86_64-windows-msvc -lc -luser32 "-I$include" --test-filter 'sketch promotion native adapter binds one decision and owns accepted fields'` | 1 / 1 |

These are selected data/state tests: forms have null sheets; clients never start
workers or transport, and sender tests disable command recording. Standard
allocator/mutex OS internals are not native GUI coverage. The initial App filter
`canvas retype app preparation` matched one source test and compiled/linked with
the existing pinned, session-owned native/provider inputs and `--test-no-exec`
(exit 0, runtime tests 0); that evidence remains compile-only. After separate
selected-path and linked-input startup review, a subsequent run of only that
App preparation filter executed and passed exactly one data-only test. It checks
the actual preparation path's canvas/sidebar origin and stopped/resolved inputs;
the callback pointer is retained, never invoked. No app window, form, provider
activation, worker or transport runs on that path. This adds one App data test,
not native GUI coverage, to the 20 selected tests above.
Original behavioral RED, compile-only RED, seven failed compiler attempts and
corrected passing logs remain separate evidence. These are historical selected
results, not final-source full feature gates. No native UIA, daemon persistence,
visual parity, Export/Import or whole-row completion is established by them.

### Retained Cards feature continuation

Merged main, including the compiled validation runner, is integrated by a
three-way merge. The Cards context-menu and transfer test registrations remain
in `WindowsShell.Tests.ps1`; the updated ownership and adapter contracts retain
main's expected counts rather than restoring the older fixture versions.
The old PowerShell monolith is not the canonical execution path.

The reconciled product source was built with pinned Zig 0.15.2 and the pinned
Winghostty provider, using `zig build -Doptimize=ReleaseSafe` with explicit
worktree-owned cache and output paths. The build exited zero; the product was
not run. Fresh pure-data regressions passed 47 transfer tests and 184 tests
from the full `SketchPromotion.zig` root (including imported model/form tests).
The source-linked canvas context-menu managed mocks passed all 16 cases with
zero failures, skips, or unexecuted cases. The first mock wrapper redirected
the returned Pester object into its log, losing its summary variable; that
wrapper failure is preserved separately from the subsequent verified result.

The `ui.cards-acceptance-controls` suite exercises
`GraphCodeUiaGateState.ClickPopupMenuItemStrict` through the shared
input core and the existing managed popup fixture. Strict acceptance refuses
unacknowledged hover and an undismissed popup before emitting select-item or
keyboard fallback; invalid target identity/geometry throws rather than returning
an empty receipt. The existing default popup entry retains its fallback behavior.
Native `GetMenuState` failure (`UINT_MAX`) is rejected before testing `MF_HILITE`,
including on the legacy error path; valid legacy fallback behavior is unchanged.
Strict preparation uses the actual cursor move and bounded native highlight
acknowledgement, without sent or posted synthetic hover messages. Refusals retain
the raw state, target geometry, and bounded cursor/window ownership observations
in the original exception's `Data`; diagnostic failures do not replace that
exception. The current native binding does not capture `GetMenuState` last-error,
so no stale Win32 error is reported as its cause. The pilot copies this metadata
before cleanup while preserving the original failure.
These controls execute no native input and do not establish live menu delivery,
picker effects, daemon persistence, accessibility parity, or visual parity.

The guarded key helper retains its original five-argument, two-event default.
Its explicit Control overload sends one Ctrl-down/key-down/key-up/Ctrl-up batch,
not a transactional guarantee. Short returns remain failures. Reported partial
chords attempt only key-up cleanup after rechecking the retained process, exact
owned foreground and current focus within that same root; no remaining keydowns
are replayed. Lost authority or short cleanup retains both the primary and
cleanup errors and explicitly leaves key release unproved; further input must
stop. The managed input fixture covers returns zero through four, short key-up
cleanup, ownership/focus loss and preserved default behavior without native input.
These controls do not qualify actual Ctrl+L navigation or picker containment.

The explicit `pickerNavigationOnly` Cancel-only observation uses that guarded
Ctrl+L batch, binds the actual focused native Edit beneath the observed address
band 41477, and requires unchanged identity/focus plus exact owned-path native
buffer readback before Enter. Folder/view qualification additionally requires a
fresh known owned directory marker in the actual native items view and a second
address readback of the current folder. It never sets the filename or invokes
Save/GetResult. Original case/control budgets and strict Cancel remain in force.
Any failed navigation run forbids further native input. Chord attempts and
completed guarded batches are recorded separately: a pre-chord failure is
`NOT_ATTEMPTED`, not evidence of held Ctrl; an attempted but incomplete/unknown
batch retains the unresolved-modifier barrier. Normal job/DPI cleanup cannot
clear that barrier or establish universal physical keyboard state.
Headless predicate controls alone do not establish that this runtime path passed.
The address band is selected from the existing bounded RawView structural reader,
not default `FindAll`: the retained structure-only diagnostic observed the exact
owned pane with `IsControlElement=false` while the same conjunction returned zero
before and after the raw walk. UIA class/automation ID remain distinct from the
freshly observed native class/control ID. The measured control-element view host
keeps its existing lookup. This correction alone does not qualify navigation.
The retained `d12` native qualification subsequently completed the ordinary
address navigation and strict Cancel: two guarded Control batches completed,
the fresh owned marker and exact current-folder address both matched, and the
graph remained unchanged with no archive. Filename edits and transfer effects
were zero. This proves that bounded folder/view path only, not filename entry,
Save/Open, selected-result containment or publication.
An explicit `pickerNativeFilenameOnly` extension stays inside that same
Cancel-only route and control budget. It binds the original raw filename host
and native Edit 1001, requires stable strict-hit readiness and exact owned focus,
then uses native selection/Delete/Unicode input with exact event counts.
Both native child and ComboBox text must match a fresh bare owned basename.
Paths, wildcard/device names, NUL and dotdot are refused; the source-derived
initial `loop.zip` and intended basename must both be absent in the proved owned
folder. It never presses Enter in the filename field or uses a setter fallback.
Folder/view, sentinel custody, graph and archive-absence checks remain required.
Headless controls alone do not qualify this filename path or authorize Save.
The separate `pickerNativeFilenameReadbackOnly` diagnostic returns before
filename selection, clear or typing and still ends in strict Cancel. It preserves
only lengths, emptiness and known-name/equality indicators for native child and
host `WM_GETTEXT`, plus the advertised host's read-only UIA value channel.
Native host window text is not silently treated as that provider's semantic
value. The original qualification guard remains in force outside this diagnostic.
No raw field text or recent-file names are retained.
The retained `d14` diagnostic observed all three channels matching the exact
source-suggested stem, not the full `loop.zip`; it did not establish when or why
the extension was elided. Initial-name qualification therefore accepts only
the source full name or its exact measured stem, with native child/host agreement
and independent advertised host-value agreement. Typed wanted-name readback
still requires the full exact ZIP basename. Both wanted/default full names and
their bare stems must be absent under the proved owned folder before and after
input. This does not change Windows extension settings or qualify Save/GetResult.
Typed filename readiness follows the existing native-field readback practice:
after one complete guarded Unicode batch, only reads are repeated inside the
original remaining control/case budget. Exact child, native host and semantic
full-basename agreement is still required; an incomplete expected prefix is
pending, never success. Unexpected bytes, missing semantic authority or changed
ownership/focus fail immediately. The last bounded lengths/equality indicators
and sample count are retained even on failure. No keydown replay, timeout
extension or typed-stem acceptance is added.
The retained `d15` attempt stopped at its immediate typed readback guard after
complete native counts; its typed channel values were not retained, so its
cause remains unproved. The fresh `d16` filename/Cancel qualification subsequently
matched the full 49-character basename in all three channels on read-only sample
two, with clear/type counts 2/98 and no replay or filename Enter. Folder/view,
four absent outputs, graph, sentinel, native jobs/DPI and default profiles passed.
This is not Save/GetResult proof.
The existing ZIP pilot has a separate explicit `nativeExportOnly` one-case mode.
It requires the hash-bound positive filename/Cancel receipt before process
creation, repeats the proved navigation and native-primary filename route, and
rechecks the original view, exact field identities/readbacks, four absent
outputs and sentinel custody before the unchanged strict Save pointer action.
Cancel-only observation still returns without Save. Success requires normal
completion, the exact owned archive/topology, unchanged graph, no alternate
archive/default/stem or retained staging, and original job/DPI/profile cleanup.
It observes the selected destination through the resulting archive effect,
not a direct pre-dispatch `GetResult` measurement. Headless gates do not qualify
this native Save mode.
The retained fresh `d17` native Save subsequently completed normally and
published the exact owned ZIP (one Composite, three recursive nodes, one edge,
no session transplants). The graph, sentinel, original jobs/DPI and default
profiles passed, with no alternate archive/default/stem or retained staging.
Its quiescence verdict retains cumulative total 4, active 1 and retired 3 with
retired identity coverage `UNOBSERVED`; it does not prove lifetime worker absence.
The separate `nativeImportOnly` one-case mode consumes a hash-bound copy of that
owned archive in a fresh owned folder. It requires the positive native export
receipt, verifies a regular non-reparse existing archive plus three absent
alternative names, and reuses the same navigation, exact native filename and
strict ID1 primary action checks. Open has no source `SetFileName`: its initial
field must be empty or agree in all channels with that exact owned file/full
stem, never an arbitrary remembered name. The target's original custody and the
archive source's payload/identity mapping are checked separately; a fresh target
is not assumed to be the original exported graph. Headless checks do not qualify
Open/import, persistence or its native cleanup.
The retained `d18` native import attempt refused at the raw filename-host selector
before filename pointer/selection/clear/type or Open dispatch. Two Control
batches completed; its conservative policy barrier is retained, not an observed
unresolved modifier. Jobs/DPI/default profiles passed and the archive was
unchanged. Host absence versus ambiguity was not retained and is not inferred.
The existing Cancel-only observation can separately opt into
`pickerImportStructureOnly`: strict Open Group/Import menu, bounded exact-owned
structural filename candidates/counts, then strict Cancel. Navigation, filename
input, Save/Open dispatch and raw Name/Value reads are forbidden by that mode.
It diagnoses Open's own hierarchy without replaying the refused Save-derived
selector or promoting a candidate to input authority.
The retained `d19` structure/Cancel diagnosis measured a shallow exact-owned
Open chain: `ComboBoxEx32` Pane 1148, its `ComboBox` 1148 child, then its native
`Edit` 1148 child. It performed no chords, navigation, filename input or
dispatch. Its bounded walk reached a depth limit elsewhere, so it is not a
whole-tree absence assertion. Native-primary Open now explicitly binds those
three measured levels, including current native/UIA classes, IDs, PID/root,
parent relations and held RuntimeIDs before each use. Root-level control 1148
is the wrapper, never the filename edit. Save retains its separately qualified
`FileNameControlHost`/Edit 1001 binding; neither operation falls back to the
other. This source correction and its negative controls do not qualify native
Open/import; the next fresh owned-existing-file attempt remains required.
The retained `d20` attempt reached native clear/type but stopped before Open
dispatch at readback timeout. Its last of 20 bounded samples had the full
49-character native Edit value matching the independently advertised host
semantic value, while the native `ComboBox` host's `WM_GETTEXT` remained empty.
The initial Open name had been empty in all channels. The archive, source and
jobs/DPI/default profiles were unchanged; two Control batches completed, with
no observed unresolved modifier. The historical policy barrier is retained.
Open's typed-name reader now requires the exact native deepest Edit plus
independent advertised host semantic full-name equality; native host window text
must be empty or exact, never foreign or another nonempty value. It is not a
setter fallback and adds no input/replay. Save still requires all three full
readbacks, and initial-name, folder/view, identity and input-file custody guards
remain. The retained timeout is not native Open/import acceptance.
The fresh `d21` native Open subsequently completed normally: one imported loop,
zero restored sessions, direct 3-node/2-edge and recursive 5-node/3-edge target
topology, fresh mapped identities, preserved original target custody and remapped
nested custody. The source/copy archive remained byte-identical, with no alternate
archive or retained staging; original source/jobs/DPI/default profiles passed.
Native Edit and advertised host semantic full names matched, with clear/type
counts 2/98 and no filename Enter/replay. Its raw inherited
`hostReadbackExact=true` label is retained with an additive correction: native
host window text was empty, not exact. Future receipts separately report native
child, native host and semantic host equality from their actual channel flags.
This label correction does not replay the earned native case.
The separate headless `h22` restarted the same verified daemon against d21's
store and used the existing public hello/open/readProjectGraph frame reader.
The complete root/nested graph matched the saved native-import state, including
payload, mapped identities and custody, with explicit revision/mailroom live
fields. Graph storage stayed byte-identical; normal open changed only
`recent-projects.json`. One held daemon job exited empty with readers drained;
archive/source/default-profile/sentinel checks passed, with zero GUI/input or
transfer calls. This is native-import persistence evidence, not restored
sessions/agents, transient-state or lifetime/backend absence evidence.
The same isolated production-daemon pilot has one explicit
`cards-connected-edge-strict` case. It opens the seeded containing graph,
derives one clear horizontal midpoint from the two exact current endpoint cards,
uses one native right-click and the strict Edit Edge menu helper, checks the
exact owned existing-edge form and read-only native endpoint fields, then
strictly Cancels and requires an unchanged complete graph. It admits no alternate
point, posted/right-click retry, direct-command or keyboard fallback, transfer,
retype or promotion. Its original foreground/identity/pointer and 15-second
case/5-second control budgets remain. Headless plan/geometry/prefill/source
negatives do not establish this live connected-edge path.
The first `d24` attempt reached the owned Edit-edge title but stopped at the
root PID/owner/class/title conjunction before endpoint reads or Cancel. Normal
job/DPI/profile cleanup passed; no connected-edge case was accepted. Per-term
root metadata was not retained, so the exact failing term is unproved. Source
audit found that the harness expected the native-form content class on the
outer sheet: `GraphCodeNativeForm` is the content child, while its root is
`GraphCodeSheetHost`. The corrected contract separately requires the existing
captionless sheet and native-form content checks, retaining PID/owner/title and
endpoint guards. Focused class/content/style negatives and bounded root metadata
do not retrospectively measure d24's root or establish live acceptance.
The fresh `d25` case subsequently passed: one native right-click at the single
clear midpoint, strict Edit menu item 5110, exact captionless sheet/viewport/
native-form-content chain, locked native endpoint fields 9100/9101, strict Cancel
and unchanged complete graph. The case took 1292 ms (278 ms for form controls),
with no keyboard, alternate point, direct-command or transfer route. Source,
held-job/readers, DPI and default-profile checks passed.

The existing focused Cycle entry first stopped in `c26` before its target case:
the strict app-root list also observed `TitleBar` and `MenuBar`. Its refusal is
retained, without a causal attribution to geometry or provider initialization.
The separate failure-only `v27` measured their exact own PID/root ancestry,
distinct runtime IDs, expected native-chrome UIA roles, empty class and contained
positive bounds. Both had native HWND/PID zero: ownership is their validated
host-provider UIA relationship, not separately held child HWNDs. The harness now
validates that exact contract independently of required app-child IDs, order and
links. Wrong role/root/PID/native identity, duplicates, unknown extras and invalid
geometry remain rejected; required app children also retain their own-PID check.
No product controls were hidden or removed.

The fresh `v28` Cycle entry passed its selected/unselected Main Inspect Button
and non-invokable footer-reason identities/geometry, with normal card activation
and return. It did not click Inspect or retain a qualified raster. The separate
existing Recovery entry passed stable Wire invoke/cancel and Mark-entry result,
removing recovery controls while preserving the card. Both retained exact
source/job/readers/DPI/default-profile checks. These are bounded Windows fixture
results, not complete Goal/Reply/Composite/wired/selected visual parity, new
production persistence or a substitute for the two current qualified rasters.

The unfiltered current-source `v29` canonical invocation failed after 77 of 684
required units passed (961 actual executions). Its popup source checker still
inspected the forwarding wrapper instead of the shared input core. The corrected
checker retains the original mutants and independently checks default/strict
forwarding, strict null refusal and no replay. Subsequent 117-unit focused
results are not a completed canonical run and do not replace that failure.

The subsequent unfiltered `v40` failed after 53 of 684 required units passed
(350 actual executions): its capture adapter ran 182 cases, with 180 passing.
The app-child negative received an unexpected string-capacity exception rather
than its ownership refusal; the later report-gate negative then refused that
earlier failed case. Replaying the retained report inputs with a reversible
single-case data control establishes the latter dependency without changing
count or provenance guards. Wrong-refusal diagnostics now preserve the original
exception and script stack instead of discarding them. The exact canonical
capture adapter subsequently passed 182/182 in a selected invocation; the
capacity error did not reproduce, so its root cause remains unproved. A selected
runner's nonzero exit for missing mandatory full coverage is not an adapter
failure or a completed canonical result. Downstream `v40` units did not run.

The unfiltered `v43` passed 276 of 684 required units (1173 actual executions),
then failed the separate declarative popup source oracle. Its inline native
menu-state pattern had not followed the checked `ReadMenuHilite` extraction.
The corrected clause binds the actual core, sentinel refusal before bit
interpretation, both caller observations, reselection, fresh ownership and Enter
ordering; existing logging/receipt clauses remain intact. The current rebuilt
shared-menu source suites passed all 82 units, including all 58 declarative
predicates and 18 executions of the affected predicate/evaluator: one actual
source accepted and 17 mutations refused, including an unused safe-helper decoy
with unchecked callers. These are source/data checks, not native input evidence
or a full canonical pass. Downstream `v43` units did not run.

The distinct stale-mode fixture first qualified the ordinary same-child public
CLI Goal-to-Timed transition headlessly (`h31`), with nil child session callbacks
and no actual provider/session creation. Preparation failures `d32`/`d33`
launched nothing. Native `d34` stopped before the form because its caller supplied
the root project path to the nested target assertion; the correction uses the
child's own project path without weakening independent root/parent/child admission.
Native `d36` proved initial Goal pixels and the deliberate saved Timed transition,
then refused before submit. Its failed pixels/timing were not retained, so the
exact failing render term and cause remain unproved. Forward diagnostics retain
bounded numeric actual/expected pixels, original deadlines and named
identity/geometry terms before refusal; no retry or expanded budget is added.

Fresh `d39` passed the distinct stale-mode case in 1617 ms: captured Goal-to-Timed
form, ordinary CLI retype of that same child, exact saved mode plus owned-root
Timed type-square pixels, then strict old-form submit and the exact
context-changed/nothing-submitted status. Whole root and nested graphs matched
the independently read post-CLI baseline with custody intact. Source, private
jobs/readers, DPI and default-profile cleanup passed. This is not removed-node
coverage: `d07` remains failed/held. Three matching type-square pixels under the
retained modal do not establish whole-card raster parity or explain `d36`.

The separate `cards-zip-pilot` plan runs only three prototype cases: native picker
Cancel, Save/export of an unpiloted containing Composite, and Open/import on its
existing child Goal card. It does not replay retypes or run the other acceptance
cases. Its announced desktop reservation is required before process creation.
Its original filename entry uses the exact owned native filename edit's UIA
`ValuePattern` (not keyboard-input evidence); that route remains held after its
retained refusal. Folder navigation qualification does not repair it or authorize
a fallback. The compiled assembly loader initializes the signed, matching PowerShell runtime
client-side providers before UIA lookup. Registration uses the normal public API
through a non-inlined compiled caller, avoiding WPF's dynamic-caller stack
inspection failure. Path, version, token, signature, file bytes and loaded MVID
are checked; failures stop initialization without retry or private provider access.
Menu and Cancel/Save/Open buttons retain the
strict pointer route. The plan requires a unique absent ZIP path inside the owned
root; that legacy setter route's selected destination remains unproved and its
Save/Open publication remains held. The separately qualified native-primary
Save does not promote or bypass it. Windows MRU/recent state is outside the GraphCode
profile fingerprint; do not dump picker recent-file names into shared evidence.

The ZIP-only post-transfer barrier requires the normal App completion status and
the actual bundle/import effect, then validates the original held GUI birth and
job membership plus the exact classified active set. It retains raw cumulative
job totals and labels historical retired identity coverage `UNOBSERVED`.
This is `LIVEQUIESCENCE`, not original-root completion or proof of lifetime
backend absence. The two-retype predicate and existing cleanup authority are
unchanged. Import under the existing child Goal leaves three direct child nodes
and two direct edges, five recursive nodes and three recursive edges; the root
still contains one unpiloted Composite. The extra direct edge is the selected
Goal's spawn edge to the arriving Composite, not a flattened import.

The opt-in compiled runner argument `--native-popup-effect-fixture` composes the
existing owned STA WinForms fixture with test-only Win32 popup menu bindings. It
does not run in the default validation invocation. Its first-open, repeat-open,
and cancel/reopen cases use the production strict input core and the same
`TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON` flags as `GraphContextMenu`.
Success requires the actual selected command and callback count, not a click
receipt or popup dismissal. Execution stops at the first failure. Run it only
under the retained-process/private-job wrapper with source/profile guards and a
serialized desktop lease; foreground admission is bounded at 60 seconds and each
case retains its five-second budget. Caller and UI-thread DPI scopes restore
exactly. Admission records owned PID/visibility/enabled/foreground observations
on state changes and at most 16 relevant activation/button messages from the
owned fixture window. A Computer Use action reporting completion is not
foreground admission; all native predicate terms must still pass.
This is a same-process, different-thread native diagnostic, not proof of
cross-process application callbacks or Cards acceptance.

The isolated Cards retype pilot uses a precompleted-onboarding fixture, not a
first-run acceptance case. Before launching the ordinary production shell, it
creates the normal empty `onboarding-seen` marker with `CreateNew` only in its
resolved, owned support directory; redirected directories and foreign support
paths are refused. This follows the scrubbed-startup and shell-smoke fixtures
without enabling UIA product hooks. The original supervised foreground health,
identity, 60-second admission, and five-second input guards remain unchanged.
An admission refusal records the still-owned window flags and owned top-level
identities before cleanup and preserves the primary failure.
Card lookup reuses `Get-MultiProjectAutomationId` with the exact daemon root
project-path bytes and node UUID, including within a Composite child canvas.
Published card IDs contain the production hashed row key, not UUID text.
CLI exit notifications are not native exit authority: the pilot waits on the
original retained process handle using only the remainder of its single
15-second CLI budget, then samples raw private-job accounting before finalization.
Expired or unproved exits still refuse; no process is reopened or adopted.
Completed CLI ownership requires native root exit, empty original private job,
and drained readers, not an image census of already-retired descendants. Raw
totals are retained; missed retired identities are explicitly `UNOBSERVED`,
never inferred to be console hosts or evidence of lifetime backend absence.
Live barriers still reject unclassified active members. Backend prerequisites
are the unpiloted parent, initially idle children, zero session state, and the child
GraphStore's `onEnsureSession: nil`, not historical process-count guesses.
Goal retype deliberately persists `.running` in `GraphStore.promoteNode`; Timed
retype persists `.idle`. These logical postconditions are checked separately
from the initial idle fixture and do not establish that a backend session ran.

These results do not replace the final-source shell shards, native accessibility,
Swift/CLI gates, or the full compiled contract. The historical 578-requirement
compiled run predates the final merged runner. Required counts for a new run
come from the current manifests and feature registrations, not a forced
historical total. Desktop/native execution remains serialized by the
coordinator. Paired actual-size visual acceptance and real menu, picker,
transfer, and daemon acceptance/persistence evidence remain outstanding;
the parity ledger stays Partial.

The first final-source shard stopped in the App allocation-failure sweep:
`custody child popup optional snapshot allocation failures preserve generic
actions` reported `SwallowedOutOfMemoryError`. The optional transfer capture
correctly retained its error while preserving generic menu actions, but the
test adapter recognized only child and promotion capture errors. The adapter
now checks the transfer error, disabled transfer state, and refusal result
before reporting the induced OOM to the allocation sweep. Its independent
single-failure regression also requires transfer-only failure without losing
child creation or promotion. Both selected in-memory App tests passed in a
fresh process; no native window, menu callback, transfer worker, or transport
was invoked. The original full-shard failure and retained isolation directory
remain evidence. The corrected full three-shard run subsequently completed all
65 sections; the native accessibility provider completed 259 checks.
The canonical compiled runner then completed 605 requirements and 2,094 direct
executions, plus one separately counted derived proof, before the tray harness
changes below. The pinned Windows Swift transfer suite completed 33 XCTest
tests; its separate zero-test Swift Testing footer is not execution evidence.

The tray test now scopes physical geometry and input to thread-only PMv2,
restores the stable pre-entry context with exact native context comparison,
and reports success only after owned cleanup and restoration. Its 16
deterministic admission/restoration controls run in the existing integration
entry and as the compiled `ps.tray-admission` suite, with exact positive
execution counts in the manifest. Admission-only receipts are not full tray
passes.

Standard integration remains incomplete. Earlier attempts retained physical
coordinate refusal, exact-context restoration failure, and nested UIA path
budget refusal. Corrected default tray assertions, owned cleanup, and exact
restoration passed. An earlier short-root integration attempt stopped when a
competing launch logged `WorkspaceActivationFailed` in the unchanged main
startup path: Windows refused foreground activation. Cleanup and exact DPI
restoration succeeded; that attempt did not reach the UIA gate. A subsequent
standard integration passed competing launch and the full tray stage, then
stopped at the outgoing connector hover pixel assertion. The transient activation
refusal did not establish machine ineligibility.

A hidden owned DPI192 fixture reproduced the UIA harness coordinate mismatch:
the same physical point converted to client `(256,229)` under an unaware caller
and `(50,50)` under PMv2. Native and UIA bounds were virtualized together; a
reverse roundtrip alone did not establish physical coordinates. The UIA entry
now uses one thread-only PMv2 scope across queries, input, failure captures and
owned cleanup, followed by exact stable-pre-entry restoration. Seven registered
regressions cover native geometry, restoration, invalid/failed restoration,
foreign-thread refusal and script error/cleanup boundaries. The selected
`ui.native` suite completed 28 actual cases, including all seven; its exit 1
reports intentionally incomplete full inventory, not failed selected cases.
The earlier full compiled result of 606 requirements and 2,110 direct executions
predates this UIA helper change. Current-source canonical coverage and the
affected visible UIA entry remain pending. No foreground policy, production
activation behavior, coordinate scaling, ownership guard or hover assertion was
weakened; these results do not establish feature-native or visual parity.

### Pre-UIA process observation

The shell runner's pre-UIA CIM snapshot is advisory, not process ownership or
termination authority. Unexpected non-baseline repository-path candidates
stop validation before UIA with their PIDs and an explicit no-termination
diagnostic. Review the snapshot and use each process's owning session to stop
it. `no_candidates_observed terminated=0` permits the normal next step; it
does not attest global process absence or cleanup. Ownership failures set the
Boolean exception-data tag `GraphCodeValidationRootRetentionRequired`. The
isolation wrapper restores the environment but retains its exact run root for
that tag, records observed retained paths in `GraphCodeValidationRetainedRoots`,
and emits `WINDOWS_SHELL_VALIDATION_ISOLATION_ROOT_RETAINED`. Retention or
reporting errors are aggregated with the original failure and preserve the tag.
Restoration preserves environment key membership: originally absent entries
are removed, while originally empty entries remain present and empty.
Success and untagged failures keep the normal root-removal behavior. An inner
gate's retained-sandbox message alone is not proof of outer retention. At a
child-process boundary, a CreateNew UTF-8 `ownership-unproven.json` receipt in
`GRAPHCODE_VALIDATION_ROOT` binds schema version 1, that exact root, and reason
`ownership_unproven`. The reader enforces a 4096-byte limit; malformed,
oversized, mismatched or reparse receipts fail closed and retain the root.
The exact stdout fallback
`GRAPHCODE_VALIDATION_ROOT_RETENTION_REQUIRED=ownership_unproven` is propagated
by the runner into the Boolean exception tag, including terminating or
incorrectly zero-exit child results. Receipt or sentinel intent never
authorizes process termination.

Before that sentinel is emitted, shell ownership failures attempt a separate
CreateNew, flushed UTF-8 `ownership-first-failure.json` in the same validated
root. It records scalar primary ErrorRecord details, exception stacks and
signed HRESULTs, plus explicitly labeled secondary cleanup evidence when the
launch and its cleanup both failed. The projection is limited to 16 exception
branches and 64 KiB; omitted branches and unavailable native operands are
explicit, never reconstructed from PIDs or default values. The original
ErrorRecords remain attached to the same exception in memory. Projection or
write failure is attached without suppressing the independent retention
receipt, sentinel or lifetime hold. This diagnostic does not recover lost
authority, establish cleanup, or authorize another run.
The canonical shell ownership unit retains its 70 existing cases and requires
the seven named first-failure diagnostic cases exactly once (77 total). Its
unfiltered Pester payload includes controlled native launch fixtures as well
as mock/filesystem contracts; filtered headless results are not that full gate.

### UIA input and process ownership

The gate's direct shell and stub launches use the existing assigned-job
launcher barrier. The target cannot start before its retained launcher joins
the private kill-on-close job. Its published generation is checked through a
retained process handle and native job membership before accepting it as input
authority. Launch arguments remain separate values, the original gate working
directory is preserved, and stdout/stderr are streamed to the existing diagnostic
paths. Teardown terminates only owned jobs (or the retained, still-unreleased
launcher), verifies job emptiness and root exit, then drains readers before
releasing handles. An unproved survivor or reader drain retains the handles and
propagates the shared root-retention tag/sentinel; it is not verified cleanup.
No registered launch is reported as `not_needed`, not verified cleanup. Cleanup
continues across owned leases after a refusal, retaining original exceptions and
root-retention metadata across both phase and gate failure boundaries.
CIM path, parent PID, creation time, and baseline absence never authorize killing
or hiding a discovered process. Provider leftovers refuse explicitly, and a
zero-candidate snapshot is labeled observation rather than verified termination.

Activation uses no synthetic Alt or unowned foreground input-queue attachment.
It verifies a retained live process and the acquired foreground; failure remains
explicit. Target-control focus attachment is limited to the retained owned
window's thread; focus observation uses `GetGUIThreadInfo` without attachment.
Keyboard batches require the expected window/PID and owned focus immediately
before injection, including separate Delete and Unicode batches after
synchronous edit reads. Mouse batches recheck foreground, actual cursor, and
actual hit; submenu cursor movement is also ownership-gated. The gate never
hides foreign windows from a provider-path/title guess.

These checks and `SendInput` are not atomic. Focus, hit, or cursor can change in
the remaining check-to-injection interval; an exclusive slot does not remove
that race. Managed mock contracts and C# compilation do not establish real
foreground acquisition, job containment, glyph rendering, or native parity.
Existing reported message-based fallbacks remain distinguishable from genuine
input. The runner's UIA retention regression sends the actual UIA sentinel
producer through a real `pwsh` child into the extracted isolation consumer:
tagged exits 17 and 0 must retain the exact root. An ordinary exit 17 also
retains its root conservatively: once an isolated workload starts, an escaping
error cannot prove cleanup when receipt and sentinel transports are unavailable.
The original error and exit remain unchanged, with
`workload_failed_without_cleanup_proof` recorded for unclassified failures.
Success still removes the root; setup failures before workload entry keep their
existing cleanup behavior. It also checks environment membership/restoration.
Receipt-only cases suppress the producer's information-stream sentinel and
still require the actual consumer to retain/refuse at both child exit codes.
Expected mock refusals run with the enclosing validation-root variable absent,
and their synthetic sentinels are relabelled `UIA_MOCK_RETENTION_SIGNAL=observed`.
This prevents successful mocks from retaining or failing the outer validation
run; assertion failures and ordinary diagnostics still propagate. Registered
contracts cover absent, empty and valued environment restoration and an isolated
mock producer passing through the real `pwsh` consumer without outer retention.
The UIA producer delegates tag, observed roots and receipt publication to the
shared `Set-ShellOwnershipUnproven` writer, without initializing native jobs.
Managed/filesystem contracts cover valid, pre-existing, missing, non-directory,
empty and absent roots plus the actual writer under mock isolation. Receipt
write-failure evidence assumes the sentinel output channel remains available;
failure of both channels is not claimed recoverable.
An explicit mock counterexample forces child exit 0 after losing both transports:
the action succeeds and its root is removed. This is a residual limitation, not
evidence that a real producer swallows ownership errors. No universal
dual-transport fail-closed guarantee is made.
These boundaries do not exercise native jobs, product launch, or UIA input.
Full native execution still needs an
explicit release after every reachable runner path is assessed and integrated.

### Isolated process environment boundary

At isolated preflight/reader entry, `IsolatedProcessEnvironment.ps1` reasserts
only `PATHEXT` and `PSModulePath`, using the reviewed expected map and explicit
Process scope. It does not read User/Machine environment values, merge paths,
invent defaults, or write the parent process. The entry validates its approved
script path first. The full 30-key literal guard remains required, including
exact key membership and zero unexpected keys; later mutation is still refused.

The contract source provides `-Phase RED` (fresh-pwsh startup plus the old guard,
deliberately failing), `-Phase GREEN` (same startup plus process-local reassertion)
and `-Phase REGRESSION` (14 planned cases). Negatives cover missing/empty expected
literals, extra keys, other-key drift, post-reassertion mutation, wrong entry
path and refused User/Machine/Host target arguments. Child results contain only
fixed codes/booleans; synthetic maps and raw streams remain in owned `.build`
directories. Source preparation is not executed RED/GREEN evidence.

Recovery supplied these official-document excerpts and revisions; no new fetch
or independent documentation verification was performed for this correction:

- [about_PSModulePath, PowerShell 7.6](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_psmodulepath?view=powershell-7.6),
  MicrosoftDocs/PowerShell-Docs commit `f435f86004c327baf231bcca0ce689f94b98b798`:
  "The value of `$Env:PSModulePath` is constructed each time PowerShell starts.
  The value varies by version of PowerShell and how you launched it."
  "On Windows, `PSModulePath` is treated similar to how the `Path` environment
  variable is treated."
- [about_Environment_Variables, PowerShell 7.6](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.core/about/about_environment_variables?view=powershell-7.6),
  canonical commit `c4961eb5730e51304b82ed82fa663528f966c56f`:
  "The Process scope contains the environment variables available in the current
  process, or PowerShell session. This list of variables is inherited from the
  parent process and is constructed from the variables in the Machine and User
  scopes."
  "When you change environment variables in PowerShell, the change affects only
  the current session."

The documentation directly supports `PSModulePath` startup construction, not
`PATHEXT` rewriting. `PATHEXT` is included because the sealed Environment11
diagnostic observed ordinal5 unequal as well as ordinal7; neither was a
fresh-root rebind. That observation does not identify Inventory10's failing key
or a startup cause. The original Inventory10/Environment11 evidence and guards
remain immutable. Any corrected inventory entry must separately bind this
helper and preserve its existing source/IL/reference policy.

## Required PR checks

The macOS shared-regression, Windows shell, Windows port, and Windows hardening
workflows run on every pull request, including documentation-only changes.
Workflow-level path/branch filters must not prevent their required check contexts
from being reported. The compiled runner's CI contracts guard the unfiltered
triggers and require positive full coverage from the normal executable.
This deliberately trades additional CI usage for reliable branch protection.

Full-pinned and owned-environment hardening remain dispatch/schedule-gated as
defined in the workflow; they are separate evidence, not required PR contexts.
No merge-queue support is introduced.

The hardening workflow also runs **Native accessibility provider** on
`windows-2022` for pull requests changing `AccessibilityProvider.cpp`/`.h`,
`AccessibilityProvider.Native.Tests.*`, the hardening workflow, or the
classifier. The existing classifier emits `native_a11y`; documentation-only
changes skip this job, while unknown paths and classification failures run it.
This standalone native job does not install Zig or Swift and is separate from
the manually dispatched full-pinned gate. Its log reports the resolved vcvars
path and separate setup, compiler discovery, compilation, and executable exits.
An abrupt command exit names the last entered stage; success requires exactly
one `204 checks, 0 failures` summary. Both PR-native and full-pinned jobs first
run the mock-tool harness regression, which injects exit 255 at setup, discovery,
and compiler entry without compiling or running the native fixture.
The provider test itself exercises the native fixture, not physical keyboard input, a screen reader,
or visual/platform parity.

Repeated Swift environment initialization can grow inherited `PATH` until
vcvars fails with `The input line is too long` and abruptly exits cmd with 255.
The native harness removes duplicate entries case-insensitively, retaining the
first occurrence and order; it does not truncate unique entries. It restores the
exact original process `PATH` on success and failure. Logs measure its inherited
and deduplicated lengths and, after successful native execution, the actual
post-vcvars length including setup additions. Both launch boundaries must remain
below 8191 characters. The original hosted failure did not record a length.
[Issue #893](https://github.com/scgopi/GraphCode/issues/893) tracks the upstream
repeated-prepend problem; this defense does not change `validate.ps1`.

### Parallel CI layout

The required `windows-shell` and `windows-spikes` checks are aggregate jobs.
Each needs every part of its workflow and fails unless each part succeeded
(`Tools/windows/Assert-CiPartResults.ps1`). The one exception is when the path
classifier skipped the whole suite, in which case every part must be skipped.
Between them, the parts run exactly what `validate.ps1 -Task all` runs.
`ValidationRunner.Tests.ps1` dry-runs every pull-request `validate.ps1`
invocation and fails if the union loses a task, a shell shard, or a packaging
part.

| Required check | Part | Command |
|---|---|---|
| `windows-shell` | unit shard k of 3 | `validate.ps1 -Task windows-shell -ShellPart unit -ShellTestShard k -ShellTestShardCount 3 -ShellTestManifest ...` |
| `windows-shell` | integration: release build, smoke, tray, UIA | `validate.ps1 -Task windows-shell -SkipTrayLive -ShellPart integration` |
| `windows-shell` | packaging contracts | `validate.ps1 -Task packaging -PackagingPart contracts` |
| `windows-shell` | real-product packaging | `validate.ps1 -Task packaging -PackagingPart real` |
| `windows-spikes` | Swift spikes, production, format | `validate.ps1 -Task swift-portable,swift-contracts,swift-production,swift-paths,swift-process,swift-named-pipe,swift-format` |
| `windows-spikes` | remaining tasks | `validate.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E -SkipTask <the Swift tasks>,windows-shell,packaging,hardening` |
| `Deterministic hardening (...)` | hardening | `validate.ps1 -Task hardening` |

The integration part also requires six native smoke-exit controls: failing
nonreading-daemon smoke must emit its transport diagnostic and exit nonzero
through both the original stderr-file producer and owned capture; successful
requested smoke exits must remain zero through both producers. Requested
workspace actions must refuse when activation or the focus effect is missing.
All controls run
inside assigned owned jobs and retain evidence under the validation scratch root.

Run local GUI, keyboard, and pointer gates serially on one desktop; CI runs the
shards and integration job on separate VM desktops. Use a short, exclusively
owned `-ShellValidationRoot` for UIA lease paths. Keep Zig caches in stable owned
directories outside per-invocation `LOCALAPPDATA`, which isolation removes after
a successful run.

The real `windows-shell` task builds and validates the current compiled helper
assembly once when `GRAPHCODE_VALIDATION_ASSEMBLY` is absent, publishes it to its
child callers, and removes that process-only publication on exit. A supplied
assembly remains subject to current-worktree provenance; an explicitly empty
entry is refused rather than treated as a bootstrap request.

`windows-spikes` no longer re-runs `windows-shell`, `packaging` or `hardening`.
Those tasks already run in the `windows-shell` and `Deterministic hardening`
required checks on every Windows-relevant pull request.

The Delete-target `SelectionItemPattern.Select()` boundary emits
`UIA_DELETE_TARGET_SELECT_FAILURE` only after that existing call throws. It
samples the held target/pattern, expected shell PID/HWND, hashed automation and
runtime identities, bounds, offscreen/enabled/selected state, and the held
selection container's PID/role/hashed class. Foreign or unavailable identity
suppresses dependent reads. Retired, active, invokable and provider-branch state
remain explicitly unavailable; they are not inferred from other properties.
No target lookup, enumeration, action, wait, activation or input is added.
Successful Select and the following selection/command/menu/sheet behavior are
unchanged; diagnostic failures cannot replace the original exception's bare
rethrow. If projection completes, exception evidence contains at most four
numeric HRESULTs, not messages. The original HRESULT chain is projected only
after the UIA probes; this is not primary-first capture. An unexpected projection
failure may leave only observer-failure and original-error output, without the
structured record or receipt.

The observer allows at most 11 logical property reads within a 500 ms
cooperatively checked post-rejection budget; synchronous UIA reads and file IO
are not hard-cancellable. Successful probe values arriving at or after the
500 ms boundary are discarded as unavailable. Identity strings are capped at
4096 characters,
runtime vectors at 64 integers, and the primitive-only UTF-8 JSON at 8192 bytes.
An optional `DeleteSelectFailureReceipt` path defaults from the child-only
`GRAPHCODE_UIA_DELETE_SELECT_FAILURE_RECEIPT` environment setting. A diagnostic
run must bind a fresh fixed file outside disposable validation isolation:
When creation, writing and `Flush(true)` succeed, the receipt is written before
the original exception propagates through cleanup. The reported receipt hash is
computed from the in-memory UTF-8 bytes, not verified by rereading the file.
Projection, serialization or IO failure can prevent complete receipt retention.
Structured JSON is emitted on stdout only after projection, serialization and
the 8192-byte check succeed; an unconfigured/existing/unwritable receipt reports
a diagnostic failure without masking the Select exception. Success performs no
receipt-path/file IO.
AST-extracted `Test-DeleteTargetSelectFailureContracts` covers 21 managed cases,
including unavailable/foreign/drifting identity, cooperative deadline expiry,
bounded values, and receipt failures. Exact mock bindings are checked before
both Select calls. These contracts are not full ValidationRunner execution,
native diagnostic evidence, or proof of the cause of the live Select failure.

The normal unwired-recovery check requires both actions to be visible inside
the owned graph before the existing positive-bounds and Invoke checks. If needed,
it invokes the owned Fit canvas action once and reacquires the same action IDs
for at most 40 observations. Fit alone is not success: persistent offscreen,
empty, foreign, or out-of-graph targets fail explicitly. The extracted
`Test-RecoveryActionVisibilityContracts` uses mocked effects; it is not live UIA
or visual parity evidence.

**Shell unit shards.**
- `WindowsShell.Tests.ps1` derives its section catalog from its own top-level
  `Invoke-Native "<name>"` calls.
- It splits the sections into a deterministic longest-first partition using
  measured cost hints. Sections that consume the prepared terminal VT library
  stay in the same shard as the section that prepares it.
- Every `zig test` in a section must print a positive passed count.
- Each shard writes a manifest. `Test-ShellSectionManifests.ps1` then proves
  that every catalog section ran exactly once across the shards.
- Local runs without `-Shard` still run every section serially.

**Packaging.** Real packaging rebuilds its own inputs on its runner: the Swift
release products and runtime, the pinned Winghostty host library, and the zmx
package fetch. It does not download artifacts from the shell integration job,
so the two run in parallel.

**Caches.**
- The pinned Zig toolchains are cached, keyed on `bootstrap.ps1`.
- Provider checkouts and the Zig global cache are cached, keyed on
  `provider-pins.json`, `bootstrap.ps1` and the build flags. Only the shell
  integration job saves this cache.
- Bootstrap still fetches and checks out each pin.
- `Assert-ProviderCheckout.ps1` re-verifies each provider's pinned SHA and
  clean tree after a restore.

**Official gobject prefetch for the required Swift real-zmx test.**
`Initialize-GobjectPackageCache.ps1` downloads only official release asset
493157198 through GitHub's asset API using the existing read-only job token.
It requires 1,867,503 bytes and SHA-256
`D572886E8672A46AC6C740E3FE3A1F1C9D9A1A9F09D59FD62328A41FCDB70196`
before the pinned Zig 0.16.0 performs a local, no-save fetch. Network and
fetch deadlines are 60 and 120 seconds respectively, without retries.

Zig 0.16.0 requires a build-root context even for `fetch`, so this helper uses
a fresh private directory with a zero-byte `build.zig`, not a provider checkout.
The fetch must return exactly
`gobject-0.3.2-Skun7F6HogCMynX2JqeSHS7xr-8pK4ob-qRFIcEasVi3`
with complete original held-job cleanup. Only then does it publish its fresh
job-owned `ZIG_GLOBAL_CACHE_DIR`. Zig's normal provider build reads the
hash-addressed `p/HASH.tar.gz` there before a remote fetch and verifies the
package content again. No local cache is transferred, manifest or pin is
changed, or acquired build script is executed during prefetch. The existing
required `Test-RealZmxEmptyList.ps1` build/test remains unchanged and mandatory.
The Swift job compiles existing ownership bindings but does not execute another
validation runner. Verification receipts, private context writes and original
worker streams are retained on failure as well as success. The headless
helper announces and flushes the existing root-retention marker before an
unknown-ownership lifetime hold. Its managed propagation contract uses the
source-bound observer (`WindowsCiTopology.Tests.ps1 -RetentionPropagationOnly`
with `GRAPHCODE_VALIDATION_ASSEMBLY` set to the current canonical build);
it does not start a native lifetime hold. The headless
byte/hash, argument transport, refusal and job-order contracts run through
`pwsh -NoProfile -File Tools\windows\Tests\WindowsCiTopology.Tests.ps1`;
they do not establish a successful current-head provider build or XCTest run.

**Timeouts and cancellation.**
- Every Windows job has a `timeout-minutes`.
- A newer push to the same pull request cancels the older in-flight run.
- Runs for any other event use a unique concurrency group, so they are never
  cancelled.

## Automatic selected-pane restoration qualification

The observation guards `Assert-UiaUnrepairedTerminalFocus` and
`Assert-UiaTerminalChallengeOutput` in `uia-live-gate.ps1` have headless contracts
in the existing `Tests\TerminalGate.Tests.ps1` entry point (20 executed cases).
They reject absent, duplicate, foreign, background, stale, or nonexclusive focus,
require a nonzero selected pane in a **persisted-layout-ordered** roster, and
reject stale nonces, command echoes, duplicate output, wrong arithmetic, invalid
shell PIDs, or nonce output on another pane. The opt-in
`-RestoredTerminalInputOnly` route now calls these guards, with 25 additional
mock/source/managed-file adapter cases in that same headless entry point.

**Integrated observer source binding, not a new native qualification:**
`Assert-UiaRestorationPeerCapability` binds `UiCaptureDriver.psm1` to SHA-256
`35B3985DDF7C7EAAC6360AE90917BF143DA633CF03E687F5214AE4CD89C1F297`.
This integrates main's Wire merge `1aa4a225` with M3's `df0a80cc`,
`2379a614`, `8aec6ba1`, and `d621c494`; the read-only peer method is unchanged.
The previous module hash `B499EA0F` belongs to the historical M3/51c tuple,
not these integrated module bytes. Preflight checks
those source bytes, requires a fresh helper load, and requires the actual
`PipeServerProcessId(SafePipeHandle)` method. Different bytes still refuse
before resource creation; there is no command-line waiver. The default startup
imports the shared module normally; the opt-in route imports it only through
its preflight and then runs `Initialize-CapUiaClient` with its own current
source-bound assembly before any UIA/native route work.

The coordinator qualified M3 source `d621c4948b5b5ee2172e4ab9ae6e8c9db9bf6857`
with its actual All-five receipt at `D:\np5b\s\report.json`, SHA-256
`217703BE1ED8FFA0DE346EC062BB052DF21A30C04F2104384CEFC79E58361F4C`.
Its terminal receipt hash was
`09A0DC3A9B54F2B95EFDC488E64CC3144D08372CD3A722497FACEA0834ED2AD7`;
elapsed 3.443 seconds, all six cleanup booleans true, original held child PID
27920/generation 134384774974541102 matched both kernel queries, with three
matched payload bytes and preserved nonpipe error 6. This is the original
**M3 tuple**, not a rerun or M2 app/provider/daemon qualification. The earlier
`np5`/`8aec6ba1` failure remains failed. The imported test source hash is
`0328888460DB9F6E859C82C4B12D93A2DE15AA5DE1A6D2B1E1B02F309B01D9DF`.
That test hash is historical too; integrated tests also contain main's compiler,
hierarchy, Create, and image-buffer contracts. The compiled CaptureSuite retains
all prerequisites: peer 5, compiler 27, hierarchy 32, Create 15, image buffer 9.
The accepted restored-pane run at `51c71b9b` remains historical execution
evidence only. Main changes product and native image/window surfaces, so a new
integrated source-bound build and separately admitted functional rerun are
required before claiming this head is natively qualified.

The normal default UIA gate sets synthetic fixture and
connection-failure flags and uses its identity-file/PID-reopen launcher. It
does not establish real-daemon/session restoration and is unchanged. The new
route returns before that default path and uses `ShellProcessOwnership.psm1`
suspended original launches and retained jobs, private profile/support/temp,
explicit child environments with no inherited UIA or synthetic workspace flags,
and normal production CLI commands. Since Swift's zmx locator ignores `PATH`,
the route stages the admitted provider bytes in its private support `bin` and
rejects a different provider beside either Swift executable.

It registers its own project, obtains the canonical project path using
`projects --json`, creates/stops one attended main loop, then starts two real
pinned-zmx `--daemon` roots with separate held launch jobs and distinct
shell-computed nonce/PID/arithmetic markers. Stopping the loop prevents opening
it from launching an agent backend. The test prepares the existing schema-v2
layout and shell ownership record with **pane zero initially selected**; this
setup is not evidence that the product created a split. Only the first window
uses the normal pane-focus action to select pane one and waits for the product
to persist it. The original shell exits through its normal tray Exit command;
its original root and attach job are finalized before a new held shell is
launched. Both separately owned seed roots must remain alive.

Each opening uses normal project/loop UIA actions. Every current owned
Winghostty provider is mapped to its session by actual TextPattern marker
content, never screen order or a generic ID. The persisted pane/session order
then identifies the expected selected provider. After reopen, actual UIA and
native keyboard focus must already match it exclusively. There are no pane
SetFocus calls, pane clicks, setters, or forced foreground recovery after
reopen. Guarded `SendUnicodeInput`/`SendKeyInput` require the retained shell,
foreground HWND and exact current pane HWND; a fresh shell-computed response
must appear on that provider and not the other one. Printed PIDs are data
witnesses, never process-control authority. The read-only peer query proves
only the observer connection's server, not the shell's separate pipe handle.

Coordinator/executor invocation **after** own source-bound guard/build custody,
source/binary admission and a serialized native lane:

```powershell
pwsh -NoProfile -File Tools\windows\uia-live-gate.ps1 `
  -RestoredTerminalInputOnly `
  -Shell (Join-Path $PWD 'graphcode-windows\zig-out\bin\graphcode-windows.exe') `
  -Daemon (Join-Path $daemonRuntime 'graphcoded.exe') `
  -Cli (Join-Path $daemonRuntime 'graphcode.exe') `
  -Zmx (Join-Path $env:GRAPHCODE_ZMX_ROOT 'zig-out\bin\zmx.exe') `
  -RestorationRoot D:\gc-m2-restore
```

`$daemonRuntime` is the current worktree's staged Swift release runtime returned
by the existing canonical build, with its matching runtime DLLs. The restoration
root must be a new, short, private absolute path. The executor must establish
binary provenance against the admitted source and provider pins; recorded input
hashes alone do not prove which source compiled a binary.

Work shares the original 20-minute case clock and protects a 90-second cleanup
reserve. Existing bounded waits are clamped to that clock; UIA/OS calls do not
acquire a kernel scheduling guarantee from a stopwatch. Cleanup uses the
original scope/job API to require zero owned survivors and pipe EOF, retains
independent stdout/stderr logs for each original launch, and holds lifetime
authority indefinitely on UNKNOWN instead of discovering/killing by PID or
name. On incomplete teardown, buffered output is retained as separate
`.stdout.partial.log` and `.stderr.partial.log` files, without an EOF claim.
Success evidence is emitted only after cleanup completes. Failures and setup
artifacts remain in the owned root. Headless passing
cases are not native input, persistence, provider, glyph, agent-backend, or
whole-parity qualification; the native result remains pending.

## Winghostty fork

`Tools/windows/bootstrap.ps1` checks out the public provider at the exact commit in
`graphcode-windows/provider-pins.json`. The GraphCode gates invoke its real build and
host contracts:

| Surface | Required command |
|---|---|
| Pinned provider build | `pwsh Tools/windows/validate.ps1 -Task windows-shell` |
| Build-only pinned provider compile (no tests; CI cache seeding) | `pwsh Tools/windows/validate.ps1 -Task provider-build` (not part of `-Task all`; `terminal-gate` runs it first) |
| Host lifecycle and rendering contracts | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |
| Interactive Win32 smoke | `pwsh Tools/windows/validate.ps1 -Task windows-shell -SkipTrayLive` on hosted runners; omit `-SkipTrayLive` on an owned interactive desktop |
| Embeddable one/two-surface stress | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |

## zmx fork

The same bootstrap checks out zmx at its exact public pin. These gates exercise the real
provider rather than a placeholder implementation:

| Surface | Required command |
|---|---|
| Pinned provider build and smoke | `pwsh Tools/windows/validate.ps1 -Task terminal-gate` |
| GraphCode terminal behavior | `pwsh Tools/windows/validate.ps1 -Task windows-shell -SkipTrayLive` |
| Windows CLI compatibility | `pwsh Tools/windows/validate.ps1 -Task hardening` |
| Agent/session compatibility | `pwsh Tools/windows/validate.ps1 -Task all -SkipTrayLive -SkipWslRemoteE2E` on hosted runners |

## Shell request correlation

The shell gate and real-product hardening delay stub replies by 150 ms to exercise
project-subscription changes with requests still outstanding. The normal stub uses
the production listener's 64 KiB pipe buffers; the separate non-reading fixture
retains zero-sized buffers to exercise backpressure.

Subscription reconnects drain pending v1/v2 responses before closing the pipe,
bounded by the existing 1.5-second negotiation interval. Explicit reconnect and
close actions do not wait for that drain. The native tests also verify that
repeated subscription changes cannot extend the deadline.

Smoke actions wait for their connection/selection or workspace after the
earliest action tick instead of being lost when that one tick arrives too
early. Enqueuing an action resets the idle-exit counter. Large-paste resource
sampling waits for the owned `pwsh` attach and continues through the active
workload so the trend uses per-process peaks, not one startup instant.
Readiness, sampling, and completion share the same eight-second budget.

`STUB_DAEMON_EVIDENCE_JSON` records request/response counts, unanswered IDs and
commands, and the stub error before assertions run. Failed repeated hardening
prints its captured child output rather than discarding it. Session/resource
tracking uses exact test-owned CIM process matches and their descendants, not a
global `zmx list` that can hang on unrelated sessions.

Real high-output timeouts also emit `HARDENING_OUTPUT_DIAGNOSTICS_JSON`: captured
byte count, independent start/end marker offsets, attach/capture state, and at
most 512 bytes from each end of the synthetic transcript. This does not change
the payload, hash checks, or completion deadline.

Completion markers are located after ANSI and line-ending normalization, just
like the payload: ConPTY may insert color/title sequences or wrapping inside a
marker. Regression fixtures cover fragmented markers, multiple OSC titles,
incomplete/reversed markers, and empty completed output. The exact normalized
4 MiB length and SHA-256 checks still decide whether the payload passes.

## Remote SSH

Remote validation uses controlled POSIX hosts and sanitized fixtures:

- local bridge unit/security tests;
- mandatory-by-default deterministic local Windows-to-POSIX parity fixture covering setup,
  fan-out, messaging, reconnect, restart/reboot restoration, multiple hosts,
  generation monotonicity, and capability non-disclosure;
- Python shim protocol fixtures;
- SSH reconnect and stale-state tests;
- manual or protected CI tier for real remote-host execution. Set
  `GRAPHCODE_REMOTE_E2E_TARGETS` to comma-separated authenticated `user@host:port`
  values; configured targets are mandatory and failures fail the run. Empty entries
  are rejected.

Public GitHub-hosted Windows runners do not provide a configured WSL distribution.
Those workflows pass `-SkipWslRemoteE2E` explicitly, which skips only the WSL-backed
local fixtures; parser and protocol-independent remote E2E checks still run. Developer
and WSL-capable validation defaults remain fail-closed and run the complete fixture.

Credentials, hostnames, and capability tokens belong in runner secrets and never in the
repository.

## Final hardening executable matrix

The `hardening` task is mandatory and always runs deterministic local fixtures; it
does not turn into a pass when an environment is unavailable. The current measured
ceilings are:

| Dimension | Fixture and threshold |
|---|---|
| High output/backpressure | 4 MiB lossless output in <=10 seconds |
| Long duration | 3-second session completes in 2.5-10 seconds |
| Crash recovery | exit 17 is observed, then a fresh session succeeds |
| Multi-terminal | four concurrent 512 KiB sessions complete in <=15 seconds |
| Unicode/hostile paths | UTF-8 clipboard text round-trips through a >=180-character Unicode path |
| Process cleanup | fixture process count returns to baseline |
| Real product output/session | pinned zmx/ConPTY writes exactly 4 MiB plus a completion marker; session exit code is 0 within 90 seconds |
| Real resource ceilings | private memory <=512 MiB; per-run handle growth <=256; three-run private-memory range <=32 MiB and handle range <=64 |
| Repeatability | three consecutive runs; each reports process, handle, and private-memory deltas and all must pass |

GPU/WGL, real ConPTY/zmx reconnect, screen reader/UIA, physical DPI/display,
authenticated SSH, login/reboot, and installer ACL tests are environment-only.
They are explicitly gated by `Hardening.Tests.ps1 -Environment` and a runner-owned
PowerShell harness supplied through `GRAPHCODE_HARDENING_TARGET` (the repository
fixture is `Tools/windows/Tests/EnvironmentFixture.ps1`); selecting that
tier without the harness fails. The
deterministic tier remains mandatory on every pull request. The scheduled full
workflow runs the pinned provider/package lifecycle gate and cannot substitute a
skip for a missing provider.

The environment harness emits `schemaVersion=1` JSON with one result for every
mandatory dimension. A skipped dimension must include a non-empty reason.
Hardening includes RED checks proving missing dimensions and reasonless skips are
rejected; the deterministic Named Pipe fixture is reported separately.

The Windows host cannot execute macOS tests. `.github/workflows/macos-shared-regression.yml`
is the authoritative macOS matrix (`swift test`, `make test`, `make check`); only
the portable Swift package is executable locally on Windows.
