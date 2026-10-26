# Matched v12 capture scenarios

`S_MATCHED_V12_V1` is an additive adapter in the existing
`Invoke-UiCapture.ps1` / `Invoke-UiCaptureWorker.ps1` pipeline. It does not grant
a desktop lease, replace the B/D adapters, or change the product. Preparation,
fresh builds, current CI admission, a separately warned capture lease, individual
image privacy checks, and one subsequent paired review remain required.

## Lease ceiling and scene budget

The production lease ceiling is **30 minutes**, not a new lease grant or an
extension of an existing allocation. A caller's smaller `maxMinutes` still
limits its lease, and future-dated or expired leases still refuse. The worker
deadline remains exactly the declared expiry minus **90 seconds**; validation
never restarts that clock. Per-scene timeouts and strict deadline clipping are
unchanged, so even an admitted planning estimate does not guarantee completion.

Both matched S and D scene contracts accept at most **1710 estimated seconds**
(`30 * 60 - 90`). They still require the exact 90-second cleanup reserve.
The matched job still requires all eighteen scenes per phase, thirty-six
images, twenty-two cmd-only seeds and two real-daemon Restart scenes.

Lane T extends existing lease and scene-budget contract groups without adding
or removing a top-level group: **delta 0 default / 0 real-seed**. On its combined
base the registered totals remain **175 default / 178 with `-RequireRealSeed`**,
including all eight S groups and the unchanged fourteen-subcase G group once.
The historical standalone Lane S totals below describe its own delta, not the
current combined-tree qualification. A later C8 preparation must re-pin merged
tooling and rerun its exact declared qualification count before preflight and
a separately granted capture window. No subset or skipped-scene support is added.

## Scene-bound seed receipts

Lane S2 adds **two top-level groups**, taking the combined registered totals
from **175 to 177 default**, or **178 to 180 with `-RequireRealSeed`**.
At the S2 checkpoint, `Tests\ValidationRunner.Tests.ps1` required exactly 177 passing groups and the
unique presence of the original eight S groups plus both S2 groups. The then-current live matched preflight required exactly 180 passing groups, zero skips, and the same
unique groups; a higher count is not accepted.

Those **177 / 180** totals are the pre-DPI historical boundary. The
`S_MATCHED_V12_DPI_V1` harness change adds four no-desktop top-level groups,
so that merged-source registration became **181 default / 184 with
`-RequireRealSeed`**. The action-budget repair adds one no-desktop real-worker
contract, making current registration **182 default / 185 with
`-RequireRealSeed`**. Current matched preflight requires exactly **185**,
zero skips, the ten existing matched/S2 identities once, and all four DPI
identities once. Historical reports retain their original denominators.

## Live transition rehearsal

`LIVE_TRANSITION_REHEARSAL` is a no-lease, non-evidence mode for exercising the
complete real matched transition sequence before one separately authorized
capture. It requires a hash-bound rehearsal authorization with
`authorizedAction=live-transition-rehearsal`,
`captureEvidenceAuthorized=false`, and `pngAuthorized=false`. It still consumes
the exact 185-case preflight and uses the real UIA, pinned zmx, daemon, process
identity, deadline, numbered-journal, and zero-survivor release paths.

The worker replaces each image operation with an immutable typed checkpoint. A
successful matched run requires exactly **36 checkpoints**, **22 cmd-only
seeds**, **two real Restarts**, one proven `before` to `after` cleanup
transition, `images=[]`, `captures=0`, and no `.png` anywhere below the fresh
owned root. Every checkpoint and final manifest is classified
`LIVE_TRANSITION_REHEARSAL_NOT_CAPTURE_EVIDENCE`.

This mode is refused by the matched capture-manifest gate and must not enter a
capture report, privacy review, parity ledger, or evidence publication. It can
identify tooling and observer defects only; passing it does not authorize
capture or establish parity.

