# Rendered Windows evidence: focus tint

The active workspace focus strip was genuinely orange instead of the blue in
current `Theme.swift`. Changing only `DesignTokens.pane_focus_tint` from
`0x000A84FF` to `0x00FF840A` corrects Win32 COLORREF's BGR channel order.
The same client-relative rectangle **[500, 130, 64, 2]** contains **128/128**
orange `RGB(255,132,10)` pixels before and **128/128** blue `RGB(10,132,255)`
pixels after. No color tolerance is used.

| Evidence | Before | After |
|---|---|---|
| Source commit | `3d7c670d8c73088b2f31f89175279dbedbb47563` | `2ba3c5a458189d9a1ebc98b5cb3c2f5b30c09305` |
| Source tree | `3b5545d5fdf97d0df9ca4e5e78690077ba500b84` | `c20f15e9d2df3d1dd764506b16afd8ef37d2fb45` |
| App SHA-256 | `f18a7b314d83fed62f68d7a04374a82b27368844a14140d7265d437554b75c14` | `3de0bc6574655365028c11e1eaaf73c2aa29fa2652e98e380ca2ed9d72097114` |
| Workspace PNG | [Original before](before-workspace.png) | [Original after](after-workspace.png) |
| Workspace client | 1264 x 761, 96 DPI | 1264 x 761, 96 DPI |
| Selected tab UIA bounds | [220, 84, 112, 22] | [220, 84, 112, 22] |

The other after-images are [canvas/sidebar](after-canvas-sidebar.png) and
[Product Settings](after-dialog.png). All four PNGs are byte-identical copies
of the original lossless app-client captures: no crop, rescale, re-encoding or
retouching. Total PNG size is **130,517 bytes**.

## Provenance and scope

[evidence-derivative.json](evidence-derivative.json) is explicitly **DERIVATIVE**:
a sanitized index, not original capture metadata and **not an input** to
`Test-RenderedVisualBaseline.ps1`. It includes image/original-record hashes,
source commits/trees and raw/LF-normalized source hashes, executable/provider
hashes, state, geometry, sample rectangles, observations and cleanup results.
Original records retain private absolute paths, process identities, command
lines, stdout/stderr and the complete capture/re-analysis history. Those fields
are omitted here, not rewritten in the originals.

Both runs used the native production renderer with `App.installUiaFixture`,
the same two-card synthetic graph, zoom 1, and a deliberately disconnected
GraphCode daemon. Both GDI+-disabling automation hooks were unset. The workspace
had a real, exact-session `zmx info` response with one attached client and live,
identity-proven cmd/backend/server ancestry. Providers were unchanged:
zmx `11e20c738b4ebd88031c7a01f1a9d938ee123234` and Winghostty
`f5abc059e4ca58b376eb209313aca7784659c679`.

Setup used UIA invocation and native `WM_COMMAND`, **not keyboard-menu delivery**.
Each run temporarily hid only its exact identity-proven foreground zmx attach
HWND, then restored visibility without activation. This is harness-assisted
visibility, **not normal-user focus proof**. The black terminal region is
**not terminal content or readability proof**. Settings was closed without
saving; its native light buttons are not declared a macOS palette violation.

The 120-second independent job watchdog was joined without firing. Job cleanup
verified zero survivors, followed by independent absence checks for 15 exact
identities before and 16 after, plus each unique zmx namespace. Elapsed totals
were 10,336 ms / 10,472 ms, with 90 ms / 73 ms recorded cleanup. The execution
deadline and separate bounded cleanup/stream waits are distinct.

## What the pixels establish

The production comparator passed exact opaque after-samples for canvas
`#0A0C0B`, grid `#151816`, card/dialog `#232326`, sidebar `#1D1D21`, selected tab
`#3C3E44`, and focused pane `#0A84FF`. The latter also independently agrees with
current `Theme.paneFocusTint`; the old orange token and actual before-image fail
that corrected expectation.

The selected rounded-corner sample has 31 distinct colors and the metric
sparkline sample 30. Card/sidebar/Settings-title glyph samples have 27/31/55;
the sampled native button label has two. Tab/loop-bar gradient samples have
6/12. These are **observations, not quality thresholds**: other colors can include
fill, decoration or subpixel fringes, not just antialiasing. No native LOGFONT
metadata was captured for those controls. Font quality on every surface, other
DPI/monitor states, and equality with Core Graphics remain unproven.

The corrected comparator rejected old-orange/channel-swap and one-channel
mutations; controlled copies of real canvas pixels also rejected delta 1 and
neutral gray while restored copies passed. Those are labeled post-hoc
sensitivity controls, not new runtime images. The immutable before-image was
re-analyzed using a separately hashed sidecar; the new comparator was never
represented as the original capture-time script.

**All four visual parity rows remain Partial.** A compatible current macOS
capture is still unavailable. Historical `graph-hero.png`, the immutable
historical manifest, and the separate two-token currentThemeContract remain
unchanged.

## Offline read-only replay

From the repository root on Windows with PowerShell 7, this checks the four
original PNG hashes/dimensions and all eight exact-color sample rectangles.
It only reads the bundled files; it does not launch an app or claim complete
source/provenance replay. The before sample intentionally expects the recorded
bug color, so a replay PASS preserves the evidence rather than approves it.

```powershell
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$root = Join-Path (Get-Location) 'investigation\visual-baseline\rendered-windows'
$index = Get-Content -LiteralPath (Join-Path $root 'evidence-derivative.json') -Raw |
  ConvertFrom-Json
if ($index.images.Count -ne 4 -or $index.pixelChecks.Count -ne 8) {
  throw 'Bundled evidence cardinality changed'
}
foreach ($image in $index.images) {
  $path = Join-Path $root $image.file
  if ((Get-FileHash -LiteralPath $path).Hash.ToLowerInvariant() -cne $image.sha256) {
    throw "PNG hash mismatch: $($image.file)"
  }
  $bitmap = [Drawing.Bitmap]::new($path)
  try {
    if ($bitmap.Width -ne $image.width -or $bitmap.Height -ne $image.height) {
      throw "PNG dimensions mismatch: $($image.file)"
    }
    foreach ($check in @($index.pixelChecks | Where-Object file -eq $image.file)) {
      $r = $check.rect
      if ($r[2] * $r[3] -ne $check.pixels) { throw 'Pixel count mismatch' }
      for ($y = $r[1]; $y -lt $r[1] + $r[3]; $y++) {
        for ($x = $r[0]; $x -lt $r[0] + $r[2]; $x++) {
          $p = $bitmap.GetPixel($x, $y)
          if ($p.A -ne $check.alpha -or
              (@($p.R, $p.G, $p.B) -join ',') -cne ($check.rgb -join ',')) {
            throw "RGB mismatch: $($image.file)/$($check.id) ($x,$y)"
          }
        }
      }
    }
  } finally { $bitmap.Dispose() }
}
'Bundled PNG replay: PASS (4 original PNGs; 8 exact-color regions)'
```

The repository production suite remains:
`pwsh -NoProfile -File .\Tools\windows\validate.ps1 -Task visual-baseline`.
Its synthetic inputs exercise the real comparators; only the separately
documented live runs produced these screenshots.
