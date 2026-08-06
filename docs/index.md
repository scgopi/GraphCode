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
[All releases →](https://github.com/scgopi/GraphCode/releases) ·
[Keyboard shortcuts →](shortcuts.html)

![Two projects and their connected loops on one GraphCode canvas — every node a live terminal you can attach to](assets/graph-hero.png)

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
| **Composite** | the prompt | a sub-graph of loops runs it end to end | a pipeline that plans its own steps |

The names aren't ours: the taxonomy follows the loop types Anthropic established in
[*Getting started with loops*](https://x.com/ClaudeDevs/status/2074208949205881033).
GraphCode's contribution is making each one a node in a graph — which is also why the
fourth one is called **composite** here rather than proactive: in a graph, that is
exactly what it is.

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

#### Composite — you hand off the prompt

The whole prompt, that is. A composite node is a sub-graph that plans its own steps and
runs them end to end — a graph running inside a graph. You describe the outcome; it
decides the loops.

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
session daemon, like tmux. It survives closing the window, quitting the app,
restarting GraphCode's own daemon, and even a machine reboot: the backend's session
ID is persisted on disk, so the daemon resumes the conversation with `--resume`
rather than starting a duplicate session.

That's what makes unattended and attended the same thing. The daemon starts a loop at
3 a.m.; you click its node at 9 and you're *in the session that did the work*, live,
history above you, process still running.

### The Graph view

The **Graph** row at the top of the sidebar shows every project on one canvas — each
folder's loops in its own lane, all hanging off a single **START** node. It's the
overview you read to know what the whole workspace is doing without clicking into each
project separately.

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

<div style="max-width:640px;margin:2rem auto;">
<svg viewBox="0 0 640 320" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Self-improving cycle: Make hands off to Review, Review records to Memory, Memory feeds back to Make. A guarded back-edge closes the cycle.">
  <rect width="640" height="320" rx="16" fill="#161b22"/>
  <text x="320" y="32" text-anchor="middle" fill="#8b949e" font-family="-apple-system,sans-serif" font-size="13" letter-spacing="0.5">How a loop gets better</text>
  <!-- edges -->
  <defs>
    <marker id="ah" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto"><path d="M0,0 L10,4 L0,8" fill="#58a6ff"/></marker>
    <marker id="ah-g" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto"><path d="M0,0 L10,4 L0,8" fill="#3fb950"/></marker>
  </defs>
  <!-- MAKE → REVIEW -->
  <line x1="210" y1="150" x2="330" y2="150" stroke="#58a6ff" stroke-width="2.5" marker-end="url(#ah)"/>
  <text x="270" y="138" text-anchor="middle" fill="#58a6ff" font-family="-apple-system,sans-serif" font-size="11">hand-off</text>
  <!-- REVIEW → RECORD -->
  <line x1="468" y1="180" x2="468" y2="240" stroke="#58a6ff" stroke-width="2.5" marker-end="url(#ah)"/>
  <text x="498" y="215" fill="#58a6ff" font-family="-apple-system,sans-serif" font-size="11">record</text>
  <!-- RECORD → MAKE (guarded back-edge) -->
  <path d="M340,270 Q168,310 168,200" stroke="#3fb950" stroke-width="2.5" stroke-dasharray="8,5" marker-end="url(#ah-g)" fill="none"/>
  <text x="210" y="298" fill="#3fb950" font-family="-apple-system,sans-serif" font-size="11">guarded ↩</text>
  <!-- nodes -->
  <circle cx="168" cy="150" r="42" fill="#5eead4"/>
  <text x="168" y="155" text-anchor="middle" fill="#0f2e29" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="16">MAKE</text>
  <circle cx="468" cy="150" r="42" fill="#a5b4fc"/>
  <text x="468" y="147" text-anchor="middle" fill="#272b52" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="14">REVIEW</text>
  <text x="468" y="163" text-anchor="middle" fill="#272b52" font-family="-apple-system,sans-serif" font-size="10">judge</text>
  <circle cx="468" cy="270" r="30" fill="#fcd34d"/>
  <text x="468" y="274" text-anchor="middle" fill="#4d3a06" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="12">RECORD</text>
  <circle cx="280" cy="270" r="30" fill="#f0abfc" opacity="0.95"/>
  <text x="280" y="267" text-anchor="middle" fill="#3d1a4e" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="11">MEA-</text>
  <text x="280" y="280" text-anchor="middle" fill="#3d1a4e" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="11">SURE</text>
  <!-- MEASURE → RECORD -->
  <line x1="310" y1="270" x2="430" y2="270" stroke="#58a6ff" stroke-width="2.5" marker-end="url(#ah)"/>
  <text x="370" y="260" text-anchor="middle" fill="#58a6ff" font-family="-apple-system,sans-serif" font-size="11">log metric</text>
  <text x="320" y="310" text-anchor="middle" fill="#6e7681" font-family="-apple-system,sans-serif" font-size="12">So pass two starts where pass one stopped.</text>
</svg>
</div>

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

<div style="max-width:580px;margin:2rem auto;">
<svg viewBox="0 0 580 200" fill="none" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Two writers feed the memory log: the daemon records facts, the agent records lessons. A relaunched session reads the digest.">
  <rect width="580" height="200" rx="16" fill="#161b22"/>
  <text x="290" y="28" text-anchor="middle" fill="#8b949e" font-family="-apple-system,sans-serif" font-size="13" letter-spacing="0.5">What it learns goes into its own log</text>
  <defs>
    <marker id="ah2" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto"><path d="M0,0 L10,4 L0,8" fill="#58a6ff"/></marker>
    <marker id="ah2-g" markerWidth="10" markerHeight="8" refX="9" refY="4" orient="auto"><path d="M0,0 L10,4 L0,8" fill="#3fb950"/></marker>
  </defs>
  <!-- Daemon node -->
  <circle cx="80" cy="80" r="30" fill="#5eead4"/>
  <text x="80" y="76" text-anchor="middle" fill="#0f2e29" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="11">DAE-</text>
  <text x="80" y="89" text-anchor="middle" fill="#0f2e29" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="11">MON</text>
  <!-- Agent node -->
  <circle cx="80" cy="155" r="30" fill="#a5b4fc"/>
  <text x="80" y="159" text-anchor="middle" fill="#272b52" font-family='SFMono-Regular,Menlo,monospace' font-weight="700" font-size="12">AGENT</text>
  <!-- Memory log -->
  <rect x="210" y="60" width="160" height="110" rx="10" fill="#0d1117" stroke="#30363d" stroke-width="1.5"/>
  <text x="290" y="82" text-anchor="middle" fill="#e6edf3" font-family='SFMono-Regular,Menlo,monospace' font-weight="600" font-size="13">memory log</text>
  <text x="230" y="104" fill="#8b949e" font-family='SFMono-Regular,Menlo,monospace' font-size="10">pass started</text>
  <text x="230" y="120" fill="#8b949e" font-family='SFMono-Regular,Menlo,monospace' font-size="10">metric: 41 → 22</text>
  <text x="230" y="136" fill="#8b949e" font-family='SFMono-Regular,Menlo,monospace' font-size="10">memo: X is dead</text>
  <text x="230" y="152" fill="#8b949e" font-family='SFMono-Regular,Menlo,monospace' font-size="10">pass resolved ✓</text>
  <!-- Daemon → log -->
  <line x1="115" y1="80" x2="200" y2="90" stroke="#58a6ff" stroke-width="2" marker-end="url(#ah2)"/>
  <text x="158" y="76" text-anchor="middle" fill="#58a6ff" font-family="-apple-system,sans-serif" font-size="10">facts</text>
  <!-- Agent → log -->
  <line x1="115" y1="150" x2="200" y2="140" stroke="#58a6ff" stroke-width="2" marker-end="url(#ah2)"/>
  <text x="158" y="156" text-anchor="middle" fill="#58a6ff" font-family="-apple-system,sans-serif" font-size="10">lessons</text>
  <!-- log → next session -->
  <rect x="430" y="85" width="120" height="60" rx="10" fill="#0d1117" stroke="#3fb950" stroke-width="1.5"/>
  <text x="490" y="111" text-anchor="middle" fill="#3fb950" font-family='SFMono-Regular,Menlo,monospace' font-weight="600" font-size="12">next pass</text>
  <text x="490" y="128" text-anchor="middle" fill="#6e7681" font-family="-apple-system,sans-serif" font-size="10">reads digest</text>
  <line x1="378" y1="115" x2="422" y2="115" stroke="#3fb950" stroke-width="2" marker-end="url(#ah2-g)"/>
</svg>
</div>

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
out on their own provider, message, and keep memory like Claude ones. Copilot presence
is read from its event log (local and remote), so a Copilot loop waiting for input
shows as "NEEDS YOU"; usage stays Claude Code-only. The picker refuses pairings a
backend can't host. Current rough edges live in the README's
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

{% if site.buttondown_username %}
<form class="gc-subscribe"
      action="https://buttondown.com/api/emails/embed-subscribe/{{ site.buttondown_username }}"
      method="post"
      target="_blank">
  <label class="gc-subscribe-label" for="gc-email">
    <strong>Get the next one.</strong>
    New releases and the next article — nothing else, and one click to leave.
  </label>
  <div class="gc-subscribe-row">
    <input class="gc-subscribe-input" type="email" id="gc-email" name="email"
           placeholder="you@example.com" autocomplete="email" required>
    <button class="gc-subscribe-btn" type="submit">Subscribe</button>
  </div>
</form>
{% endif %}

Building from source, development commands, and limitations are in the
[README](https://github.com/scgopi/GraphCode#readme). The app is under the
[Functional Source License](https://github.com/scgopi/GraphCode/blob/main/LICENSE)
— free to use, read, change and self-host, converting to MIT two years after each
release — while `GraphcodeKit` and the `graphcode` CLI stay MIT. It is built on the
independent open-source projects [Ghostty](https://ghostty.org) and
[zmx](https://zmx.sh).

Questions, feedback, or just following along — find me on
[X (@scgopi)](https://x.com/scgopi) or [LinkedIn](https://www.linkedin.com/in/scgopi/).
