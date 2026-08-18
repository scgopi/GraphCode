<p align="center">
  <a href="https://graphcode.app/">
    <img src="docs/assets/banner.png" alt="GraphCode — graphs of live, steerable Claude Code sessions on macOS" width="100%">
  </a>
</p>

<p align="center">
  <a href="https://github.com/scgopi/GraphCode/releases"><img src="https://img.shields.io/github/v/release/scgopi/GraphCode" alt="Release"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2015%2B%20(Apple%20Silicon)-blue" alt="Platform">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-FSL--1.1--MIT-green" alt="License: FSL-1.1-MIT"></a>
</p>

<p align="center">
  <a href="https://graphcode.app/">Website</a> ·
  <a href="https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg">Download .dmg</a> ·
  <a href="https://github.com/scgopi/GraphCode/releases">All releases</a> ·
  <a href="https://graphcode.app/shortcuts.html">Shortcuts</a>
</p>

You can run one Claude Code session in a terminal. GraphCode lets you run ten —
connected, unattended, and still yours to attach to and correct mid-run. Each node in the
graph is a unit of work running inside a real CLI coding-agent session; each edge is a
hand-off, message, or spawn between them. They are real terminals you can attach to and
steer, not headless jobs that report back when they're done.

**[Graph Engineering, simplified →](https://graphcode.app/)** — the full
article: the mental model, then the machinery underneath it.

![Two projects and their connected loops on one GraphCode canvas — every node a live terminal you can attach to](screenshots/graph-hero.png)

## How it works

Every loop type is "an agent runs repeatedly" — they differ in what *you* stop doing:

| Loop type | You hand off | Runs until | For example |
|---|---|---|---|
| **Turn-based** | the check | you end it — each turn pauses for your review inside the session | a refactor you want to eyeball step by step |
| **Goal-based** | the stop condition | a goal is met (optionally a shell predicate exits 0) | "fix the build" — done when `make test` passes |
| **Time-based** | the trigger | you stop it — cadence lives in the prompt (`/loop 1h …`) | hourly issue triage |
| **Composite** | the prompt | a sub-graph of loops runs it end to end | a pipeline that plans its own steps |

Two design choices explain most of the rest:

- **GraphCode schedules nothing.** A time-based loop's recurrence lives *inside* its
  session, written into the prompt with the agent's own `/loop` or `/schedule` skill; the
  daemon only keeps the session alive. That's what makes a running loop something you can
  attach to and correct, rather than a job that already finished somewhere.
- **Sessions outlive everything.** Each loop's terminal is a [`zmx`](https://zmx.sh)
  session, so it survives closing the window, quitting the app, restarting the daemon, and
  a reboot — the backend's session ID is persisted, so relaunching resumes the conversation
  with `--resume` rather than starting a duplicate.

So a working graph might be an hourly triage loop, a hand-off edge into a goal-based fixer
(done when the test suite passes), and a second edge into a turn-based reviewer where you
approve each change yourself. All three stay live terminals — click any node and you're in
that session, scrollback and all.

Each project carries its own graph, laid out as a lane. Cards are painted by the state
they're in rather than their kind, so the canvas reads as which loops are running, which
are done, and which are waiting on you — and the **Graph** view hangs every project's lane
off one START node.

## Install

Requires **macOS 15+ on Apple Silicon** (arm64), with **Claude Code on your `PATH`** —
GraphCode launches it, it doesn't bundle it.

```sh
brew install --cask scgopi/graphcode/graphcode
```

Or grab
[`graphcode-macos-arm64.dmg`](https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg)
from the [latest release](https://github.com/scgopi/GraphCode/releases/latest) and drag
**GraphCode** to Applications. Releases are Developer ID signed and notarized.

## Using it

1. **Add a project** — the sidebar's ⊕ menu: open a local folder, clone a repository from a
   URL, or add a remote repository over SSH (key auth and zmx on the server required — loops
   then run on the server while this Mac steers them). Whatever was open is restored next
   launch.
2. **Create a loop** — ⊕ on the canvas or the Graph view. Write the prompt and hit Create:
   the type chooser explains what each kind hands off, and the title is optional — leave it
   blank and GraphCode asks the loop's own backend for a name. A goal-based loop's done
   check has a **Test** button that runs it exactly as the daemon will.
3. **Open it** — click the node for its terminal workspace: tabs, splits, ⌘K to jump to any
   loop by name, ⌘⇧R to walk the loops asking for you
   ([all shortcuts](https://graphcode.app/shortcuts.html)). Every loop type opens the same
   way, including ones the daemon started on its own — you're attaching to the live session,
   not a copy of its output.
4. **Connect loops** — drag between nodes. An edge is a hand-off by default (fires when the
   source resolves); it can also be a message or a spawn, with a condition and a cycle guard.

## Parts

| Piece | What it is |
|---|---|
| `graphcode.app` | The UI — project sidebar, graph canvas, and a per-loop terminal workspace with tabs and splits |
| `graphcoded` | Background daemon (launchd agent). Owns every project's graph, fires hand-off edges, polls goal predicates, and keeps unattended sessions alive whether or not the app is open |
| `graphcode` | CLI for the same daemon — `graphcode status <project>`, `graphcode node create …`, `graphcode node send …` (type a message into another loop's live session), `graphcode node memo …` (leave a note a relaunched loop reads on its next pass) |
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

make test            # unit tests
make check           # swiftlint + swift-format, both strict
```

Start with `make doctor` when something is missing — it covers the toolchain, the
submodules, the macOS 15 SDK zig needs, and the Metal toolchain GhosttyKit compiles shaders
with. Design docs live in `docs/` and are kept local (gitignored) for now.

## Known limitations

- **Apple Silicon only.** GhosttyKit is built for the native architecture; there is no
  x86_64 slice, so a universal build won't link.
- **Claude Code is the most complete backend.** Copilot CLI and Codex loops launch, run,
  fan out, resume after a reboot, and receive message edges like Claude ones; usage
  reporting stays Claude Code-only. The picker refuses pairings a backend can't host.
- **A new folder stops at Claude's trust prompt.** An unattended loop started by the daemon
  in a folder Claude hasn't seen waits at *"Do you trust this folder?"* and shows as
  `running` while doing nothing. Attach once and answer it.
- **First session start is slow if your shell profile is slow** (conda's hook, for
  instance) — the queued command runs only after the profile finishes.
- **Sessions aren't reaped.** Long-lived `graphcode-*` zmx sessions accumulate; list them
  with `zmx list` and remove dead ones with `zmx kill`.
- **Remote repositories ride one multiplexed SSH connection per host.** A dropped link
  redials itself and degrades readings to "unknown" rather than resolving a loop it merely
  lost sight of. Worktrees aren't available there, goal predicates run locally (write an
  explicit `ssh host …` if the check is remote), and a sleeping Mac fires no edges — the
  daemon stays local by design.

## Inspiration & third-party

Inspired by [Supacode](https://supacode.sh) — same spine of daemon-kept terminal sessions;
its unit is the worktree, GraphCode's is the graph of loops. Built on
[Ghostty](https://ghostty.org) and [zmx](https://zmx.sh), vendored under `ThirdParty/`.

## License

The app and the daemon are under the [Functional Source License](https://fsl.software) v1.1
with an MIT future license ([FSL-1.1-MIT](LICENSE)): use it, change it, self-host it,
redistribute it — the one thing it does not permit is shipping a competing commercial
product built from it, and every release converts to plain MIT two years after it goes out.
`GraphcodeKit/` and `graphcode-cli/` stay [MIT](GraphcodeKit/LICENSE), so scripting against
`graphcode` never raises a licensing question.

Contributions are accepted under the [Developer Certificate of
Origin](DCO) — add a `Signed-off-by` line with `git commit -s`.
