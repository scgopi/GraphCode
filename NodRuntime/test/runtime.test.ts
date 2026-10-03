import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readBrief, type NodBrief } from "../src/brief";
import { EventLog } from "../src/eventLog";
import { PresenceReporter } from "../src/presence";
import type { NodEventRecord } from "../src/protocol";
import { NodRuntime, type LoopType } from "../src/runtime";
import { defaultSettings, type NodSettings } from "../src/settings";
import { FakeEngine, tick, until } from "./fakeEngine";

interface Setup {
  loopType?: LoopType;
  inherit?: NodBrief;
  resume?: string;
  goal?: string;
  settings?: Partial<NodSettings>;
  unattended?: boolean;
}

function setup(engine: FakeEngine, options: Setup = {}) {
  const cwd = mkdtempSync(join(tmpdir(), "nod-rt-"));
  const stateDir = join(cwd, ".state");
  mkdirSync(stateDir);
  const support = join(cwd, ".support");
  const log = new EventLog(join(stateDir, "events.jsonl"));
  const records: NodEventRecord[] = [];
  log.onRecord((r) => records.push(r));
  const labels: string[][] = [];
  const presence = new PresenceReporter("graphcode-node-1", async (args) => void labels.push(args), support);
  const runtime = new NodRuntime({
    nodeID: "node-1",
    cwd,
    stateDir,
    loopType: options.loopType ?? "main",
    settings: { ...defaultSettings, ...options.settings },
    engine,
    log,
    presence,
    goal: options.goal,
    unattended: options.unattended,
    inherit: options.inherit,
    resume: options.resume,
  });
  const types = () => records.map((r) => r.type);
  return { runtime, records, labels, cwd, stateDir, support, types, presence };
}