Every scene action and its associated visibility probe now waits for at most
**10 seconds** and must stop at least **30 seconds before the worker deadline**,
whichever comes first. The calculation holds one additional second ahead of
that published reserve so the final bounded poll sleep cannot consume it.
Deadline selection uses UTC `DateTimeOffset` arithmetic. If the target never appears,
the worker retains time to stop held process generations, publish the terminal
journal and bind the failed manifest; the supervisor must release
`FAILED_ZERO_SURVIVORS`, not `CLEANUP_UNPROVEN`.

## Numbered journal moving head

The supervisor's live journal read accepts the verified monotonic snapshot selected
at the start of its bounded transaction. Publications that arrive while that
snapshot is being decoded are recorded as the next observed floor and are consumed
by the next 200 ms supervisor poll; they do not force the current transaction to
chase an indefinitely moving head. Open retries remain limited to the existing
eight attempts, seven retries, one-second I/O budget, and absolute caller deadline.

This preserves fail-closed behavior: a missing highest-observed publication,
corrupt bytes, foreign binding, stale removal, sequence regression, or expired
deadline is still refused. Quiescent final verification still reopens every
numbered publication, verifies the complete predecessor hash chain, binds the
canonical final stdout record, and requires exact kernel-exit and stream-EOF
cleanup evidence. The correction adds no capture scenes or top-level preflight
group, so the registered totals remain **182 default / 185 with
`-RequireRealSeed`**.

An owned journal actor can exit after the worker publishes its generation but
before the supervisor opens a retained handle. The supervisor defers only the
exact typed initial-handle race when the recorded PID is unchanged and current
metadata is absent. It does not infer exit: the final numbered journal must
still bind that generation to the worker's held-handle kernel-exit receipt and
its owning stream EOF or contained-job file-closure proof. Foreign, live,
stale/reused, and partially classified identities remain refusals.

## DPI-parametric matched adapter

`S_MATCHED_V12_DPI_V1` preserves the V1 fixture, eighteen scene names, actions,
real Restart requirements, process ownership, privacy and cleanup gates. It
changes only the geometry/evidence contract.

The job separates logical and physical geometry:

- logical client 1440x900;
- actual window DPI 192, base DPI 96;
- physical client 2880x1800;
- `AdjustWindowRectExForDpi` outer 2906x1910 for
  the source-requested `WS_OVERLAPPEDWINDOW | WS_CLIPCHILDREN` frame and an
  installed menu;
- separate baseline/current identities generated from each phase's exact
  `MainWindow.zig` source commit. Both C7 baseline `a8b09434` and current source
  request outer 1280x820 with style `0x02CF0000` and extended style 0;
- exact post-creation Win32 identity: shown style `0x16CF0000`
  (`WS_VISIBLE` and the system-added `WS_CLIPSIBLINGS`) and extended style
  `0x00000100` (`WS_EX_WINDOWEDGE`);
- measured fit inside a physical work area at least 2906x1910;
- no resampling.

The supervisor performs the work-area calculation before worker launch. It
temporarily enters per-monitor-v2 awareness on the calling thread, selects the
primary monitor natively, and reads `GetMonitorInfo` work bounds in physical
pixels. This preserves taskbar exclusion and physical virtual-screen origins
without deriving bounds by multiplying DPI-virtualized Windows Forms values.
The worker enters a temporary per-monitor-v2 caller context for `GetWindowRect`,
`GetClientRect`, `SetWindowPos`, and `PrintWindow`, restoring the prior context
after every operation. It first requires the exact physical initial identity:
outer 1280x820 and client 1254x710 at DPI 192, with the phase's exact
post-creation styles and menu. The failed pre-fix observation
outer `[49,49,689,459]`, client `[0,0,627,355]` was the same window viewed
through DPI virtualization; the physical query is `[98,98,1378,918]` with
client `[0,0,1254,710]`. The worker then derives the target frame from that
phase's source identity, positions it in the native physical work area, and
remeasures exact physical client and outer bounds before any scene action.
The native `CapWindowSnapshot` is copied at that validation boundary into the
existing complete `PSCustomObject` record, preserving both bounds arrays,
64-bit DPI/style values and the Boolean menu flag. Dictionaries, missing or
null fields, and wrong array, numeric or Boolean types still refuse.
Foreign style, extended-style, menu, client, or outer identities still fail
closed. A genuinely physical 1920x1032 RDP mode refuses before product launch;
a 3840x2064 physical work area remains admissible when Windows Forms reports
its DPI-192 logical equivalent as 1920x1032.

