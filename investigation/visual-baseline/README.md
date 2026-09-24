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
not a substitute for a rendered screenshot diff. This repository/CI has no
deterministic way to rasterize a live Win32 window, so no such rendered comparison
exists for GraphCode-owned regions today.

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