describe("NodRuntime", () => {
  test("starts with sessionStarted, writes conversation.json and the session-id pointer", async () => {
    const engine = new FakeEngine();
    const { runtime, records, stateDir, support, presence } = setup(engine);
    await runtime.start();
    expect(records[0]).toMatchObject({ type: "sessionStarted", engine: "claude", model: "fake-model", conversationID: "conv-1", resumed: false });
    expect(JSON.parse(readFileSync(join(stateDir, "conversation.json"), "utf8"))).toEqual({ engine: "claude", model: "fake-model", conversationID: "conv-1" });
    expect(readFileSync(join(support, "sessions", "node-1.id"), "utf8")).toBe("conv-1");
    expect(readFileSync(join(support, "sessions", "node-1.history"), "utf8")).toMatch(/^\d+ conv-1 \S+\n$/);
    await presence.flush();
  });

  test("a turn becomes turnStarted, streamed text, tool cards, usage and turnEnded", async () => {
    const engine = new FakeEngine([
      async (cb) => {
        cb.text("m1", "Found ", false);
        cb.toolCall("c1", "Grep", { pattern: "UsageGate" });
        cb.toolResult("c1", "ok", "6 hits in 4 files", undefined, 400);
        cb.text("m1", "it.", false);
        cb.text("m1", "", true);
        cb.usage({ inputTokens: 1200, outputTokens: 300, costUSD: 0.01, contextUsed: 0.1 });
        return { lastMessage: "Found it.\nDetails follow." };
      },
    ]);
    const { runtime, records, labels, types, presence } = setup(engine);
    await runtime.start("Fix /export");
    await runtime.whenIdle();
    await presence.flush();
    expect(types()).toEqual([
      "sessionStarted", "userMessage", "turnStarted", "assistantText", "toolCall", "activity",
      "toolResult", "assistantText", "assistantText", "usage", "turnEnded",
    ]);
    expect(records.find((r) => r.type === "toolCall")).toMatchObject({ turn: 1, callID: "c1", tool: "Grep", title: 'Search "UsageGate"' });
    expect(records.find((r) => r.type === "activity")).toMatchObject({ line: "Searching for UsageGate · turn 1" });
    expect(records.at(-1)).toMatchObject({ type: "turnEnded", turn: 1, filesChanged: 0, summary: "Found it." });
    expect(labels).toContainEqual(["set", "graphcode-node-1", "presence=busy", "activity=searching_20for_20UsageGate"]);
    expect(labels).toContainEqual(["set", "graphcode-node-1", "usage=input.1200_output.300"]);
    expect(labels.at(-1)).toEqual(["set", "graphcode-node-1", "presence=idle", "activity="]);
  });

  test("a queued message waits for the turn to end; each runs as its own turn", async () => {
    let release!: () => void;
    const engine = new FakeEngine([async () => (await new Promise<void>((r) => (release = r)), { lastMessage: "one" })]);
    const { runtime, records } = setup(engine);
    await runtime.start("first");
    await until(() => runtime.isBusy);
    runtime.send("also log when a request is blocked", "queue");
    expect(engine.turns).toEqual(["first"]);
    release();
    await runtime.whenIdle();
    expect(engine.turns).toEqual(["first", "also log when a request is blocked"]);
    expect(records.filter((r) => r.type === "turnStarted").map((r) => r.type === "turnStarted" && r.origin)).toEqual(["user", "queue"]);
  });

  test("a steer lands at the next tool boundary without starting a turn", async () => {
    let steered: string | undefined;
    let atBoundary!: () => void;
    const engine = new FakeEngine([
      async (cb) => {
        await new Promise<void>((r) => (atBoundary = r));
        steered = cb.takeSteer();
        return { lastMessage: "done" };
      },
    ]);
    const { runtime, records } = setup(engine);
    await runtime.start("work");
    await until(() => runtime.isBusy);
    runtime.send("use the fixture clock, not Date()", "steer");
    atBoundary();
    await runtime.whenIdle();
    expect(steered).toBe("The human steered while you worked: use the fixture clock, not Date()");
    expect(engine.turns.length).toBe(1);
    expect(records.find((r) => r.type === "userMessage" && r.delivery === "steer")).toBeDefined();
  });

  test("a steer that never met a tool boundary runs next, as a steer turn", async () => {
    let release!: () => void;
    const engine = new FakeEngine([async () => (await new Promise<void>((r) => (release = r)), { lastMessage: "" })]);
    const { runtime, records } = setup(engine);
    await runtime.start("work");
    await until(() => runtime.isBusy);
    runtime.send("and cover the monthly reset too", "steer");
    release();
    await runtime.whenIdle();
    expect(engine.turns).toEqual(["work", "and cover the monthly reset too"]);
    expect(records.filter((r) => r.type === "turnStarted").at(-1)).toMatchObject({ origin: "steer" });
  });

  test("an in-worktree edit is staged and held until reviewed; the tool runs only when all accepted", async () => {
    const engine = new FakeEngine();
    const { runtime, records, cwd, labels, presence } = setup(engine, { settings: { editsInWorktree: "reviewHunks" } });
    const file = join(cwd, "Routes.swift");
    writeFileSync(file, "a\nb\nc\n");
    let authorization: unknown;
    engine.queueTurn(async (cb) => {
      authorization = await cb.authorize({ intent: { kind: "edit", path: file }, edit: { path: file, after: "a\nB\nc\n" } });
      return { lastMessage: "edited" };
    });
    await runtime.start("edit it");
    await until(() => records.some((r) => r.type === "hunkStaged"));
    await presence.flush();
    expect(labels.at(-1)).toEqual(["set", "graphcode-node-1", "presence=awaitingInput", "activity=waiting_20for_20review"]);
    await runtime.handle({ type: "resolveHunk", hunkID: "h1", decision: "accept" });
    await runtime.whenIdle();
    expect(authorization).toEqual({ allow: true });
  });

  test("auto mode allows the edit at once and the turn tally counts it", async () => {
    const engine = new FakeEngine();
    const { runtime, records, cwd } = setup(engine, { settings: { editsInWorktree: "auto" } });
    const file = join(cwd, "Routes.swift");
    writeFileSync(file, "a\nb\nc\n");
    engine.queueTurn(async (cb) => {
      const verdict = await cb.authorize({ intent: { kind: "edit", path: file }, edit: { path: file, after: "a\nB\nc\nd\n" } });
      expect(verdict).toEqual({ allow: true });
      return { lastMessage: "edited" };
    });
    await runtime.start("edit it");
    await runtime.whenIdle();
    expect(records.find((r) => r.type === "hunkStaged")).toMatchObject({ autoAccepted: true, added: 2, removed: 1 });
    expect(records.find((r) => r.type === "turnEnded")).toMatchObject({ filesChanged: 1, added: 2, removed: 1 });
  });

  test("a permission ask puts the loop in awaiting input until resolvePermission", async () => {
    const engine = new FakeEngine();
    let verdict: unknown;
    engine.queueTurn(async (cb) => {
      verdict = await cb.authorize({ intent: { kind: "shell", command: "swift package resolve" } });
      return { lastMessage: "" };
    });
    const { runtime, records, labels, presence } = setup(engine);
    await runtime.start("resolve deps");
    await until(() => records.some((r) => r.type === "permissionAsked"));
    await presence.flush();
    expect(labels.at(-1)?.[2]).toBe("presence=awaitingInput");
    await runtime.handle({ type: "resolvePermission", askID: "p1", decision: "allowOnce" });
    await runtime.whenIdle();
    expect(verdict).toEqual({ allow: true });
  });

  test("an unattended loop fails the run with permissionUnavailable instead of waiting", async () => {
    const engine = new FakeEngine();
    let verdict: unknown;
    engine.queueTurn(async (cb) => {
      verdict = await cb.authorize({ intent: { kind: "shell", command: "swift package resolve" } });
      return { lastMessage: "", interrupted: true };
    });
    const { runtime, records } = setup(engine, { loopType: "timed" });
    await runtime.start("nightly deps");
    await runtime.whenIdle();
    expect(verdict).toMatchObject({ allow: false, interrupt: true });
    expect(records.find((r) => r.type === "failure")).toMatchObject({ kind: "permissionUnavailable" });
    expect(records.some((r) => r.type === "permissionAsked")).toBe(false);
  });

  test("the spend cap stops an unattended run mid-turn, and the next run starts from zero", async () => {
    const engine = new FakeEngine();
    engine.queueTurn(async (cb) => {
      cb.usage({ inputTokens: 1, outputTokens: 1, costUSD: 1.5, contextUsed: 0.1 });
      await tick(5);
      cb.usage({ inputTokens: 2, outputTokens: 2, costUSD: 2.1, contextUsed: 0.1 });
      await new Promise(() => {}); // only the interrupt ends this turn
      return { lastMessage: "" };
    });
    engine.queueTurn(async (cb) => {
      cb.usage({ inputTokens: 3, outputTokens: 3, costUSD: 3.0, contextUsed: 0.1 });
      return { lastMessage: "fine" };
    });
    const { runtime, records } = setup(engine, { loopType: "timed", settings: { spendCapUSD: 2 } });
    await runtime.start("run 1");
    await runtime.whenIdle();
    expect(engine.interrupted).toBe(1);
    expect(records.filter((r) => r.type === "failure")).toEqual([
      expect.objectContaining({ kind: "spendCap", message: "Hit its $2.00 cap this run ($2.10 spent). Stopped mid-turn 1." }),
    ]);
    runtime.send("run 2", "queue");
    await runtime.whenIdle();
    expect(records.filter((r) => r.type === "failure").length).toBe(1);
  });

  test("an attended loop has no spend cap", async () => {
    const engine = new FakeEngine([async (cb) => (cb.usage({ inputTokens: 1, outputTokens: 1, costUSD: 50, contextUsed: 0 }), { lastMessage: "" })]);
    const { runtime, records } = setup(engine, { settings: { spendCapUSD: 2 } });
    await runtime.start("go");
    await runtime.whenIdle();
    expect(records.some((r) => r.type === "failure")).toBe(false);
  });

  test("an engine failure becomes a failure event and the loop goes idle", async () => {
    const engine = new FakeEngine([() => ({ lastMessage: "", failure: { kind: "signInExpired", message: "Claude sign-in expired." } })]);
    const { runtime, records, labels, presence } = setup(engine, { goal: "it works" });
    await runtime.start("go");
    await runtime.whenIdle();
    await presence.flush();
    expect(records.find((r) => r.type === "failure")).toMatchObject({ kind: "signInExpired" });
    expect(records.some((r) => r.type === "goalCheck")).toBe(false);
    expect(labels.at(-1)?.[2]).toBe("presence=idle");
  });

  test("a thrown engine error is an engineError failure, not a crash", async () => {
    const engine = new FakeEngine([() => { throw new Error("socket hang up"); }]);
    const { runtime, records } = setup(engine);
    await runtime.start("go");
    await runtime.whenIdle();
    expect(records.find((r) => r.type === "failure")).toMatchObject({ kind: "engineError", message: "socket hang up" });
    expect(records.at(-1)?.type).toBe("turnEnded");
  });

  test("stop interrupts the turn, rejects pending hunks, denies open asks and clears the queue", async () => {
    const engine = new FakeEngine();
    const { runtime, records, cwd } = setup(engine, { goal: "it works", settings: { editsInWorktree: "reviewHunks" } });
    const file = join(cwd, "A.swift");
    writeFileSync(file, "x\n");
    engine.queueTurn(async (cb) => {
      await Promise.all([
        cb.authorize({ intent: { kind: "edit", path: file }, edit: { path: file, after: "y\n" } }),
        cb.authorize({ intent: { kind: "shell", command: "make" } }),
      ]);
      return { lastMessage: "" };
    });
    await runtime.start("go");
    await until(() => records.some((r) => r.type === "permissionAsked") && records.some((r) => r.type === "hunkStaged"));
    runtime.send("queued", "queue");
    await runtime.handle({ type: "stop" });
    await runtime.whenIdle();
    expect(engine.interrupted).toBe(1);
    expect(records.find((r) => r.type === "hunkResolved")).toMatchObject({ decision: "reject", note: "the turn was stopped" });
    expect(records.find((r) => r.type === "permissionResolved")).toMatchObject({ decision: "deny" });
    expect(engine.turns).toEqual(["go"]);
    expect(records.some((r) => r.type === "goalCheck")).toBe(false);
    expect(readFileSync(file, "utf8")).toBe("x\n");
  });

  test("setModel and compact are passed to the engine; runPlan here queues the plan", async () => {
    const engine = new FakeEngine();
    const { runtime, records, stateDir } = setup(engine);
    await runtime.start();
    await runtime.handle({ type: "setModel", model: "opus" });
    expect(engine.model).toBe("opus");
    expect(JSON.parse(readFileSync(join(stateDir, "conversation.json"), "utf8")).model).toBe("opus");
    await runtime.handle({ type: "compact" });
    expect(records.some((r) => r.type === "compacted")).toBe(false); // nothing to compact before turn 1
    await runtime.handle({
      type: "runPlan",
      planID: "p1",
      mode: "here",
      steps: [{ id: "1", text: "Move /export behind UsageGate", files: [], editedByHuman: false }, { id: "2", text: "Return 402", files: [], editedByHuman: true }],
    });
    await runtime.whenIdle();
    expect(engine.turns[0]).toContain("1. Move /export behind UsageGate\n2. Return 402 (edited by the human");
    await runtime.handle({ type: "compact" });
    expect(records.at(-1)).toMatchObject({ type: "compacted", fromTurn: 1, throughTurn: 1 });
    expect(runtime.handle({ type: "runPlan", planID: "p", mode: "composite", steps: [] })).rejects.toThrow("graph layer");
    expect(runtime.handle({ type: "fork", messageID: "m" })).rejects.toThrow("not supported");
  });

  test("context at 95% compacts after the turn", async () => {
    const engine = new FakeEngine([async (cb) => (cb.usage({ inputTokens: 1, outputTokens: 1, contextUsed: 0.96 }), { lastMessage: "" })]);
    const { runtime, records } = setup(engine);
    await runtime.start("go");
    await runtime.whenIdle();
    expect(records.at(-1)).toMatchObject({ type: "compacted", throughTurn: 1 });
  });
});

