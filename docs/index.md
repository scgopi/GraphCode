---
title: Graph Engineering, Simplified — with GraphCode
description: Graph engineering for coding agents on macOS — loops and their types, self-improving loops, and the machinery underneath.
---

# Graph Engineering, simplified — with GraphCode

You can run one Claude Code session in a terminal. GraphCode lets you run ten —
connected, unattended, and still yours to attach to and correct mid-run. That's
**graph engineering**: your agents' work arranged as a graph you design, instead of a
pile of terminals you babysit.

Requires **macOS 15+ on Apple Silicon**, with **Claude Code on your `PATH`** —
GraphCode launches it, it doesn't bundle it.
[All releases →](https://github.com/scgopi/GraphCode/releases)

![Two projects and their connected loops on one GraphCode canvas — goal-based, time-based, and proactive nodes, every one a live terminal](assets/graph-hero.png)

<!-- VIDEO SLOT: demo video goes here when ready -->

This article is in three parts: the four loops an AI session can run — the claim the
rest is built on — the self-improving loop, where the graph starts to learn, and, for
contributors, the machinery underneath.

---

## Part 1 — The four loops an AI session can run

### The problem

An agent in a terminal is powerful but singular: one session, one task, gone when you
close the window. The obvious fix — cron firing `claude -p` headlessly — throws away
what made the terminal good: you could watch it, interrupt it, redirect it.

GraphCode keeps both. Work is a **graph of loops**: each node is a unit of agentic work
inside a real CLI session, each edge a relationship between two of them. The sessions
stay real, attachable terminals the whole time — the automation lives in the graph
around them, not in taking the terminal away.

### Every loop is an AI session that runs repeatedly

The unit of work in GraphCode is the **loop**: a real CLI agent session — Claude Code,
Copilot CLI, or Codex — that runs again and again instead of once. Not a script that
calls a model, not a job that reports back when it's done: a live terminal you can open
mid-run, with an agent inside that keeps going.

Here's the claim this whole design rests on. When you put an agent on repeat, you are
handing it something you used to do yourself — and there are only four things you can
hand off: the **check**, the **stop condition**, the **trigger**, or the **prompt
itself**. Four hand-offs, four loop types. This isn't a feature list that will grow a
fifth entry next release; it's the space of loops possible:

| Loop type | You hand off | Runs until | For example |
|---|---|---|---|
| **Turn-based** | the check | you end it — each turn pauses for your review | a refactor you eyeball step by step |
| **Goal-based** | the stop condition | the goal is met (optionally: a shell command exits 0) | "fix the build" — done when `make test` passes |
| **Time-based** | the trigger | you stop it — cadence lives in the prompt (`/loop 1h …`) | hourly issue triage |
| **Proactive** | the prompt | a composite sub-graph runs it end to end | a pipeline that plans its own steps |

The names aren't ours: the taxonomy follows the loop types Anthropic established in
[*Getting started with loops*](https://x.com/ClaudeDevs/status/2074208949205881033).
GraphCode's contribution is making each one a node in a graph.

#### Turn-based — you stay in the sequence

The session stops after every turn and waits for you. It exists because a person
belongs in this sequence: your review criterion travels into the loop's opening prompt,
so you state it once and never retype it. The loop does the work; you keep the
judgment. Use it for the refactor you want to watch happen, change by change.

#### Goal-based — you hand off "done"

You hand this loop a statement of done (the form refuses an empty one), and optionally
a shell predicate — a command the daemon polls, where exit 0 means finished. "Fix the
build" resolves itself the moment `make test` passes, whether you were watching or
asleep. This is the workhorse type, and the one the self-improving cycle in Part 2 is
built around.

#### Time-based — you hand off the trigger

You hand this loop its cadence, and the cadence lives *inside the session* — written
into the prompt with the agent's own `/loop` or `/schedule` skill (`/loop 1h Triage
new bug reports`). Nothing external fires it; the session re-triggers itself, which is
why you can attach at any point and see every pass it has ever run in one scrollback.

#### Proactive — you hand off the prompt

The whole prompt, that is. A proactive node is a composite: a sub-graph that plans its
own steps and runs them end to end — a graph running inside a graph. You describe the
outcome; it decides the loops.

Pick the type by what you're ready to let go of — the check, the stop condition, the
trigger, or the prompt itself. A working graph usually mixes them: a time-based triage
loop hands findings to a goal-based fixer, which hands the fix to a turn-based
reviewer where you approve each change yourself.

### GraphCode schedules nothing

A time-based loop's recurrence lives *inside* its session, written into the prompt with
the agent's own `/loop` or `/schedule` skill. GraphCode holds no timers and never fires
a headless `claude -p`.

An early version did the opposite — a timer per node, output discarded. It worked, and
it was worthless: nothing to attach to, nothing to steer. Moving the cadence into the
session makes a running loop an ordinary terminal that happens to be busy. The daemon's
only duty is **liveness**: making sure the session exists.

### Sessions outlive everything

Each loop's terminal is a [`zmx`](https://zmx.sh) session — a PTY kept alive by a
session daemon, like tmux. It survives closing the window, quitting the app, and
restarting GraphCode's own daemon; reattaching restores full scrollback.

That's what makes unattended and attended the same thing. The daemon starts a loop at
3 a.m.; you click its node at 9 and you're *in the session that did the work*, live,
history above you, process still running.

### Projects: local, cloned, or remote

From the sidebar's ⊕ menu a project can be a **local folder**, a **repository cloned
from a URL**, or a **repo on another machine over SSH** — the loops run there, your Mac
draws the graph and steers them. The remote case falls out of the session model:
`zmx attach` becomes `ssh -t host zmx attach`, and everything above it is unchanged.

### Edges: the three ways loops talk

Drag between two nodes and you get an edge:

| Kind | What it does | Blocks its target? |
|---|---|---|
| **Hand-off** | fires when the source resolves, unblocking the target | yes |
| **Message** | injects text into a running peer's live session | no |
| **Spawn** | instantiates a new node from a template — the one kind that may cross into another project's graph | no |

Each edge carries a condition — always, on success, on failure. An `on failure`
hand-off is how you build "if the nightly build breaks, wake the fixer."

### And loops can just talk

Edges are standing relationships. For the one-off — a loop deciding mid-run that a peer
should know something — there's the CLI:

```sh
graphcode node send <project-path> <node-id> the API changed under you, heads up
```

The message is typed straight into the target's live terminal, attributed to its
sender. A target that isn't live doesn't lose the message: it's **staged into that
loop's memory** and read at its next wake, and the sender is told which happened.
Every session is briefed on this verb, so "tell loop 5 to stop" is something you can
ask a loop to do.

### A goal knows when it's done

A goal has two halves: the **summary** (the human statement of done, required) and the
**predicate** (an optional shell command the daemon polls; exit 0 resolves the node).
The predicate is also written into the session's prompt, so the agent and the daemon
never work to two definitions of done. A loop moves through a small lifecycle — *idle →
running → succeeded / failed / stalled / stopped* — and **stopped** is deliberately not
**failed**: work someone chose to end didn't go wrong.

---

## Part 2 — The self-improving loop

A self-improving loop is a simple sentence: **try → get judged → remember → try again
smarter → stop honestly.** GraphCode gives each verb a mechanism.

### The shape: a bounded cycle

Draw a maker and a reviewer, hand-off forward, and a **guarded back-edge** closing the
cycle. An unguarded edge fires exactly once; attaching a guard is what lets it re-fire,
and a guard must carry a bound — a pass cap, an `until` shell condition, a stop after N
passes without improvement, or any mix. The feature that lets a loop repeat is the same
feature that bounds it, so "loop forever, unattended, spending tokens" cannot be said
by accident.

### Every pass is announced

When a cycle re-enters, the loop is *told*, right in its terminal:

> `[graphcode] Cycle re-entry 2 of 5 — the stop condition is not yet met. Continue
> toward your goal.`

Hand-offs announce themselves the same way, and an edge can carry a payload — a text
note, or a script whose output rides along (`git diff --stat`, the reviewer's notes).
Without this, a still-open session had no idea its next pass had started; it just sat
there while the graph said "running."

### Every loop keeps a diary

Each loop has an append-only memory log (`~/.graphcode/memory/…`). Two writers:

- **The daemon records facts** — pass started, resolved how, metric readings, messages
  staged while the loop was away.
- **The agent records lessons** — `graphcode node memo <project> <id> approach X is a
  dead end` — decisions and constraints, not a transcript.

A relaunched session opens by reading a short digest of it: recent entries in full,
older ones elided. Round two starts *smarter*, not from scratch. And a loop created by
another loop is born with its first entry already written — the exact command for
reporting results back to its parent, so nothing is guessed.

### Measured by: the loop's own fitness function

A goal can carry a metric — a command whose last printed line is a number, plus which
direction is better. It's a *method*, not just a score: the loop is handed it in its
opening prompt ("measure your performance with this command — run it as you work"), so
it can steer. The orchestrator independently runs the same command once per pass, so
the recorded numbers come from the measurement, never from the loop's self-report.

The history feeds the diary, and the cycle guard can act on it: **stop after N passes
without improvement** ends a cycle that keeps running but stopped getting better — as
*stalled*, which is the honest word for it.

### Loops can be re-instructed, within limits

`graphcode node update` edits a live loop — its goal, predicate, poll and stall bounds,
metric, model tier — without delete-and-recreate. Changes the session was told at
launch are told to it again, live; everything lands in the diary either way. One rule
has teeth: **a loop may not change its own stop condition.** The verifier stays outside
the verified — the same reason maker and reviewer are separate sessions.

### Family rules

A loop that fans work out into child loops gets three guarantees: children run on
**their parent's backend** (a Copilot loop spawns Copilot children), children know how
to **report back** (the route is in their diary from birth), and children **die with
their parent** — stopping or deleting a coordinator takes its spawned descendants,
sessions and all. Custody comes from creation, never from drawn edges: stopping one
side of a maker–reviewer pair you drew leaves the other side alone.

---

## Part 3 — Under the hood

### Four pieces, one socket

| Piece | Role |
|---|---|
| `graphcode.app` | SwiftUI app — sidebar, canvas, per-loop terminal workspace, rendered with GhosttyKit |
| `graphcoded` | The orchestrator daemon, kept alive by launchd — owns every project's graph and all automation |
| `graphcode` | CLI speaking to the same daemon — `status`, `node create`, `node send`, `node memo`, `node update`, `node delete` |
| `GraphcodeKit` | The shared framework all three link, so the app and daemon can never disagree about what a loop is |

The app and CLI are both clients, speaking length-framed JSON over a Unix socket
(`~/.graphcode/graphcoded.sock`). After every mutation the daemon broadcasts the whole
graph to every client, so two windows and a CLI always agree. Validation happens in the
daemon — a rule only one client enforces isn't a rule.

### GraphStore: the automation core

One `GraphStore` actor per open project owns that project's graph: it fires edges when
nodes resolve, polls goal predicates, samples metrics at pass boundaries, delivers or
stages messages, appends the memory records, and keeps unattended sessions alive across
daemon restarts. It knows nothing about zmx, sockets, or subprocesses — every effect is
an injected closure — which is why the automation core is fully unit-testable without
spawning a process.

### How a session starts, and why attaching just works

The session is named after the node's ID — exactly the name the app's terminal surface
attaches to, so "the daemon started it" and "you opened it" converge on one PTY with
one scrollback. Commands run through an interactive login shell (launchd's bare `PATH`
would otherwise make `claude` unfindable), and prompts ride as arguments, never
interpolated into shell syntax.

Every session receives a **briefing** about the graph it runs inside — loop types, the
CLI, how to message a peer and record memory — delivered however its backend takes
instructions (Claude Code as a system-prompt file; Copilot and Codex as a pointed-at
file they're granted access to read). That's what lets a loop asked to "fix each of
these five issues" create five sibling loops instead of grinding through them.

One PTY detail worth knowing: agent TUIs treat text-plus-newline in a single chunk as a
*pasted* newline, so delivered messages send Enter as its own keystroke, a beat after
the text — otherwise every message rendered in the composer and sat there, unsent.

### Reported, never estimated

GraphCode can't see inside a running agent. Presence and token usage are read from
per-session labels the backend's own hooks can set; without hooks the UI says "not
reported" rather than showing a zero nobody measured. The same honesty rule shapes the
metric design: numbers a decision rests on come from running the command, not from the
loop's account of itself.

### State: one directory, plain JSON

Everything lives in `~/.graphcode/` — graphs, memory logs, layouts, socket, logs,
installed binaries. **Nothing is ever written inside a project folder you open.** Every
domain type decodes missing fields to defaults, hand-written, because a decode failure
reads to a user as *their project got wiped* — a graph saved by last month's build
always loads in today's.

### What runs today

Claude Code is the most complete backend. Copilot CLI and Codex loops launch, run, fan
out on their own provider, message, and keep memory like Claude ones; hook-reported
presence and usage stay Claude Code-only, and the picker refuses pairings a backend
can't host. Current rough edges live in the README's
[Known limitations](https://github.com/scgopi/GraphCode#known-limitations).

---

## Try it

1. **`brew install --cask scgopi/graphcode/graphcode`** — or
   [download the .dmg](https://github.com/scgopi/GraphCode/releases/latest/download/graphcode-macos-arm64.dmg)
   and drag GraphCode to Applications. Releases are Developer ID signed and notarized.
2. Add a folder — or clone a URL, or connect a repo over SSH — then create a loop: just
   write the goal, GraphCode names it for you. Connect a second one with an edge. For a
   self-improving pair, give the goal a *Measured by* command and close the cycle with a
   guarded back-edge.
3. Close the app whenever you like — the loops won't notice.

Building from source, development commands, and limitations are in the
[README](https://github.com/scgopi/GraphCode#readme). GraphCode is
[MIT-licensed](https://github.com/scgopi/GraphCode/blob/main/LICENSE), built on the
independent open-source projects [Ghostty](https://ghostty.org) and
[zmx](https://zmx.sh).

Questions, feedback, or just following along — find me on
[X (@scgopi)](https://x.com/scgopi) or [LinkedIn](https://www.linkedin.com/in/scgopi/).
