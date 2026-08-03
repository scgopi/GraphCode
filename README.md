<p align="center">
  <a href="https://graphcode.app/">
    <img src="docs/assets/banner.png" alt="GraphCode — graphs of live, steerable Claude Code sessions on macOS" width="100%">
  </a>
</p>

<p align="center">
  <a href="https://github.com/scgopi/GraphCode/releases"><img src="https://img.shields.io/github/v/release/scgopi/GraphCode" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-blue" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-green" alt="License: MIT"></a>
</p>

<p align="center">
  <a href="https://graphcode.app/">Website</a> ·
  <a href="https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg">Download .dmg</a> ·
  <a href="https://github.com/scgopi/GraphCode/releases">All releases</a>
</p>

You can run one Claude Code session in a terminal. GraphCode lets you run ten —
connected, unattended, and still yours to attach to and correct mid-run. Each node in the
graph is a unit of work running inside a real CLI coding-agent session; each edge is a
hand-off, message, or spawn between them. The sessions are real terminals you can attach
to, watch, and steer — not headless jobs that report back when they're done.

**[Graph Engineering, simplified →](https://graphcode.app/)** — the full
article: the mental model, then the machinery underneath it.

![Two projects and their connected loops on one GraphCode canvas — every node a live terminal you can attach to](screenshots/graph-hero.png)

## New in 0.1.12

Every surface was rebuilt to answer **what are my loops doing right now** rather than
*what kind of loop is this* ([full notes](https://github.com/scgopi/GraphCode/releases/tag/v0.1.12)):

- **State-first cards.** Each state carries a word — RUNNING, NEEDS YOU, BLOCKED, DONE,
  FAILED, STALLED, SCHEDULED, STOPPED — an indicator and its own paint, instead of eight
  states sharing five colours and an 8pt dot.
- **Project lanes with an origin.** Every loop nothing hands off to hangs off its lane's
  entry point, and chains flow right along their own rows, so nothing floats.
- **An attention rail you can reach.** `⌘⇧R` works the queue oldest-first from anywhere,
  including inside a terminal, and the titlebar names who needs you only when someone does.
- **⌘K to jump to any loop** by name across every open project.
- **A downstream rail** (`⌥G`) with a one-hop minimap and a metric sparkline — off by
  default, and never drawn empty.
- **A new-loop dialog rebuilt around what each type needs**, including a **Test** button
  that runs a done check exactly as the daemon will.

## How it works

Every loop type is "an agent runs repeatedly" — they differ in what *you* stop doing:

| Loop type | You hand off | Runs until | For example |
|---|---|---|---|
| **Turn-based** | the check | you end it — each turn pauses for your review inside the session | a refactor you want to eyeball step by step |
| **Goal-based** | the stop condition | a goal is met (optionally a shell predicate exits 0) | "fix the build" — done when `make test` passes |
| **Time-based** | the trigger | you stop it — cadence lives in the prompt (`/loop 1h …`) | hourly issue triage |
| **Proactive** | the prompt | a composite sub-graph runs it end to end | a pipeline that plans its own steps |

Two design choices explain most of the rest:

- **GraphCode schedules nothing.** A time-based loop's recurrence lives *inside* its
  session, written into the prompt with the agent's own `/loop` or `/schedule` skill. The
  daemon only makes sure the session is alive. That's what keeps a running loop something
  you can attach to and correct, rather than a job that already finished somewhere.
- **Sessions outlive everything.** Each loop's terminal is a [`zmx`](https://zmx.sh)
  session, so it survives closing the window, quitting the app, and restarting the daemon —
  reattaching restores full scrollback.

So a working graph might look like: a time-based loop runs `/loop 1h Triage new bug
reports`, a hand-off edge fires a goal-based fixer loop for anything it finds (done when
the test suite passes), and a second edge hands the fix to a turn-based reviewer loop where
you approve each change yourself. All three are live terminals the whole time — click any
node and you're in that session, scrollback and all.

Each project you add carries its own graph, laid out as a lane: an origin the loops
nothing hands off to hang from, and every chain flowing right from there. A card is
painted by the state it is in, not by its kind — what you read off the canvas is which
loops are running, which are done, and which are waiting on you.

## Install

Requires **macOS 15+ on Apple Silicon** (arm64), with **Claude Code on your `PATH`** —
GraphCode launches it, it doesn't bundle it.

```sh
brew install --cask scgopi/graphcode/graphcode
```

That pulls the same signed release, and puts the `graphcode` CLI on your `PATH` while it's
there — the long name adds the tap by itself, so `brew tap scgopi/graphcode` first is
equivalent and makes later commands just `graphcode`. `brew upgrade --cask graphcode` from
then on. The tap is
[scgopi/homebrew-graphcode](https://github.com/scgopi/homebrew-graphcode) — its own
repository, since Homebrew's cask index takes only projects past a notability threshold
GraphCode hasn't reached yet.

Homebrew 6 warns that a third-party tap is untrusted. It's a gate on taps in general, not
a finding about this one; `brew trust --tap scgopi/graphcode` settles it, and gets ahead of
the release that stops making it optional.

Or download the latest
[`graphcode-macos-arm64.dmg`](https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg)
(all versions under [Releases](https://github.com/scgopi/GraphCode/releases)), open it,
and drag **GraphCode** to Applications. Releases are Developer ID signed and notarized, so
a browser download opens on a double-click.

Either way the app carries `graphcoded`, `graphcode` (the CLI), and `zmx` inside it, and
puts them in `~/.graphcode/bin` on first launch, along with the launchd agent that keeps
the daemon running. If you installed from the DMG, add that directory to your `PATH` for
the CLI; Homebrew links it for you.

<details>
<summary>Holding a pre-0.0.9 build?</summary>

Builds before 0.0.9 were ad-hoc signed and picked up a quarantine flag that made macOS
refuse them with a misleading *"graphcode.app is damaged"*.
`xattr -dr com.apple.quarantine /Applications/graphcode.app` clears it — or just grab the
current release.

</details>

## Using it

1. **Add a project** — the sidebar's ⊕ menu: open a local folder, **clone a repository
   from a URL**, or **add a remote repository over SSH** (key auth and zmx on the server
   required — loops then run on the server while this Mac steers them). Each becomes a
   project with its own graph. Whatever was open is restored next launch; right-click a
   project to Close, Remove, or delete its loops.
2. **Create a loop** — ⊕ on the canvas or the Graph view. Write the prompt and hit Create:
   the form opens on goal-based, the type chooser explains what each kind hands off, and
   the title is optional — leave it blank and GraphCode asks the loop's own backend for a
   name. A time-based loop's `/loop 1h Check for new reports` directive is composed for
   you, and a goal-based loop's done check has a **Test** button that runs it exactly as
   the daemon will.
3. **Open it** — click the node. You get its terminal workspace: tabs (⌘T), splits (⌘D /
   ⌘⇧D — split as many times as you like), ⌘1–9 to switch tabs, ⌘]/⌘[ to move between a
   split's panes, and ⇧⌘]/⇧⌘[ to step between loops. ⌘K jumps to any loop by name, ⌥G
   opens the downstream rail, and ⌘⇧R walks the loops asking for you, oldest first — all
   of them listed in the menu bar. Every loop type opens the same way, including ones the
   daemon started on its own — you're attaching to the live session, not a copy of its
   output.
4. **Connect loops** — drag between nodes. An edge is a hand-off by default (fires when the
   source resolves); it can also be a message or a spawn, with a condition and a cycle guard.

A turn-based loop resolves when its session exits — the per-turn review happens inside the
session itself, so there's no separate approve step in the app.

## Parts

| Piece | What it is |
|---|---|
| `graphcode.app` | The UI — project sidebar, graph canvas, and a per-loop terminal workspace with tabs and splits |
| `graphcoded` | Background daemon (launchd agent). Owns every project's graph, fires hand-off edges, polls goal predicates, and keeps unattended sessions alive whether or not the app is open |
| `graphcode` | CLI for the same daemon — `graphcode status <project>`, `graphcode node create …`, `graphcode node send …` (type a message into another loop's live session) |
| `zmx` | Third-party session daemon that keeps each loop's PTY alive ([zmx.sh](https://zmx.sh)) |
| GhosttyKit | Third-party terminal engine rendering each surface ([ghostty.org](https://ghostty.org)) |

State lives in `~/.graphcode/` — per-project graphs, recents, terminal layouts, the daemon
socket and logs, and the installed binaries. **Nothing is ever written inside a project
folder you open.**

## Building from source

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
- **Claude Code is the most complete backend.** Copilot CLI and Codex loops launch, run,
  fan out, and receive message edges like Claude ones; what stays Claude-only is
  hook-*reported* presence and usage (the others read as heuristics or "not reported") —
  and the picker refuses pairings a backend can't host (time-based needs the session to
  re-trigger itself; composites need verified sub-agents).
- **A new folder stops at Claude's trust prompt.** An unattended loop started by the daemon
  in a folder Claude hasn't seen waits at *"Do you trust this folder?"* and shows as
  `running` while doing nothing. Attach once and answer it.
- **First session start is slow if your shell profile is slow** (conda's hook, for
  instance) — the queued command runs only after the profile finishes.
- **Sessions aren't reaped.** Long-lived `graphcode-*` zmx sessions accumulate; list them
  with `zmx list` and remove dead ones with `zmx kill`.
- **Remote repositories are attach-first.** Loops on an SSH remote launch and attach
  fine, but deleting one doesn't kill its remote session, message edges into remote
  loops report undelivered, presence/usage read "not reported", and worktrees and
  loop fan-out aren't available there yet. And a sleeping Mac fires no edges — the
  daemon stays local by design.

## Inspiration & third-party

Inspired by [Supacode](https://supacode.sh) — same spine of daemon-kept terminal sessions;
its unit is the worktree, GraphCode's is the graph of loops. Built on
[Ghostty](https://ghostty.org) and [zmx](https://zmx.sh), vendored under `ThirdParty/`.

## License

[MIT](LICENSE).
