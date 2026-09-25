# Windows visual baseline

This fixture set is a public-source contract for the Windows shell. It freezes the
GraphCode-owned geometry, state words, colors, IDs, timestamps, metrics, and static
terminal text needed for deterministic review without building the Windows UI.

`manifest.json` cites the existing GraphCode screenshot, `Theme.swift`, card
presentation, canvas, sidebar, workspace, and parity sources. The four DPI entries are
layout variants, not screenshots tied to a particular machine: `Tools/windows/visual-baseline.ps1`
reimplements `graphcode-windows/src/Dpi.zig`'s exact scaling formula and reads real
control-metric base values straight out of `graphcode-windows/src/DesignTokens.zig`, so
each variant's scaled geometry for GraphCode-owned regions (`regionGeometry`) is
checked against the real per-monitor DPI values (96/120/144/192), not just asserted to
be present.

**What this check does and does not do:** `visual-baseline.ps1` performs static
manifest/geometry validation, not rendered-output comparison. It never launches the
app, captures a window, or rasterizes a bitmap; it re-derives expected numeric pixel
geometry from the real source-of-truth constants (`Dpi.zig`, `DesignTokens.zig`) and
checks the manifest's declared values against that math. This still catches real drift
(a stale manifest value or a changed constant that nobody updated the manifest for),
which is why it is stronger than the prior version's simple presence checks, but it is
not a substitute for a rendered screenshot diff. The separate rendered capture
and replay commands below do not turn these historical layout variants into
runtime screenshots. Live capture requires an exclusively reserved interactive
Windows desktop; the static command does not.

The GraphCode-owned regions are safe for screenshot comparison. Terminal rendering,
input, IME, clipboard, resize, and accessibility remain live Winghostty functional
tests; the text files in `fixtures` are only stable placeholders for testing workspace
layout and split ownership.

## Static command

```powershell
pwsh Tools/windows/visual-baseline.ps1
```

Static, no-launch validator: it never builds or launches `graphcode-windows.exe`,
only reads source and manifest files already in the checkout. Exits non-zero with
a specific diagnostic on any contract violation, or prints `Visual baseline:
PASS`. Must be run with `pwsh` (PowerShell 7), not Windows PowerShell 5.1's
`powershell.exe` — an unrelated, pre-existing check elsewhere in this script
fails under Desktop edition regardless of this contract.

## currentThemeContract

`tokenContracts`/`baseCommit` above is an immutable historical pin at commit
`ece55b6` and is never edited. `currentThemeContract` is a separate, additive
section that instead tracks *today's* `graphcode/Sources/Features/App/Theme.swift`,
re-derived from the file on disk every run.

`Tools\windows\Test-CurrentThemeContract.ps1` is the actual comparator. It is
dot-sourced by `visual-baseline.ps1` for the real run, and invoked directly (same
file, as its own process) by `Tools\windows\Tests\VisualBaseline.Tests.ps1`
against fixture files — tests exercise this exact production code, not a
re-declared copy. For each of the two tracked tokens it enforces:

- `schemaVersion` is exactly `1`; exact token identity, cardinality, and no
  duplicates (an empty or partial token list fails, it does not pass vacuously)
- RGB shape (3 channels), that each channel is an integral number in `0..255`
  (a fractional or null recorded channel is rejected before any lossy `[int]`
  coercion), and that `hex` matches `rgb`
- zero-tolerance equality between the token's recorded `rgb` and the RGB
  derived from Theme.swift's active `Color(red:green:blue:)` literal; a
  declaration commented out with `//` or a `/* ... */` block, or one with a
  trailing expression such as `.opacity(...)`, is rejected rather than
  silently matched or accepted -- an unterminated block comment is likewise an
  explicit failure, not a silent misparse
- a whole-file SHA-256 (`themeSwiftBlobSha256`, CRLF normalized to LF) against
  the approved Theme.swift blob, without requiring any historical git object
- a mandatory `windowsToken` mapping to the real
  `graphcode-windows/src/DesignTokens.zig` `Color` constant, decoded from its
  Win32 `COLORREF` (`0x00BBGGRR`) byte order and compared to the same
  Theme.swift-derived RGB -- an independent macOS-vs-Windows source
  cross-check, not one manifest constant compared against another; a blank,
  missing, or wrongly-mapped `windowsToken` field fails outright

This is a source-contract check only. It does not capture or compare live
screenshot pixels; no live/launch mode exists in this script.

## Rendered Windows capture and replay

`Tools\windows\capture-visual-baseline.ps1` captures actual application client
pixels, not a reimplementation of the renderer. Its data is the existing
`App.installUiaFixture` synthetic graph; **the production rendering path remains
enabled**. In particular, `GRAPHCODE_UIA_GATE` and the daemon-supervisor test hook
must be unset: both disable GDI+ startup, so ordinary UIA-gate screenshots cannot
prove production shape anti-aliasing.

The bounded driver captures graph/sidebar, Product Settings (without saving),
and an attached workspace. It requires own-worktree shell/provider binaries and
an explicit foreground reservation. It creates isolated support, LOCALAPPDATA,
cwd, layout, named-pipe and zmx namespaces. It deliberately refuses a sibling
`graphcoded.exe` and connects to no daemon server, so a real daemon cannot
replace the synthetic graph. Disconnected UI is part of the recorded state,
not full production-data parity.

