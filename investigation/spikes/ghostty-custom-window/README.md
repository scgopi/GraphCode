# Ghostty/libghostty-vt Win32 embedding spike

This is a minimal, external-host proof for the current public Ghostty VT API. It does **not** embed Ghostty's complete GUI/runtime surface.

## What it proves

- Creates a GraphCode-like Win32 top-level host window.
- Creates two `WS_CHILD` terminal windows owned by that host.
- Keeps two independent `GhosttyTerminal` and `GhosttyRenderState` instances.
- Feeds independent VT text to each terminal.
- Uses the public render-state row/cell iterators to paint styled ASCII cells with GDI.
- Runs a smoke check requiring both child HWNDs to be created and painted.

## Source and upstream inputs

- Source: `spike.c`
- Upstream Ghostty revision used: `fad7f854e8f976968bf4d61d408de9699cf87666`
- The upstream build was `zig build -Demit-lib-vt=true` with Zig 0.16.0.

## Re-run without storing bulky outputs here

Set `$ghosttyBuild` to a local Ghostty build produced with
`zig build -Demit-lib-vt=true`. Build from this directory and write generated outputs to a
temporary directory:

```powershell
$src = Join-Path (Get-Location) 'spike.c'
$out = Join-Path $env:TEMP 'graphcode-ghostty-window-spike'
$inc = Join-Path $ghosttyBuild 'include'
$lib = Join-Path $ghosttyBuild 'lib\ghostty-vt.lib'
New-Item -ItemType Directory -Force $out | Out-Null
clang-cl /nologo /W4 /I $inc /c $src /Fo:(Join-Path $out 'spike-from-graphcode.obj')
clang-cl /nologo (Join-Path $out 'spike-from-graphcode.obj') $lib user32.lib gdi32.lib advapi32.lib shell32.lib /Fe:(Join-Path $out 'spike-from-graphcode.exe')
Copy-Item (Join-Path $ghosttyBuild 'bin\ghostty-vt.dll') $out -Force
& (Join-Path $out 'spike-from-graphcode.exe')
```

Expected result includes:

```text
SMOKE PASS: created=2 painted A=1 B=1 independent-terminal-state=PASS
```

Build outputs are intentionally excluded from this GraphCode investigation directory.
