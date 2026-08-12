# Winghostty embeddable host contract

Provider: `coneilen/winghostty`

## Ownership

- GraphCode owns the top-level HWND and sole Win32 message loop.
- The host owns registered terminal child-window procedures.
- Each surface owns its HWND, HDC, HGLRC, Ghostty core surface, renderer resources, attach
  client process, and callbacks.
- Every call and callback declares UI-thread affinity.
- Surface creation copies command, cwd, environment, and callback configuration.
- Destruction is synchronous or awaitable and guarantees no later callback, posted child
  work, renderer access, or process access.

## Required API

- initialize/deinitialize host
- create/destroy surface under a caller parent HWND
- set bounds, visibility, focus, theme, and font scale
- optional non-blocking UI-thread drain hook
- callbacks for exit, title/cwd, bell, notification, redraw, focus, and fatal error

## Excluded provider policy

- GraphCode tabs/splits and graph UI
- Winghostty product tabs/settings/updater/recovery/application IPC
- GraphCode daemon protocol or domain types

## Gates

- Original Winghostty application remains green.
- External one-surface host.
- External two-surface host.
- Repeated create/destroy without leaked HWND/HDC/HGLRC/process/thread resources.
- Independent focus/input/IME/clipboard/DPI/UIA.