describe("inherited briefs", () => {
  const brief: NodBrief = {
    kind: "fork",
    fromNodeID: "9B3408F9-9B16-447F-A439-FC2AA8C02D06",
    text: "Try the other approach: check the cap inside the handler.",
    attachments: [{ kind: "loopTranscript", reference: "9B3408F9-9B16-447F-A439-FC2AA8C02D06" }],
    fork: { conversationID: "parent-conv", messageID: "m7" },
  };

  test("a fresh start sends the brief as turn 1, a handoff from its loop, forking the parent conversation", async () => {
    const engine = new FakeEngine();
    const { runtime, records } = setup(engine, { inherit: brief, goal: "it works" });
    await runtime.start();
    await until(() => engine.turns.length > 0);
    expect(engine.started?.forkFrom).toBe("parent-conv");
    expect(records.find((r) => r.type === "userMessage")).toMatchObject({ text: brief.text, fromNodeID: brief.fromNodeID, attachments: brief.attachments });
    expect(records.find((r) => r.type === "turnStarted")).toMatchObject({ origin: "handoff" });
    expect(engine.turns[0]).toBe(brief.text);
  });

  test("a resume never replays the brief", async () => {
    const engine = new FakeEngine();
    const { runtime, records } = setup(engine, { inherit: brief, resume: "own-conv" });
    await runtime.start();
    expect(engine.started?.forkFrom).toBeUndefined();
    expect(records.some((r) => r.type === "userMessage")).toBe(false);
  });

  test("readBrief takes the file's fields and drops malformed attachments", async () => {
    const path = join(mkdtempSync(join(tmpdir(), "nod-brief-")), "brief.json");
    writeFileSync(path, JSON.stringify({ v: 1, kind: "compositeChild", text: "Do step 3", attachments: [{ kind: "file", reference: "A.swift" }, { bad: 1 }] }));
    expect(readBrief(path)).toEqual({ kind: "compositeChild", fromNodeID: undefined, text: "Do step 3", attachments: [{ kind: "file", reference: "A.swift" }], fork: undefined });
  });
});

