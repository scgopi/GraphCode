---
title: GraphCode Keyboard Shortcuts
description: Every keyboard shortcut and mouse trick in GraphCode — the graph, the terminals, and the tips that depend on which agent is running.
---

# Keyboard shortcuts

Everything here is also in the menu bar — **Loop** and **Terminal** are the two menus
that appear once a workspace is open, and macOS draws each key beside its item. This
page is the same information in one place.

## The graph

| Shortcut | Does |
|---|---|
| ⌘K | Jump to any loop by name, across every open project. ↑/↓ to choose, ⏎ to open |
| ⌘⇧R | Review what needs you — works the attention queue oldest-first, from anywhere |
| ⌘⇧] / ⌘⇧[ | Next / previous loop, in sidebar order across projects |
| ⌥G | Show or hide the loop panel — the downstream rail with the one-hop minimap and metric sparkline |
| ⌘= / ⌘− | Zoom the canvas in / out |
| ⌘0 | Canvas to actual size |
| ⌘9 | Fit the whole graph |
| ⌘O | Open a project folder (from the Welcome window) |
| ⌘, | Settings |

## Terminals

Inside a loop's workspace, the panes are real terminals — these act on them:

| Shortcut | Does |
|---|---|
| ⌘T | New tab |
| ⌘W | Close tab (a workspace always keeps its last one) |
| ⌘1 … ⌘9 | Select that tab |
| ⌘→ / ⌘← | Next / previous tab |
| ⌘D | Split the pane right |
| ⌘⇧D | Split the pane down |
| ⌘] / ⌘[ | Focus the next / previous pane of a split |
| ⌘= / ⌘− | Bigger / smaller terminal font (⌘+ works too) |
| ⌘0 | Reset the terminal font size |

Canvas zoom and terminal font share keys on purpose: ⌘= acts on whatever is in front
of you — the graph when the canvas has focus, the type when a terminal does.

## Mouse tricks in a session

| Gesture | Does |
|---|---|
| ⌘-click a URL | Opens it in your browser |
| ⌘⇧-click a URL | Same, for sessions whose agent captures the mouse — see below |
| ⇧-drag | Select text when the agent captures the mouse |

Some agents' interfaces take over the mouse for their own use — GitHub Copilot CLI
does; Claude Code doesn't. When one does, an unmodified click belongs to the agent,
and ⇧ is the terminal-standard way to say "this click is for me": **⌘⇧-click** opens a
link, **⇧-drag** selects text. In a Claude Code session, plain ⌘-click and plain drag
already work. This is stock [Ghostty](https://ghostty.org) behavior — GraphCode's
terminals are Ghostty surfaces, so anything that holds there holds here.

---

[← Graph Engineering, simplified](./) · [All releases](https://github.com/scgopi/GraphCode/releases)
