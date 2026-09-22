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
