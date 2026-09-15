# Ghostty Windows embedding assessment

Revisions examined:

- Ghostty `fad7f854e8f976968bf4d61d408de9699cf87666`
- Winghostty `dccedf73600e0ef59c938aa8997f378f27d08f31`

## Public API boundary

`libghostty-vt` is usable on Windows and exposes terminal state, VT writes, resize,
callbacks, render snapshots, row/cell iterators, styles/colors/graphemes, key/mouse/focus
encoders, selection, snapshots, Kitty graphics support, and paste validation.

It intentionally does not provide HWND creation, ConPTY/process launch, Win32 events,
clipboard ownership, font shaping/rasterization, glyph atlases, GPU contexts, compositor,
or presentation.

Upstream `ghostty.h` is documented as an internal macOS embedder API. Its platform payloads
are NSView/UIView, and upstream has no Win32 application runtime or HWND surface API.

## Spike

`investigation/spikes/ghostty-custom-window` proves:

- one GraphCode-owned top-level HWND
- two child terminal HWNDs
- independent `GhosttyTerminal` and `GhosttyRenderState` values
- public row/cell iteration
- independent GDI painting

Smoke result:

```text
SMOKE PASS: created=2 painted A=1 B=1 independent-terminal-state=PASS
```

This is a VT/state and window-topology proof, not a production Ghostty renderer proof.

## Winghostty dependency map

Winghostty's internal runtime demonstrates the desired topology:

- `src/apprt/win32.zig`: `App`, `Host`, `Surface`, HWND lifecycle, input, DPI, focus,
  clipboard, tabs/splits, accessibility, repaint scheduling
- `src/Surface.zig`, `src/App.zig`: terminal/application core
- `src/renderer.zig`, `src/renderer/OpenGL.zig`, `src/renderer/opengl/*`: WGL/OpenGL
  terminal rendering
- `src/pty.zig`: Windows pipes and ConPTY
- `src/Command.zig`: `CreateProcessW`, pseudoconsole attribute, process lifetime

Each Winghostty surface owns an HWND, HDC, HGLRC, core surface, and host association.
Rendering uses `wglMakeCurrent` and `SwapBuffers`. Multiple complete surfaces are therefore
technically possible.

There is no exported `create_surface(parent_hwnd)` boundary. Extracting it crosses a wide
import graph including compositor, shell, clipboard, UIA, settings, tabs, recovery,
drag/drop, IPC, and theme code.

## Build evidence

- Current Ghostty `zig build -Demit-lib-vt=true` succeeds with Zig 0.16.0.
- Shared/static C spike builds and runs.
- Winghostty requires Zig 0.15.2 but its build runner failed on an absolute child cwd.
- Zig 0.16.0 is incompatible with that checkout's declared version and build APIs.
- `libghostty-vt` tests hung for more than five minutes and were stopped; result is
  inconclusive.

## Decision

- **Go** for `libghostty-vt` with a GraphCode-owned renderer.
- **No-go today** for embedding a complete upstream Ghostty surface via public APIs.
- **Conditional go** for extracting/maintaining Winghostty's internal Win32/OpenGL runtime.

The production UI cannot be estimated as a thin wrapper. It requires either a substantial
Winghostty runtime extraction/fork or a production terminal renderer/input stack owned by
GraphCode.
