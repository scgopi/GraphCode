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

![Two projects and their connected loops on one GraphCode canvas — every node a live terminal you can attach to](assets/graph-hero.png?v=2)

<!-- VIDEO SLOT: demo video goes here when ready -->

This article is in three parts: the four loops an AI session can run — the claim the
rest is built on — the self-improving loop, where the graph starts to learn, and, for
contributors, the machinery underneath.

---

## Part 1 — Four loop types

A **loop** is a CLI agent session (Claude Code, Copilot, Codex) that runs repeatedly instead of once — a live terminal you can attach to mid-run.

When you put an agent on repeat, you hand off one of four things: the **check**, the **stop condition**, the **trigger**, or the **prompt itself**. That's the space of loops possible:

| Loop type | You hand off | Runs until | Example |
|---|---|---|---|
| **Turn-based** | the check | you end it — pauses each turn | a refactor you eyeball step by step |
| **Goal-based** | the stop condition | goal met (optionally: shell exits 0) | "fix the build" — done when `make test` passes |
| **Time-based** | the trigger | you stop it — cadence in the prompt | `/loop 1h Triage new bug reports` |
| **Composite** | the prompt | a sub-graph runs end to end | a pipeline that plans its own steps |

Pick by what you're ready to let go of. A working graph often mixes them: a time-based triage loop hands findings to a goal-based fixer, which hands the fix to a turn-based reviewer.

### Sessions outlive everything

