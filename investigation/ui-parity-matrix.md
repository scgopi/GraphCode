# Windows UI parity matrix

This is a behavioral contract, not a SwiftUI translation plan.

| Feature | Current macOS surface | Required Windows behavior | Priority |
|---|---|---|---:|
| Project sidebar | `AppSidebarView`, project rows | Open/close projects, recent projects, state badges | P0 |
| Global graph | `GraphOverview*` | All project lanes under one start node | P1 |
| Project graph canvas | `ProjectCanvasView`, `Canvas*` | Pan, zoom, select, create, position nodes, render edges | P0 |
| Node cards | `LoopCardView`, presentation/state helpers | State, presence, activity, backend, attention styling | P0 |
| Create loop | `NodeDraftForm`, type/backend pickers | Create goal/turn/time/composite with validation | P0 |
| Connect loops | connector handles, edge forms | Drag/create hand-off/message/spawn edges and conditions | P1 |
| Loop workspace | `LoopWorkspace*` | Open a node into a terminal-first workspace | P0 |
| Terminal attach | `GhosttyTerminalView` | Run `zmx attach`, close/recreate without ending session | P0 |
| Terminal tabs | terminal layout domain + workspace views | Persist/reopen tabs | P1 |
| Terminal splits | pane layout/workspace views | Multiple panes, resize, focus navigation | P1 |
| Two simultaneous terminals | multiple panes/surfaces | Independent input, focus, resize, rendering | P0 architecture gate |
| Quick chat | `QuickChatsCanvasView` | Ad-hoc persistent agent session | P2 |
| Needs-you flow | attention rail/activity strip | Identify and navigate awaiting-input loops | P1 |
| Downstream rail | workspace rail | Navigate graph descendants from a loop | P2 |
| Jump palette | `JumpPalette*` | Keyboard navigation to projects/loops | P1 |
| Context menus | project/worktree/canvas menus | Native menus for node/project actions | P1 |
| Settings | `SettingsView` | Backend, permission, appearance, path settings | P1 |
| Worktree management | worktree features/dialogs | Inspect/sweep worktrees and bindings | P2 |
| Remote repository UI | welcome/remote forms | Defer until Windows remote transport is designed | Deferred |
| Updates/install | Sparkle-like macOS flow | Native installer/update strategy | P2 |
| Accessibility | SwiftUI/AppKit semantics | UIA names, roles, focus, terminal text exposure | P0 for release |
| Keyboard/IME | AppKit/Ghostty integration | Native key layout, dead keys, IME composition | P0 architecture gate |
| Clipboard/selection | Ghostty/AppKit | Copy/paste and mouse selection | P0 architecture gate |
| DPI/theme | AppKit/SwiftUI | Per-monitor DPI, resize, dark/light theme | P0 |

## Minimum usable Windows shell

1. Project list.
2. One project canvas with node cards and edges.
3. Create/open/stop/send actions through `graphcoded`.
4. One terminal workspace attached to zmx.
5. State/presence updates.
6. Two terminal surfaces in one top-level window before committing to the compositor.

Tabs, arbitrary splits, remote SSH, worktree polish, updater, and full global-graph parity
should follow only after the terminal-host gate passes.
