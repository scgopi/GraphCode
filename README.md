# GraphCode

A macOS app for running **graphs of agentic loops**. Each node is a unit of work running
inside a real CLI coding-agent session (Claude Code today); each edge is a hand-off,
message, or spawn between them. The sessions are real terminals you can attach to, watch,
and steer mid-run — not headless jobs that report back when they're done.

> Early and moving. Expect rough edges, and see [Known limitations](#known-limitations).

![GraphCode Graph View](screenshots/graph-view.png)

## The idea

Four kinds of loop, differing in what you hand off:

| Loop type | You hand off | Runs until |
|---|---|---|
| **Turn-based** | the check | you approve or reject each turn |
| **Goal-based** | the stop condition | a goal is met (optionally a shell predicate exits 0) |
| **Time-based** | the trigger | you stop it — cadence lives in the prompt (`/loop 1h …`) |
| **Proactive** | the prompt | a composite sub-graph runs it end to end |

Two design choices are worth knowing up front, because they explain most of the rest:

- **GraphCode schedules nothing.** A time-based loop's recurrence lives *inside* its
  session, written into the prompt with the agent's own `/loop` or `/schedule` skill. The
  daemon only makes sure the session is alive. That's what keeps a running loop something
  you can attach to and correct, rather than a job that already finished somewhere.
- **Sessions outlive everything.** Each loop's terminal is a [`zmx`](https://zmx.sh)
  session, so it survives closing the window, quitting the app, and restarting the daemon —
  reattaching restores full scrollback.

## Parts

| Piece | What it is |
|---|---|
| `graphcode.app` | The UI — project sidebar, graph canvas, and a per-loop terminal workspace with tabs and splits |
| `graphcoded` | Background daemon (launchd agent). Owns every project's graph, fires hand-off edges, polls goal predicates, and keeps unattended sessions alive whether or not the app is open |
| `graphcode` | CLI for the same daemon — `graphcode status <project>`, `graphcode node create …` |
| `zmx` | Third-party session daemon that keeps each loop's PTY alive ([zmx.sh](https://zmx.sh)) |
| GhosttyKit | Third-party terminal engine rendering each surface ([ghostty.org](https://ghostty.org)) |

State lives in `~/.graphcode/` — per-project graphs, recents, terminal layouts, the daemon
socket and logs, and the installed binaries. **Nothing is ever written inside a project
folder you open.**

## Install

Requires **Apple Silicon** (arm64) macOS. Claude Code must be on your `PATH`.

### From a release

Download the `.dmg` from [Releases](https://github.com/scgopi/GraphCode/releases), open it,
and drag **GraphCode** to Applications. That's the whole install.

The app carries `graphcoded`, `graphcode` (the CLI), and `zmx` inside it, and puts them in
`~/.graphcode/bin` on first launch, along with the launchd agent that keeps the daemon
running. Add that directory to your `PATH` for the CLI.

Releases from 0.0.9 on are Developer ID signed and notarized, so a browser download opens
on a double-click. Earlier builds were ad-hoc signed and picked up a quarantine flag that
made macOS refuse them with a misleading *"graphcode.app is damaged"* — if you are holding
one of those, `xattr -dr com.apple.quarantine /Applications/graphcode.app` clears it.

**Claude Code must already be on your `PATH`** — GraphCode launches it, it doesn't bundle
it.

### From source

Needs [mise](https://mise.jdx.dev) (Xcode, tuist, swiftlint, zig come through it) and the
submodules:

```sh
git submodule update --init --recursive
make doctor          # checks every prerequisite and prints the fix for anything missing
make third-party     # builds zmx and GhosttyKit (zig)
make install-zmx install-cli daemon-install
make run-app
```

`make doctor` is the fastest way to find a missing piece — it checks the toolchain, the
submodules, the macOS 15 SDK zig needs, and the Metal toolchain GhosttyKit compiles shaders
with.

## Using it

1. **Add a folder** — the sidebar's ⊕ menu. It becomes a project with its own graph. Whatever
   was open is restored next launch; right-click a project to Close, Remove, or delete its
   loops.
2. **Create a loop** — ⊕ on the canvas. Pick a type; the form changes to match. For a
   time-based loop put the cadence in the prompt itself: `/loop 1h Check for new reports`.
3. **Open it** — click the node. You get its terminal workspace: tabs (⌘T), splits (⌘D /
   ⌘⇧D), and ⌘1–9 to switch. Every loop type opens the same way, including ones the daemon
   started on its own — you're attaching to the live session, not a copy of its output.
4. **Connect loops** — drag between nodes. An edge is a hand-off by default (fires when the
   source resolves); it can also be a message or a spawn, with a condition and a cycle guard.

A turn-based loop resolves itself when its session exits — there's no separate approve step.

## Development

```sh
make test     # unit tests
make check    # swiftlint + swift-format, both strict
make format   # apply formatting
```

Design docs live in `docs/` and are kept local (gitignored) for now.

## Known limitations

- **Apple Silicon only.** GhosttyKit is built for the native architecture; there is no
  x86_64 slice, so a universal build won't link.
- **Ad-hoc signed, not notarized.** See the install note above. Proper double-click-from-a-
  browser distribution needs a Developer ID certificate and notarization.
- **Claude Code is the only working backend.** Copilot CLI and Codex exist in the model and
  the picker refuses pairings it can't host, but only Claude Code is wired end to end.
- **A new folder stops at Claude's trust prompt.** An unattended loop started by the daemon
  in a folder Claude hasn't seen waits at *"Do you trust this folder?"* and shows as
  `running` while doing nothing. Attach once and answer it.
- **First session start is slow** if your shell profile is (conda's hook, for instance) —
  the queued command runs only after the profile finishes.
- **Sessions aren't reaped.** Long-lived `graphcode-*` zmx sessions accumulate; list them
  with `zmx list` and remove dead ones with `zmx kill`.

## Third-party

[Ghostty](https://ghostty.org) and [zmx](https://zmx.sh) are independent open-source
projects, vendored as submodules under `ThirdParty/` and used as dependencies — GraphCode's
own integration of each, not code taken from any other tool.
