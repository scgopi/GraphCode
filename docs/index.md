---
title: Graph Engineering, Simplified — with GraphCode
description: Graph engineering for coding agents on macOS — the mental model, and the machinery underneath it.
---

# Graph Engineering, simplified — with GraphCode

You can run one Claude Code session in a terminal. GraphCode lets you run ten —
connected, unattended, and still yours to attach to and correct mid-run. That's
**graph engineering**: your agents' work arranged as a graph you design, instead of a
pile of terminals you babysit.

**[⬇ Download GraphCode (.dmg, latest release)](https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg)**
· [All releases](https://github.com/scgopi/GraphCode/releases) ·
[Source on GitHub](https://github.com/scgopi/GraphCode) · Requires macOS 15+ on Apple
Silicon, with Claude Code on your `PATH`.

![Five projects and dozens of connected loops on one GraphCode canvas — every node is a live terminal](assets/graph-hero.png)

<!-- VIDEO SLOT: demo video goes here when ready -->

This article is in two parts. The first explains the mental model — what a loop is, what
an edge does, why the sessions are real terminals. The second opens the hood for
contributors: the app/daemon/CLI split, how sessions are created and reattached, and how
edges actually fire.

---

## Part 1 — The mental model

### The problem

A coding agent in a terminal is powerful but *singular*: one session, one task, and it
stops mattering the moment you close the window. The obvious fix — cron jobs firing
`claude -p` headlessly — throws away the thing that made the terminal session good: you
could watch it, interrupt it, and redirect it.

GraphCode's premise is that you shouldn't have to choose. Work is arranged as a **graph
of loops**: each node is a unit of agentic work running inside a real CLI session, and
each edge is a relationship between two of them. The sessions stay real, attachable
terminals the whole time — automation comes from the graph around them, not from taking
the terminal away.

### Loops: what you hand off

Every loop type is "an agent runs repeatedly" — they differ in what *you* stop doing:

| Loop type | You hand off | Runs until |
|---|---|---|
| **Turn-based** | the check | you end it — each turn pauses for your review inside the session |
| **Goal-based** | the stop condition | the goal is met (optionally: a shell command exits 0) |
| **Time-based** | the trigger | you stop it — cadence lives in the prompt (`/loop 1h …`) |
| **Proactive** | the prompt | a composite sub-graph runs it end to end |

The hand-off framing is load-bearing. A turn-based loop exists because *a person is in
the sequence* — its session is told to stop after every turn for review, and the
criterion you wrote travels into the session's opening prompt so you never retype it. A
goal-based loop is handed a statement of "done" (and the creation form refuses an empty
one — a goal without a stop condition is a modelling error, not a style choice). A
time-based loop is handed a trigger, and a proactive node is handed the whole prompt: it
is the orchestrator running a graph *inside* a graph.

### The first design choice: GraphCode schedules nothing

A time-based loop's recurrence lives *inside* its session, written into the prompt with
the agent's own `/loop` or `/schedule` skill. GraphCode holds no interval of its own,
runs no timers, and never fires a headless `claude -p`.

An early version did the opposite — a timer per node, a headless invocation per tick,
output discarded. It worked, and it was worthless: there was nothing to attach to,
nothing to watch, nothing to steer. Moving the cadence into the session is what makes a
running loop an ordinary interactive terminal that happens to be busy, rather than a job
that already finished somewhere else. The daemon's only remaining duty for such a loop is
**liveness**: making sure the session exists.

### The second design choice: sessions outlive everything

Each loop's terminal is a [`zmx`](https://zmx.sh) session — a PTY kept alive by a
session daemon, the same idea as tmux. It survives closing the window, quitting the app,
and restarting GraphCode's own daemon. Reattaching restores full scrollback.

This is also what makes unattended and attended the *same thing*. When the daemon starts
a goal-based loop at 3 a.m., and you click its node at 9, you are not reading a log of
what happened — you are in the session that did it, live, with its history above you and
its process still running.

### Projects don't have to be local

A project can start three ways from the sidebar's ⊕ menu: open a **local folder**,
**clone a repository from a URL** (progress streams into the form; the finished clone is
an ordinary project), or **add a remote repository over SSH** — a repo on another
machine, where the loops themselves run on that machine while your Mac draws the graph
and steers them.

The remote case follows directly from the session model: a loop's terminal was already
"a `zmx` session somewhere, attached to on demand", and the only thing that knows *where*
is the attach command — `zmx attach` becomes `ssh -t host zmx attach` and everything
above it is unchanged. The daemon stays on your Mac; every remote effect is a command
run over ssh. Connections are validated up front (key auth, the path being a repo, zmx
installed there), because each of those failures would otherwise surface as a loop that
silently does nothing. Remote rows wear a network glyph in the sidebar so where the
shells run is readable at a glance. The current edges of remote support are listed in
the README's
[Known limitations](https://github.com/scgopi/GraphCode#known-limitations).

### Edges: the three ways loops talk

Drag between two nodes and you get an edge. There are three kinds:

| Kind | What it does | Blocks its target? |
|---|---|---|
| **Hand-off** | fires when the source resolves, unblocking the target | yes — the target waits for it |
| **Message** | injects text into a running peer's live session | no — peers run concurrently |
| **Spawn** | instantiates a new node from a template — the one kind allowed to cross into another project's graph | no — a template isn't waiting |

Each edge carries a **condition** — always, on success, or on failure — evaluated
against how the source resolved. An `on failure` hand-off is how you build "if the
nightly build breaks, wake the fixer."

### Cycles are opt-in, and bounded by construction

An unguarded edge fires exactly once. To make a cycle actually loop, you attach a
**cycle guard** — and a guard must carry a bound: a maximum iteration count, an `until`
shell condition, or both. The feature that lets a loop repeat is the same feature that
bounds it, so there is no way to express "loop forever, unattended, spending tokens" by
accident.

### Knowing when a goal is done

A goal-based loop's stop condition has two halves. The **summary** is the human statement
of done, and it is required. The **predicate** is an optional shell command — the machine
version — and the daemon polls it (once a minute by default), resolving the node the
moment it exits 0. The same predicate is written into the session's opening prompt, so
the agent and the daemon are never working to two different definitions of done. Goals
with no honest shell equivalent ("the design doc reads clearly") simply omit the
predicate and resolve when their session exits.

A loop moves through a small lifecycle — *idle → running → succeeded / failed / stalled /
stopped* — and **stopped** is deliberately distinct from **failed**: work someone chose
to end didn't go wrong, and filing it as a failure would bury real failures in noise.

---

## Part 2 — Under the hood

### Four pieces, one socket

| Piece | Role |
|---|---|
| `graphcode.app` | SwiftUI app — sidebar, graph canvas, per-loop terminal workspace (tabs, splits), rendering terminals with GhosttyKit |
| `graphcoded` | The orchestrator daemon, kept alive by launchd. Owns every project's graph and all automation |
| `graphcode` | CLI speaking to the same daemon — `graphcode status <project>`, `graphcode node create …` |
| `GraphcodeKit` | The shared framework all three link — the domain model, persistence, IPC, and session plumbing live here once, so the app and daemon can never disagree about what a loop is |

The app and CLI are both *clients*. They connect to `graphcoded` over a Unix domain
socket (`~/.graphcode/graphcoded.sock`) speaking length-framed JSON. Commands flow in;
after every mutation the daemon broadcasts the updated graph to every connected client,
so two app windows and a CLI watching the same project always agree. Validation happens
in the daemon, not just the app's forms — a rule only one client enforces isn't a rule.

### GraphStore: the automation core

Inside the daemon, one `GraphStore` actor per open project owns that project's graph.
It is the whole of what makes `graphcoded` load-bearing:

- **Edge firing.** When a node resolves, the store walks its outgoing edges, evaluates
  each condition against how the node resolved, and fires the ones that pass — unblocking
  hand-off targets, delivering messages, instantiating spawns.
- **Goal polling.** One background task per goal predicate, at the node's poll interval.
- **Liveness.** Unattended loops (time-based and goal-based) get their sessions started
  at creation and re-ensured when the daemon restarts — nothing else would restart them.
- **Honest failure surfaces.** A message edge whose target has no live session isn't
  silently dropped; it's recorded as undelivered and shown.

Notably, `GraphStore` knows nothing about zmx, sockets, or subprocesses — every effect
is an injected closure the daemon wires up at startup. That's why the automation core is
fully unit-testable without spawning a process.

Cross-project spawn edges can't be handled by a store that owns exactly one graph, so
they're handed up to the `ProjectRegistry` — the daemon layer that holds one store per
open project and does the routing.

### How a session starts, and why attaching just works

When the daemon starts an unattended loop, it runs the node's backend command inside a
detached zmx session. Three details carry most of the weight:

- **Shared identity is the mechanism.** The session is named after the node's ID —
  exactly the name the app's terminal surface attaches to. `zmx attach` joins an existing
  session rather than starting a second one, so "the daemon started it" and "you opened
  it" converge on the same live PTY, scrollback intact. There is no attach *protocol*;
  there is one session and two doors.
- **The login-shell trick.** launchd gives the daemon a bare `PATH`. Commands are
  wrapped in `/bin/zsh -i -l -c` — and `-i` is load-bearing, not decoration: a
  developer's real `PATH` is typically set in `~/.zshrc`, which zsh only reads when
  interactive. Without it, `claude` is `command not found` for every daemon-started loop.
- **Prompts are arguments, not syntax.** The node's opening prompt rides in as `"$@"`
  rather than being interpolated into the shell script, so a goal containing quotes,
  `;`, or `$(…)` is one argument and cannot become shell code.

The opening prompt itself is computed in exactly one place (`LoopNode.sessionPrompt`),
shared by the daemon and the app, so the two can never disagree about what a loop starts
with.

Every session also receives a **briefing** about the graph it runs inside — a file
explaining the loop types and the `graphcode` CLI, delivered however its backend takes
instructions (Claude Code as a system-prompt file, Copilot and Codex as a pointer the
session is granted access to read). That's what lets a loop asked to "fix each of these
five issues" create five sibling loops instead of grinding through them in sequence —
fan-out is a capability of every session, whichever of the two launchers started it.

### Presence and usage: reported, never estimated

GraphCode cannot see inside a running `claude`. Rather than guess, it reads per-session
labels that the backend's own lifecycle hooks can set (`zmx set "$ZMX_SESSION"
presence=busy`, and similarly for token usage). With hooks installed, readings are
*reported*; without them, the UI says "not reported" instead of showing a zero nobody
measured. GraphCode deliberately doesn't install those hooks itself — that would mean
editing your Claude Code settings behind your back.

### State: one directory, plain JSON

Everything lives in `~/.graphcode/` — per-project graphs, recents, terminal layouts, the
daemon socket and logs, and the installed binaries under `bin/`. **Nothing is ever
written inside a project folder you open.**

It's a dotfile directory rather than `~/Library/Application Support` for two concrete
reasons: the state is plain JSON a developer will want to `cat` and `jq`, and it sits
where developers already look (`~/.claude`, `~/.ssh`); and a Unix socket path is capped
at 104 bytes on Darwin — the Application Support path burns most of that and grows with
the username, while `~/.graphcode/graphcoded.sock` leaves real headroom.

Persistence is defensive by design: every domain type decodes missing fields to
defaults, hand-written, because a decode failure reads to a user as *their project got
wiped*. A graph saved by last month's build always loads in today's.

### What runs today

Claude Code is the most complete backend. Copilot CLI and Codex sessions launch, run,
and can fan work out into new loops; mid-session messaging and reported presence are
still Claude Code-only, and the picker refuses pairings a backend can't host. The full
current list of rough edges lives in the README's
[Known limitations](https://github.com/scgopi/GraphCode#known-limitations).

---

## Try it

1. **[Download GraphCode (.dmg, latest release)](https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg)** —
   drag GraphCode to Applications; that's the whole install. Releases are Developer ID
   signed and notarized.
2. Add a folder — or clone a URL, or connect a repo on another machine over SSH — then
   create a loop: just write the goal; the title is optional, GraphCode names it for
   you. Connect a second one with an edge.
3. Close the app whenever you like — the loops won't notice.

Building from source, development commands, and limitations are in the
[README](https://github.com/scgopi/GraphCode#readme). GraphCode is
[MIT-licensed](https://github.com/scgopi/GraphCode/blob/main/LICENSE), built on the
independent open-source projects [Ghostty](https://ghostty.org) and
[zmx](https://zmx.sh).