UIA bounding rectangles remain physical pixels. Actual-size zoom normalizes
the physical width by `96 / actualDpi` before comparing with the card's 250
logical-pixel natural width. A 500-physical-pixel card at DPI 192 is therefore
250 logical pixels and 100% zoom; the old unnormalized 200% interpretation is
a negative contract.

Geometry schema 3 stores separate `before` and `after` source identities; an
assembly must generate each identity from the exact source commit used to build
that phase and bind it to the phase binary's source fields. This preserves C7
baseline semantics instead of substituting current-source assumptions.

Each image retains the raw PrintWindow bitmap and records logical client size,
physical client/outer bounds, nonclient extents, raw pixel dimensions, actual
DPI and scale, adjustment/runtime styles, menu state, physical work area,
placement and `resampled=false`. The evidence classification is
`C8R_RDP_DPI192_QUALIFIED`.

The four focused groups cover:

| Group | Boundary |
| --- | --- |
| DPI exact frames | C7/current source-derived identities, the exact virtualized failed observation, physical 1280x820/1254x710 initial geometry, and 96-DPI 1456x959 / 192-DPI 2906x1910 target frames |
| DPI refusals | stale style/ex-style, one-pixel client mutations, insufficient/one-pixel-short work areas, non-integral scaling and wrong adjusted outer |
| DPI logical zoom | physical-to-logical normalization and the old unnormalized mutant |
| DPI manifest | 36 simulated raw records and DPI/resampling/logical/work-area mutations |

These contracts launch no GraphCode window and capture no images. A future live
run still requires a source-reviewed job, exact 185-case preflight, warned
one-attempt lease and sufficiently large DPI-192 RDP work area.

An exact macOS @2x 1440x900 logical reference has a 2880x1800 client raster and
may be reviewed against the raw Windows client at native 1:1 pixels without
resampling. Such review may support observed layout/state/action findings, but
not physical input, local-console compositor equivalence, native local glyph
or antialiasing fidelity, focus outside the observed RDP session, or automatic
row validation. Unmatched scenes remain logical-geometry-only or unassessable.

Matched S seed receipts use the initialized `Roots.Root\zmx-seed.json`, not a
path rebuilt from the diagnostic phase label. B and D retain their existing
normal and per-session receipt layouts (D seeds share an app root). That directory is
ensured before launch; initial, exit and final writes retain the same owned
path. Final cleanup records `NOT_CREATED` and `CLEANUP_UNPROVEN` if the initial
receipt was never published, without inventing a file or a clean result.
Native job closure and receipt/stream publication remain distinct.

The worker performs a **post-termination held-handle exit wait** after the
existing owned-job termination/empty proof and before the unchanged kernel-live
refusal. Its original live-image attestation is bound to the same retained
handle, PID and creation time; the wait rechecks native PID and creation time
without querying a terminating image or looking up a PID. Termination, `WaitForEmpty` and this signal wait
share the original **5000 ms** monotonic window, started immediately before
`Terminate`; no new timeout is added. Receipt `launcherExitWait` records the
remaining wait budget, actual signal observation latency and timestamp. A
timeout retains null signal latency and still refuses; the observed latency is
not an exact kernel exit instant. The existing daemon-descendant held-pipe
design still terminates its owned job; there is no pre-close natural-exit wait.