Each loop is a [`zmx`](https://zmx.sh) session — a PTY that survives quitting the app, restarting the daemon, or rebooting. The daemon starts a loop at 3 a.m.; you click its node at 9 and you're *in the session that did the work*, live.

### Projects

From the sidebar's ⊕ menu: a **local folder**, a **cloned repo**, or a **repo over SSH** — remote loops run there, your Mac draws the graph.

### Edges

Drag between nodes to connect them:

| Kind | What it does | Blocks target? |
|---|---|---|
| **Hand-off** | fires when source resolves, unblocking target | yes |
| **Message** | injects text into running peer | no |
| **Spawn** | instantiates a copy from a template | no |

Each edge carries a condition — always, on success, on failure. An `on failure` hand-off builds "if the nightly breaks, wake the fixer."

### Ad-hoc messaging

Loops can message each other mid-run via the CLI:

```sh
graphcode node send <project-path> <node-id> the API changed, heads up
```

A target that isn't live doesn't lose the message — it's **staged** and read at next wake.

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

<div style="max-width:560px;margin:2rem auto;background:#161b22;border-radius:12px;padding:1.5rem;">
<div style="font-family:SFMono-Regular,Menlo,monospace;font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:1rem;">Edge firing and cycle re-entry</div>
<svg viewBox="0 0 560 200" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Animated: guarded edge fires, pulse travels loopback, cycle re-enters">
  <defs>
    <marker id="arr" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#58a6ff"/></marker>
  </defs>
  <!-- Forge node -->
  <rect x="60" y="70" width="100" height="60" rx="6" fill="#21262d" stroke="#484f58" stroke-width="1.5"/>
  <text x="110" y="95" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="11" fill="#8b949e">FORGE</text>
  <text x="110" y="115" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="12" fill="#e6edf3">Make change</text>
  <!-- Critic node -->
  <rect x="260" y="70" width="100" height="60" rx="6" fill="#21262d" stroke="#484f58" stroke-width="1.5"/>
  <text x="310" y="95" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="11" fill="#8b949e">CRITIC</text>
  <text x="310" y="115" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="12" fill="#e6edf3">Verify change</text>
  <!-- Guard indicator -->
  <rect x="440" y="75" width="70" height="50" rx="4" fill="#21262d" stroke="#30363d" stroke-width="1"/>
  <text x="475" y="95" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="9" fill="#8b949e">GUARD</text>
  <text x="475" y="112" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="10" fill="#e6edf3">≤5×</text>
  <!-- Edge: forge → critic -->
  <line x1="160" y1="100" x2="255" y2="100" stroke="#58a6ff" stroke-width="2" marker-end="url(#arr)"/>
  <!-- Loopback edge (guarded) -->
  <path d="M 360 100 Q 410 100 410 50 Q 410 20 310 20 Q 110 20 110 65" fill="none" stroke="#484f58" stroke-width="1.5" stroke-dasharray="4 3"/>
  <!-- Animated firing pulse -->
  <circle r="6" fill="#f0883e">
    <animate attributeName="opacity" values="0;1;1;1;0" dur="4s" repeatCount="indefinite"/>
    <animateMotion dur="4s" repeatCount="indefinite">
      <mpath href="#loopPath1"/>
    </animateMotion>
  </circle>
  <path id="loopPath1" d="M 360 100 Q 410 100 410 50 Q 410 20 310 20 Q 110 20 110 65" fill="none" stroke="none"/>
  <!-- State label -->
  <text x="110" y="155" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="10" fill="#3fb950">
    <animate attributeName="opacity" values="0;0;0;1;1" dur="4s" repeatCount="indefinite"/>
    idle → running
  </text>
  <!-- Pass counter -->
  <text x="310" y="155" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="10" fill="#8b949e">
    <animate attributeName="fill" values="#8b949e;#8b949e;#f0883e;#8b949e" dur="4s" repeatCount="indefinite"/>
    pass 2 of 5
  </text>
</svg>
</div>

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

<div style="max-width:560px;margin:2rem auto;background:#161b22;border-radius:12px;padding:1.5rem;">
<div style="font-family:SFMono-Regular,Menlo,monospace;font-size:11px;color:#8b949e;text-transform:uppercase;letter-spacing:0.5px;margin-bottom:1rem;">Pass 3 reads what passes 1–2 learned</div>
<svg viewBox="0 0 520 200" xmlns="http://www.w3.org/2000/svg" role="img" aria-label="Animated: log grows, wake digest briefs next pass">
  <defs>
    <marker id="arr2" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#58a6ff"/></marker>
    <marker id="arr2g" markerWidth="8" markerHeight="6" refX="7" refY="3" orient="auto"><polygon points="0 0, 8 3, 0 6" fill="#3fb950"/></marker>
  </defs>
  <!-- Memory log -->
  <rect x="20" y="20" width="180" height="160" rx="8" fill="#0d1117" stroke="#30363d" stroke-width="1.5"/>
  <text x="40" y="45" font-family="SFMono-Regular,Menlo,monospace" font-size="10" fill="#8b949e">LOG.txt</text>
  <!-- Log entries appearing over time -->
  <text x="35" y="70" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#6e7681">14:23  pass 1 started</text>
  <text x="35" y="85" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#6e7681">14:23  metric: 41</text>
  <text x="35" y="100" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#8b949e">14:24  tried A, failed</text>
  <text x="35" y="115" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#8b949e">14:31  pass 2 started</text>
  <text x="35" y="130" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#8b949e">14:31  metric: 38</text>
  <text x="35" y="145" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#e6edf3">
    <animate attributeName="opacity" values="0;0;0;0.9;0.9" dur="5s" repeatCount="indefinite"/>
    14:42  pass 3 started
  </text>
  <text x="35" y="160" font-family="SFMono-Regular,Menlo,monospace" font-size="8" fill="#3fb950">
    <animate attributeName="opacity" values="0;0;0;0;0.9" dur="5s" repeatCount="indefinite"/>
    14:42  read wake digest
  </text>
  <!-- Arrow to wake digest -->
  <path d="M 205 100 L 245 100" stroke="#58a6ff" stroke-width="1.5" stroke-dasharray="4 2" marker-end="url(#arr2)">
    <animate attributeName="opacity" values="0;0;1;1;1" dur="5s" repeatCount="indefinite"/>
  </path>
  <!-- Wake digest (budgeted view) -->
  <rect x="255" y="55" width="120" height="90" rx="6" fill="#0d1117" stroke="#58a6ff" stroke-width="1.5">
    <animate attributeName="stroke-width" values="1.5;2.5;1.5" dur="5s" repeatCount="indefinite" begin="2s"/>
  </rect>
  <text x="275" y="78" font-family="SFMono-Regular,Menlo,monospace" font-size="9" fill="#58a6ff">WAKE.md</text>
  <text x="275" y="93" font-family="SFMono-Regular,Menlo,monospace" font-size="7" fill="#6e7681">(last 40 lines)</text>
  <text x="275" y="112" font-family="-apple-system,sans-serif" font-size="8" fill="#8b949e">• A failed</text>
  <text x="275" y="125" font-family="-apple-system,sans-serif" font-size="8" fill="#8b949e">• metric 41→38</text>
  <text x="275" y="138" font-family="-apple-system,sans-serif" font-size="8" fill="#3fb950">• try B next</text>
  <!-- Arrow to session -->
  <path d="M 380 100 L 420 100" stroke="#3fb950" stroke-width="1.5" marker-end="url(#arr2g)">
    <animate attributeName="opacity" values="0;0;0;1;1" dur="5s" repeatCount="indefinite"/>
  </path>
  <!-- Session node -->
  <rect x="430" y="65" width="70" height="70" rx="6" fill="#21262d" stroke="#484f58" stroke-width="1.5">
    <animate attributeName="stroke" values="#484f58;#3fb950;#484f58" dur="5s" repeatCount="indefinite" begin="3s"/>
  </rect>
  <text x="465" y="95" text-anchor="middle" font-family="SFMono-Regular,Menlo,monospace" font-size="9" fill="#8b949e">PASS 3</text>
  <text x="465" y="112" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="9" fill="#3fb950">
    <animate attributeName="opacity" values="0;0;0;0;1" dur="5s" repeatCount="indefinite"/>
    knows history
  </text>
  <!-- Caption -->
  <text x="260" y="188" text-anchor="middle" font-family="-apple-system,sans-serif" font-size="10" fill="#6e7681">Session 3 starts where session 2 left off.</text>
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

GraphCode can't see inside a running agent. Presence, what a session is currently doing,
and token usage are read from per-session labels the backend's own hooks can set; without
hooks the UI says "not reported" rather than showing a zero nobody measured. That third
label is what puts `editing GraphStore.swift` or `running make check` under a card's
RUNNING pill — the tool call the agent is making, reported by its own `PreToolUse` hook,
never scraped from the terminal. A card with nothing reported falls back to the goal or
prompt the loop was handed. The same honesty rule shapes the metric design: numbers a
decision rests on come from running the command, not from the loop's account of itself.

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

**Want help designing your graph?** I offer setup and graph engineering for teams
adopting GraphCode — [reach out](mailto:sravani2201@outlook.com).