describe("goal loops", () => {
  const notMet = '{"clauses":[{"index":0,"met":true,"evidence":"4 / 4 routes"},{"index":1,"met":false,"evidence":"1 failure"}]}';
  const met = '{"clauses":[{"index":0,"met":true},{"index":1,"met":true,"evidence":"31 tests pass"}]}';
  const goal = "Done when every paid route enforces the cap and swift test passes";

  test("each stop is checked; not met sends the agent back with the unmet clauses, met ends it", async () => {
    const engine = new FakeEngine([() => ({ lastMessage: "Done, I think." }), () => ({ lastMessage: "Fixed the failure." })], [() => notMet, () => met]);
    const { runtime, records } = setup(engine, { loopType: "goal", goal });
    await runtime.start();
    await runtime.whenIdle();
    expect(engine.turns[0]).toBe(goal);
    expect(engine.turns[1]).toContain("- swift test passes (1 failure)");
    const checks = records.filter((r) => r.type === "goalCheck");
    expect(checks.map((r) => r.type === "goalCheck" && [r.turn, r.met])).toEqual([[1, false], [2, true]]);
    expect(records.filter((r) => r.type === "turnStarted").map((r) => r.type === "turnStarted" && r.origin)).toEqual(["user", "goalCheck"]);
    expect(engine.asks[0]!.model).toBe("haiku");
  });

  test("the goal is not checked while more messages are queued", async () => {
    let release!: () => void;
    const engine = new FakeEngine([async () => (await new Promise<void>((r) => (release = r)), { lastMessage: "" }), () => ({ lastMessage: "" })], [() => met]);
    const { runtime, records } = setup(engine, { loopType: "goal", goal });
    await runtime.start("first");
    await until(() => runtime.isBusy);
    runtime.send("second", "queue");
    release();
    await runtime.whenIdle();
    expect(records.filter((r) => r.type === "goalCheck").map((r) => r.type === "goalCheck" && r.turn)).toEqual([2]);
  });

  test("markGoalDone while idle records a met check without the judge", async () => {
    const engine = new FakeEngine([() => ({ lastMessage: "" })], [() => notMet]);
    const { runtime, records } = setup(engine, { loopType: "goal", goal, });
    await runtime.start("go");
    await until(() => records.some((r) => r.type === "goalCheck"));
    // Not met queued a continuation; the default script ends it, and the judge has no more answers.
    await runtime.whenIdle();
    await runtime.handle({ type: "markGoalDone" });
    expect(records.filter((r) => r.type === "goalCheck").at(-1)).toMatchObject({ met: true });
  });

  test("continuations stop after the limit and wait for a human", async () => {
    const engine = new FakeEngine([], Array.from({ length: 10 }, () => () => notMet));
    const cwd = mkdtempSync(join(tmpdir(), "nod-rt-"));
    const log = new EventLog(join(cwd, "events.jsonl"));
    const records: NodEventRecord[] = [];
    log.onRecord((r) => records.push(r));
    const runtime = new NodRuntime({
      nodeID: "n", cwd, stateDir: cwd, loopType: "goal", settings: defaultSettings, engine, log,
      presence: new PresenceReporter(undefined), goal, maxGoalContinuations: 2,
    });
    await runtime.start("go");
    await runtime.whenIdle();
    expect(engine.turns.length).toBe(3);
    expect(records.at(-1)).toMatchObject({ type: "activity", line: "Goal not met after 2 checks · waiting for you" });
  });
});