The first new group runs the actual worker seed writer and cleanup for
`before-s-tabs-goal-needs-you`, plus an actual blocked-first-write refusal.
The second walks all **18 scene names x 2 phases = 36** through real directory
creation, actual worker receipt writes, owned job cleanup and scene-local
filesystem removal, preserving a sibling sentinel. Both use a hidden harmless
native target deliberately exiting 23 before daemon readiness, not real seeds,
Restart, UI actions, capture or parity proof. Only journal payload construction
is narrowed; the seed launcher, atomic writer and cleanup functions are not
replaced.

Within the first group, deterministic delayed-signal and spent-budget refusal
controls invoke actual worker `Close-CapOfflineSeed` with a real held fixture
process. Its close-job return boundary and elapsed clock are injected and
explicitly labelled as **not native job-empty/termination evidence**. Those
controls have real, separate owned safety-job/EOF teardown, including a held
PID/creation exit wait sharing the safety cleanup's own five-second deadline,
anchored before its actual job termination, not the injected worker clock.
The matrix and seed-path lifecycle cases use the unmodified actual job closer,
not that injection.

The budget contract compares the **actual milliseconds passed to the native
`WaitForSingleObject`** with the original Terminate timestamp, unchanged
five-second deadline and native monotonic configuration timestamp captured
after identity validation. It requires exactly
`max(0, floor((deadline - configuredTimestamp) * 1000 / frequency))`, with no
reset or extra budget; fresh-window, changed-origin, fresh-5000 and one-ms
overspend mutations must refuse. The receipt retains these native arguments.
The spent-window control injects 4000 ms already elapsed at its test timestamp,
then delays 200 ms before the actual worker/native configuration. Its earlier
test-budget sample is diagnostic only: neither that separately sampled value
nor an arbitrary `<=100` cap defines the native argument. A second control
injects a fully spent 5000 ms window and requires an actual zero-millisecond
wait, an unsignalled held root, null signal latency and the unchanged kernel-live
refusal. These controls remain inside the existing first S2 group: **delta 0**,
with the S2-checkpoint totals still **177 default / 180 real-seed**.
Wall observation is separate: a deterministic 1500 ms delay after actual Close
reproduces the old strict wall-time assertion, and a documented 5000 ms
observational scheduling tolerance applies only to that wall measurement
(5000 ms window + injected delay + tolerance). It never changes the native
argument check, kernel-live refusal or production window.

CI artifact patterns retain the legacy `gc-ui-capture-*` paths and additionally
match exactly `g` plus eight lowercase hex characters under the declared capture
TEMP root, with the same file types and `.git` exclusions. A filesystem-only
contract requires positive current/legacy file selection and refuses unrelated
roots; it is not proof of an actual hosted upload.

Artifact path parsing accepts both LF and CRLF workflow text without including
the CR terminator in a literal path. It does not trim path whitespace or alter
`!`, case or wildcard characters. Each line-ending variant must contain the
exact same inclusion/exclusion multiset; duplicate, private-path, missing-`!`
and trailing-path-space mutations refuse. Fixture inventories are derived from
explicit files written under current, legacy and unrelated roots, including
root-level and nested `.git` sentinels. They assert exact included and excluded
relative-path sets with no missing or extra files. This is a literal-pattern,
PowerShell root-wildcard and explicit `.git` partition contract, **not** a
translation or execution of the Actions glob engine or proof of hosted upload.

Default test scratch leaves and the registered capture scratch leaf are short
`g` plus eight hex characters to leave room for the unchanged 240-character
zmx lease-path guard. Existing roots refuse rather than being adopted or
overwritten; both allocation entry points have marker-preservation negatives.
Explicitly supplied overlong scratch paths still refuse.

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -PrepareFixturesOnly -ScratchRoot D:\owned\seed-fixtures

pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -SeedPathContractOnly -ScratchRoot D:\owned\seed-paths `
  -PrebuiltFixtureManifest D:\owned\seed-fixtures\fixtures.json `
  -PrebuiltFixtureManifestSha256 ACTUAL_64_HEX_SHA256