The zmx root alone uses a fresh short `TEMP\gcv-<12 hex>` directory. The pinned
provider's ordinary `SetFileSecurityW` lease path must remain below 260 UTF-16
units; its nonce-qualified owner pipe must remain below 256. The preflight
records the exact endpoint/lease/pipe lengths and fails on collisions or
excess length, without a global-root fallback or ACL workaround. Logs are
copied into the run artifacts during cleanup; the exact short root is also
recorded for preservation and later targeted removal. A zmx attach/conhost
process alone is not readiness: the driver waits for the exact endpoint, then
requires pinned `zmx info` to report the expected session/cwd, at least one
attached client, and a live backend PID already proven to be a run descendant.

After building with the pinned tools/providers, use a **new** output directory:

```powershell
pwsh -NoProfile -File .\Tools\windows\capture-visual-baseline.ps1 `
  -Shell .\graphcode-windows\zig-out\bin\graphcode-windows.exe `
  -Zmx .\.graphcode-tools\providers\zmx\zig-out\bin\zmx.exe `
  -OutputDirectory <absolute-new-run-directory> `
  -ForegroundLease <explicit-reservation-reference> `
  -TimeoutSeconds 120
```

The lease parameter records authorization; it does not acquire a reservation.
Do not run this concurrently with another desktop test. No display/font/input
settings are changed. Capture uses `CopyFromScreen` only inside the owned,
foreground, unobstructed client rectangle, with before/after ownership and
geometry guards. Failure to acquire foreground is a capture-infrastructure
failure, not a product-rendering regression. There is no global Alt injection or
desktop-capture fallback. The outer process bounds even a stuck UIA call;
cleanup uses recorded PID plus process creation time, never process-name kills.

If the current foreground HWND belongs to the exact identity-proven owned zmx
attach process, the harness may hide **only that HWND once** to expose workspace
chrome. Its PID, executable, creation time, ancestry and visibility intervention
are recorded; visibility is restored without activation if the original HWND
still exists, and only run-owned processes are cleaned up. This is assisted
capture, not proof that normal user focus behavior is correct. No arbitrary
provider-window enumeration, global Alt injection or foreign-window hiding is
used.

To execute the same source/provider/binary preflight without launching the app,
pass `-PreflightOnly` and a fresh output directory; no foreground lease is
required for that mode. It writes `build-snapshot.json` and compiles the actual
capture interop. It does not establish that foreground acquisition or capture
will succeed.

The output includes lossless PNGs, UIA bounds/state, actions, DPI, font-smoothing
settings, shell/zmx/Winghostty-library hashes and pinned provider commits, raw
and LF-normalized source/script hashes, and private process/environment records.
Provider pins/cleanliness are checked before launch and binary hashes again
after capture. Keep private paths/logs out of published
artifacts. Captures are native-size at the observed DPI; they do not establish
multi-DPI or hardware-input coverage.

`evidence.json` intentionally starts with **empty regions**. Review the actual
images and map sample rectangles to renderer/UIA geometry before replay; a
successful capture alone is not a comparator PASS. A region records `id`,
`kind`, `rect` (client-relative x/y/width/height), and its `source` call site.
`flat` regions name the `windowsToken`; `coverage` observations name
`backgroundRgb` and `foregroundRgb`; `gradient` observations report row means.
Exclude glyphs, shadows, grid intersections and borders from opaque-interior
assertions. Required flat regions are `canvas-tone`, `canvas-grid`,
`dialog-panel`, `selected-tab`, and `pane-focus`.

```powershell
pwsh -NoProfile -File .\Tools\windows\Test-RenderedVisualBaseline.ps1 `
  -EvidencePath <run-directory>\evidence.json `
  -ReportPath <run-directory>\measurements.json
```

The comparator first runs the existing currentThemeContract validator, then
checks source provenance and the actual PNGs. Text source comparisons use the
existing LF-normalized SHA-256 helper so CRLF checkouts do not create false
drift; raw capture-time hashes are retained separately. PNGs and binaries are
never newline-normalized. `-SourceRoot` selects the source checkout being
verified; it defaults to this repository, not a historical reference.
Window PID/creation-time/HWND, surface state, client dimensions and provider
pin/hash identities are required metadata. Consistent metadata is not origin
authentication: the actual capture guards and preserved run process records
must independently establish that these were the owned app's pixels.

Opaque flat samples require **zero** channel difference. A one-channel delta of
1, neutral `#0C0C0C` instead of canvas `#0A0C0B`, and a red/blue swap are rejected.
This is Windows-renderer/source consistency, not matched macOS screenshot
parity. The separate currentThemeContract independently cross-checks the
canvas/grid source values against current Theme.swift.

Coverage counts and gradient row samples are observations, not quality-score
thresholds. Colors other than the selected endpoints may include subpixel
fringes, decorations or grid pixels, not just shape anti-aliasing. Font flags
and system ClearType configuration are not rendered glyph proof. Preserve and
inspect native-size glyph/curve crops, and record the limits of each region.
Windows two-stop gradients and opaque surfaces also differ from macOS material
compositing; do not silently equate those outputs.

`VisualBaseline.Tests.ps1` invokes this exact production comparator against
explicitly labeled tiny synthetic test PNGs. It covers the exact RGB boundary,
neutral gray and channel-swap negatives, coverage counts, invalid/missing
regions, hashes, dimensions, state/DPI, physical LF/CRLF source copies, and
actual source-content drift. Synthetic inputs require `-AllowTestFixture` and
are never runtime screenshots.

The historical hero image remains authentic **historical** evidence only.
A compatible current macOS capture with matching source, state, geometry/DPI
and compositing context is still required for matched-current comparison.
Source agreement, a Windows capture, or a comparator PASS alone does not
promote any of the four visual parity rows to Validated.
