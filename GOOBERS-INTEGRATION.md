# GraphCode + Goobers integration roadmap

GraphCode and [Goobers](https://github.com/Agent-Clubhouse/Goobers) are separate
projects with different execution models. This integration does not merge them or make
either project's architecture subordinate to the other:

- **GraphCode** remains the graph authoring, visualization, and monitoring surface.
- **Goobers** owns workflow scheduling, admission, execution, and run history for a
  graph explicitly handed to it.

The integration is experimental, additive, and off by default. A graph that never opts
in must behave exactly as it did before this work.

## What we are trying to make possible

1. Draw a graph in GraphCode and run the whole graph as one Goobers workflow.
2. Monitor the Goobers run from the same graph rather than switching mental models.
3. Let Goobers schedules and webhooks become explicit graph entry points.
4. Let a predefined Goobers workflow trigger an ordinary GraphCode session loop without
   converting that graph to Goobers execution.
5. Later, point GraphCode at a hosted Goobers instance so work continues when the Mac is
   asleep or offline, including execution on MDB or another managed runner.

## Execution boundary

A graph has one execution mode:

| Mode | Orchestrator | Node process |
|---|---|---|
| `graphcode` | `graphcoded` fires edges and manages recurrence | One live, attachable zmx session per node |
| `goobers` | Goobers runs the exported state machine | No GraphCode zmx session; a node is a Goobers task |

There is deliberately no per-node hybrid mode yet. Two orchestrators must never believe
they own the same edge. Switching a graph to Goobers stops its GraphCode sessions and
disarms its local pollers; switching back stops the graph-owned Goobers daemon and
restores the ordinary unattended sessions.

This boundary is expected to evolve after the integration has been used enough to show
which hybrid forms are actually useful. It is a safety constraint for the experiment,
not a claim that mixed graphs can never work.

## Feature gates

The settings file has two independent, off-by-default switches:

| Setting | Effect |
|---|---|
| `goobersEnabled` | Allows a graph to opt into Goobers execution |
| `goobersTriggersEnabled` | Allows Goobers schedules and webhooks; effective only while `goobersEnabled` is also on |

Turning on the first setting converts nothing. A graph must explicitly choose Goobers
mode. Turning off trigger support keeps the graph's trigger definitions but reconciles
the running config back to manual-only execution.

GraphCode does not add its own webhook server. Goobers owns webhook ingestion,
signature validation, deduplication, and trigger admission.

## Local instance layout

Each opted-in graph gets a private, persistent Goobers instance:

```text
~/.graphcode/goobers/<graph-uuid>/
├── instance.yaml
├── config/
├── snapshots/<snapshot-uuid>/
├── graphcode-runs/<run-id>.json
├── scheduler/api.address
└── secrets/webhook-secret
```

Named GraphCode workspaces use their own support directory, so their Goobers instances
are isolated in the same way as their graphs and zmx sessions.

The graph UUID is the directory identity. Project names and paths can change; the graph
identity does not. Deleting the graph stops its private daemon and removes this
directory. Forgetting or closing a project does neither.

Every dispatch writes an immutable snapshot before it starts a run. The run ID is
recorded against that snapshot so later diagnostics can answer which graph definition
actually ran.

## Export contract

The exporter targets Goobers DSL 2.0:

| GraphCode | Goobers |
|---|---|
| Graph | Workflow |
| Node | Agentic task + Goober role |
| Unconditional handoff | `next` |
| Conditional handoff | Synthesized automated gate |
| Count-only cycle guard | `maxRepasses` |
| Read-only node | `workspace: repo-readonly` |
| Copilot CLI backend | `harness: copilot` |
| Claude Code backend | `harness: claude-code` |

`model: auto` is emitted rather than pinning a model name. Goobers validates model names
against the selected harness's current catalogue, while GraphCode's tiers are stable
intent rather than catalogue identifiers.

There is no lossy export mode. The exporter refuses constructs whose behavior it cannot
preserve:

- Codex and OpenCode nodes, until Goobers has matching harnesses.
- Message and spawn edges.
- Composite nodes and sketches.
- Time-based nodes: their cadence re-enters a live session, while a Goobers schedule
  starts a new workflow run.
- Fan-out or multiple graph roots until a `parallels[]` block and join can be derived.
- Unguarded cycles.
- Adaptive cycle guards using `until` or plateau detection, because DSL 2.0 would retain
  only their count and silently discard an early-stop rule.

Generated trees must pass:

```sh
goobers validate --source-tree <export>
```

Runnable graph-owned instances must also pass:

```sh
goobers validate <instance>
```

## Dispatch and daemon lifecycle

For local execution, GraphCode:

1. Resolves the project's GitHub origin and a branch visible on `origin`.
2. Exports the current graph into its private instance and immutable snapshot.
3. Starts `goobers up` on an ephemeral loopback port.
4. Discovers the selected port through `scheduler/api.address`.
5. Calls `POST /api/v1/triggers` with a stable delivery ID.
6. Persists the returned run ID on the graph.

An unpushed local branch cannot be the base of a fresh Goobers clone. GraphCode uses the
current branch only when a matching `origin/<branch>` exists; otherwise it uses the
remote default branch. Sending local patches to hosted execution is a separate future
feature.

Config reload is asynchronous in Goobers. The current prototype restarts the graph-owned
daemon at an explicit synchronization boundary so a trigger cannot race the previous
definition. A future revision may replace that restart with a generation-aware reload
acknowledgement.

## Monitoring

While a GraphCode client is attached, the existing 15-second observation sweep reads:

- `GET /api/v1/runs`
- the latest run matching the graph's gaggle and workflow

GraphCode adopts runs it did not start. That is how scheduled and webhook-created runs
appear on the graph.

The current stage maps back through the exporter's stable task names:

- current stage → `running`
- a stage the run advanced past → `succeeded`
- completed run → all workflow nodes `succeeded`
- failed or aborted run → active node `failed`
- escalated run → active node `awaitingInput`

This is the first monitoring slice. Richer monitoring should consume run detail, stage
attempts, events, transcripts, and the resumable `/api/v1/events` stream rather than
persisting a second copy of Goobers history in the graph.

## Triggers

A Goobers graph can persist:

- schedule expressions, including cron and `@every`
- GitHub webhook event names

Updating triggers synchronizes the private instance immediately; a schedule does not
require a manual run to become armed. Webhook-enabled instances receive a generated
mode-0600 secret and bind only to loopback.

The remaining webhook work is operational rather than representational:

- Expose the loopback listener through an explicit tunnel or hosted endpoint.
- Surface the listener address without scraping daemon logs.
- Provide a safe way to configure the matching GitHub webhook secret.
- Fix the daemon synchronization/CLI acknowledgement path that exceeded its bounded
  command timeout during the initial webhook smoke test.

## Poking ordinary GraphCode sessions

Some graphs should stay session-backed but still react to Goobers triggers. The planned
bridge is a predefined Goobers workflow whose task calls the GraphCode daemon or CLI to
send a message to a named project and node.

That workflow does **not** own the GraphCode graph:

- GraphCode still owns its sessions, edges, cycle guards, and recurrence.
- Goobers owns only the external trigger and one delivery attempt.
- The delivery must be idempotent and attributable to its Goobers run.
- A missing or busy session must become a visible blocked/failed delivery, never a
  success-shaped no-op.

This is the intended replacement for adding a second webhook listener to GraphCode.

## Hosted and MDB execution

Local mode proves the contract, but it does not continue when the laptop is closed. The
hosted phase requires:

1. A long-lived Goobers instance reachable through an authenticated API.
2. A way to publish immutable GraphCode-generated config snapshots to it.
3. Remote trigger, cancellation, health, run, event, transcript, and artifact clients.
4. A credential model that never copies GitHub tokens or Microsoft feed credentials
   into a graph or portable repository.
5. Runner placement describing the capabilities a workflow needs.

GraphCode should not grow a private MDB provisioner if Goobers already has, or plans to
have, a runner/deployment seam for shared machines. The two projects' roadmaps must be
evaluated independently. If Goobers cannot provision an MDB, a separate deployment
stage may provision and supervise `goobers up` there; GraphCode should still speak the
same hosted API rather than learning the machine's lifecycle.

## Staged delivery

| Stage | Status | Scope |
|---|---|---|
| Export fidelity | Done | DSL 2.0 exporter, validation oracle, refusal diagnostics |
| Discovery | Done | Experimental settings, loopback address discovery, health and run client |
| Local execution | Done | Per-graph instance, snapshots, daemon start, trigger dispatch, no zmx sessions |
| Monitoring | Done | Latest run adoption and node-state projection, including scheduled runs |
| Schedules and webhooks | Partial | Schedule path works end to end; webhook listener exists, operational synchronization remains |
| Session poke workflow | Planned | Goobers-triggered delivery into an ordinary GraphCode loop |
| Translation phase 2 | Planned | Fan-out to `parallels[]`, join detection, broader DSL coverage |
| Hosted/MDB | Planned | Authenticated remote instance and runner placement |

## Acceptance rules

Every stage must preserve these invariants:

- Both experimental switches default off.
- Existing graph files decode as GraphCode-managed.
- A GraphCode-managed graph follows the existing session path without new branching at
  its call sites.
- A Goobers-managed graph never starts a node zmx session or fires an edge locally.
- No token or webhook secret is committed to a project repository or exported graph.
- Every emitted config validates with the Goobers binary.
- A real smoke workflow, not only a fixture, must pass before a stage is called done.
- Graph deletion removes only that graph's Goobers instance.
- Remote support must fail closed until authentication and trust are explicit.