```

Use a short, fresh owned scratch root and the actual manifest hash. Frozen C8
remains `CLEANUP_UNPROVEN`, with 6/36 images; this repair neither reviews those
images nor upgrades that historical result. C8R requires fresh authorization
and qualification.

## Counts and registration

The standalone Lane S change adds **eight top-level groups exactly once**:
**166 + 8 = 174 default**, or **169 + 8 = 177 with `-RequireRealSeed`**.
The three existing actual-zmx rehearsal cases are unchanged; the real-seed
top-level delta is **zero**. No old group or negative case was removed or
relabelled. Its original registration required 174 and the unique
presence of all eight names; the historical S2 totals above superseded that total.
A different total is a failure, not an empty-filter
pass. A later merged change with its own declared delta requires an explicit
combined-tree count update and registered-runner rerun.

| New group | Bounded subcases |
| --- | --- |
| Typed fixture inventory | Eight wire nodes, six qualified card-state records; unchanged graph publication through the actual B peer on a real local pipe; actual worker persistence of the isolated Restart graph and recent-project index |
| Fixture refusals | Fourteen identity/type/status/wiring/reason/selection/resolution/size/branch/source/date/duplicate/required-project-date mutations |
| Scene inventory | One accepted complete inventory; eighteen omission refusals; actual worker's seventeen static-scene/eleven seed/one Restart dispatches with simulated dependencies |
| Tab observations | Eight positive shapes and ninety-four negative mutations of exact owned IDs, parents, names, selection, order, missing/foreign/duplicate rows, close bounds, final-tab eligibility and visibility |
| Restart evidence | Two simulated positive transcripts (including UUID casing and response-embedded graph data) and nineteen strict refusal mutations |
| Restart route | Actual worker function, one simulated positive and one offline-authority refusal; actual pending helper returns null for two incomplete files, retains both diagnostics, and loudly refuses malformed complete JSON |
| Transparent recorder | Four unchanged framed messages on actual local pipes, one connection, a simulated echo upstream; no daemon or UI |
| Manifest | One simulated thirty-six-image/two-Restart shape and six refusal mutations |

These are component/scenario contracts, not executed UI actions. The original
registered runner still performs its existing owned hidden native process,
generation, launcher, EOF, journal, selector and cleanup contracts. The
`-RequireRealSeed` extension runs the pinned **real zmx**, not a real Restart.

```powershell
pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -MatchedScenarioContractOnly -ScratchRoot D:\owned\matched-contracts

pwsh -NoProfile -File Tools\windows\Tests\ValidationRunner.Tests.ps1

pwsh -NoProfile -File Tools\windows\Tests\UiCaptureDriver.Tests.ps1 `
  -RequireRealSeed -RealSeedZmxPath D:\owned\runtime\zmx.exe `
  -RealSeedZmxSha256 ACTUAL_64_HEX_SHA256 -ScratchRoot D:\owned\real-seed-contracts
```

Use fresh owned paths. Bootstrap and load the repository-pinned environment
before resolving or building zmx. Retain failing logs separately from passing
runs. The placeholder hash above is documentation only; the command refuses it.

## Matched fixture and scene matrix

`fixtures\matched-v12.json` is synthetic, offline data derived from the qualified
macOS source `2ccf303a04f995184aae1d4b738a9eca0f71b79e`. The source root
`C:\fixture` is rewritten in full through the existing hash-bound mapping.
One graph contains eight nodes, a real closed two-node handoff cycle, and a
separate fired blocking Main-STOPPED-to-Goal-DONE handoff.
Node types are not changed by renaming a Goal to Main. Selection is a separate,
observed UI state, not a `selected` property invented on the daemon's node.

| Scene names | State and comparison boundary |
| --- | --- |
| `s-goal-unwired-selected`, `s-goal-unwired-unselected` | Goal / `goalBased` / `awaitingInput`, no inbound or outbound edge; M6 unwired NEEDS YOU context. Both selection variants are recorded. Recovery-control equivalence is **not** inferred from the fixture or a warm face. |
| `s-main-cycle-selected`, `s-main-cycle-unselected` | Main / `sketch` / `blocked`, two unfired blocking handoff edges form a closed cycle with no external entry; M1 Main-cycle context. |
| `s-main-stopped-reclaim` | Actual Main / `sketch` / `stopped` ENTRY, null resolution, separate worktree binding; M4 Main STOPPED entry context. `GraphStore.swift` clears resolution outside succeeded/failed. |
| `s-goal-done-reclaim` | Actual Goal / `goalBased` / `succeeded` interior, predicate resolution and separate worktree binding; controls/context only against M4, **not** an equivalent Main outcome. |
| `s-tabs-goal-needs-you` | One Goal tab, agent asks state, selected focused pane. |
| `s-tabs-loop-running` | One Loop tab, running indicator. |
| `s-tabs-backend-idle` | One recorded-backend Copilot CLI tab, quiet state. |
| `s-tabs-agent-unknown` | Missing backend metadata produces Agent, never an assumed Claude Code backend. Compatibility coverage, not a new Mac requirement. |
| `s-tabs-two-agent-selected` | Two tabs; blocked agent selected, Shell unselected; the agent's attention indicator remains contextual. |
| `s-tabs-two-shell-selected` | Two actual Shell tabs after closing the agent tab, second selected. |
| `s-tabs-split-right-focused` | Two Shell tabs, selected tab split horizontally with the right pane explicitly focused; safe M3 context only. |
| `s-tabs-many-first`, `s-tabs-overflow-last` | Twelve tabs; first-selected and last-selected overflow windows. Hidden IDs may not appear in the UIA roster, and tab rows do not claim the sidebar-only ScrollItem contract. The first-selected route derives the exact contiguous visible stable-ID window, invokes its nearest edge tab, reacquires the roster, then invokes the exact first-tab ID. Ctrl+1 through Ctrl+9 have inline hints; later indexes do not invent one. |
| `s-tabs-hover-close` | Two tabs; posted owned-window hover over Shell, close geometry retained. This is not physical mouse input. |
| `s-tabs-last-guard` | One selected tab; the exact visible close row is retained, while the phase's source-bound `Workspace.canCloseTab()` contract proves that one tab cannot close. Dynamic UIA rows report enabled independently of that product guard, and capture does not attempt the close. |
| `s-restart-confirmed` | Existing Restart session UIA route against an actual isolated daemon, with same-connection protocol and new owned-attach evidence described below. |

The adapter requests eighteen scenes for each before/after phase: **36 original
images**, **22 cmd-only seed lifecycles**, and **two real-daemon Restart scenes**.
The live transition rehearsal executes the same order and transitions but emits
36 non-image checkpoints instead of those images.
Every static workspace uses its own profile, zmx state, layout and contained app
job. Card scenes share no live backend. Actual tab and pane ownership, selected
state, bounds and focus are read before capture; the terminal text/glyphs are
not an acceptance criterion. No pane ID is invented when a provider exposes none.

The source-derived four tab presentations are quiet, running, blocked attention,
and awaiting-input asks. See macOS `LoopWorkspaceView.swift:230-248,281-295`
and `LoopWorkspacePanes.swift:40-115`, and Windows
`TerminalSurface.zig:2054-2080,2143-2200`.
Mac allows closing its last tab to end a loop; Windows' guard remains a known
behavioral difference, not a fabricated macOS requirement.

## Outcome-copy source capability, not runtime parity

The wire fixture retains genuine `LoopResolution` (`basis`, `detail`,
`resolvedAt`) and `WorktreeRef` (`id`, `repositoryPath`, `worktreePath`, `branch`)
fields. Worktree branch, default branch, Ask policy and expected size are
separate fixture facts. The live preparation creates actual owned git
worktrees; declaring bytes in JSON does not claim they were inspected.
Main STOPPED deliberately has no invented session-exit verdict; Goal DONE has
the predicate verdict. The reclaim branch/bytes line comes from an assessment,
not from renaming either type or injecting a renderer string.

The lane was rebased onto actual main
`b987ad596dcd58d0b35c99eff821b2c8ec9030c4`, which contains the merged outcome
decoder/card consumer. The fixture qualification is therefore now
**`ASSESSABLE_SOURCE_CAPABILITY_NOT_RUNTIME_VALIDATED`**, not the earlier
missing-consumer label. `GraphModel.zig` retains `LoopResolution`, while
`GraphCanvas.zig`'s `cardLiveLine`, `resolutionLine` and `reclaimLine` provide the
source capability. macOS `LoopCardPresentation.swift:63-84,108-120` chooses
the reclaim branch/bytes line or resolved evidence; `LoopCardView.swift:65-75`
instead shows recovery controls for an unwired card. The Main is consequently
a genuine entry, not an unwired stand-in. Neither this source label nor the
fixture contract establishes visible full-copy equivalence; C8 must still
execute and review the states. Goal DONE remains a different type/outcome.

The canonical project also includes required `ProjectRef.lastOpenedAt` as
**814100400 Swift-reference seconds**, encoding `2026-10-19T11:00:00Z`.
`Initialize-CapMatchedRestartStore` preserves it in both the saved graph and
recent-project index. The initializer's default date is not a decoding fallback.
The compatibility evidence uses the actual repository `ProjectRef.swift`
compiled with pinned Swift, not a copy of its Codable schema; it is not a claim
that the real daemon or visible Restart scene ran in this lane.

## Real Restart, not offline-peer acknowledgement

The static B peer is reused only for fixed card/tab states. The Restart scene
launches **actual `runtime\graphcoded.exe`**, pinned `runtime\zmx.exe`, and a
hash-bound harmless `runtime\copilot.exe` fixture inside an owned job. The
fixture's canonical C source comes from `Get-CapMatchedBackendSource`; it prints
one fixed offline notice and waits, with no networking or agent behavior.
The job also binds the exact UTF-8 `inputs\offline-backend.c` source hash.
Build this fixture in the owned preparation root using the pinned toolchain,
and retain its compile command and output. No real provider credentials or
backend installation are needed or authorized.

A transparent local named-pipe recorder forwards the original framed bytes to
the actual daemon. It does **not** answer requests, change model counters, or
publish fabricated graph events. It records ordered direction, connection,
monotonic elapsed time and original frame bytes. Before invoking Restart the
worker holds the daemon and old attachment's native generations. Acceptance
requires all of:

- The existing `workspace-restart-session` ID and `Restart session` name target
  the exact declared Main, not Stop or a direct protocol-only substitute.
- One correlated daemon Restart request/response, an increased counter for
  that exact project/node on the **same recorded connection**, checked
  `resumeSession` request/response, and a subsequent owned attachment.
- Old attachment retirement, a different later attach generation, a live
  fixture backend in the daemon's owned job and one bounded owned terminal
  pane. Queue acceptance, process exit or peer acknowledgement alone fails.
- Counter confirmation within 30 seconds and the bounded attach wait within
  the capture deadline, preserving a 90-second cleanup reserve.
- Launcher job active-zero, held process exits and owned output-file closure;
  raw target pipe EOF is not invented from those file proofs.

The shell's production sequence is source-derived from
`App.zig:4427-4565`, `GraphStore.swift:3242-3294`,
`ZmxSessionLauncher.swift:1124-1152`, and
`GraphStore.swift:2660-2698`: retire, daemon restart, counter advance, resume,
then bounded daemon-owned attach. Stop remains separate.

The current lane executes **no visible Restart, desktop capture, physical input,
authenticated backend, glyph, accessibility-conformance or paired visual test**.
The real-pipe unit contract uses an explicitly simulated upstream. C8 must run
the real scene only after merged tooling, fresh preparation and an explicit
capture lease, and then obtain one review of the matched states. A green
174/177 report is not that evidence.
