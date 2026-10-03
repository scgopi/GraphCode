import { randomUUID } from "node:crypto";
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import type { Authorization, Engine, EngineFailure, ToolRequest, TurnCallbacks, TurnResult, UsageReport } from "./engine";
import type { EventLog } from "./eventLog";
import { GoalEvaluator } from "./goal";
import { HunkStager, type StagedHunk } from "./hunks";
import {
  createGraphcodeTools,
  daemonClient,
  DaemonError,
  sendDraft,
  type GraphDaemon,
  type GraphcodeToolContext,
  type MessagePolicy,
} from "./mcp";
import type { ProjectMcpServer } from "./mcpServers";
import { PermissionGate } from "./permissions";
import type { PresenceReporter } from "./presence";
import type { NodAttachment, NodCommand, NodDelivery, NodTurnOrigin } from "./protocol";
import type { NodBrief } from "./brief";
import type { NodSettings } from "./settings";
import { describeTool } from "./tools";

export type LoopType = "main" | "goal" | "timed" | "turn" | "composite";

export interface RuntimeOptions {
  nodeID: string;
  cwd: string;
  stateDir: string;
  loopType: LoopType;
  settings: NodSettings;
  engine: Engine;
  log: EventLog;
  presence: PresenceReporter;
  model?: string;
  goal?: string;
  briefing?: string;
  resume?: string;
  /** `--inherit`: sent as turn 1 on a fresh start, never on a resume. */
  inherit?: NodBrief;
  /** Timed loops and composite children: nobody is there to answer an ask. */
  unattended?: boolean;
  /** Consecutive "not yet" goal checks before Nod stops and waits for a human. */
  maxGoalContinuations?: number;
  /** `$NOD_PROJECT_PATH`: the graph the graphcode MCP server reads. */
  projectPath?: string;
  /** graphcoded's socket; a client on the default socket when absent. */
  daemon?: GraphDaemon;
  /** Read per call, so Settings › Agents › Nod applies without a restart. */
  messagesOtherLoops?: () => MessagePolicy;
  /** The project's `.mcp.json` servers, already without `disabledMCPServers`. */
  mcpServers?: Record<string, ProjectMcpServer>;
}

interface Pending {
  text: string;
  origin: NodTurnOrigin;
  attachments: NodAttachment[];
}

const CONTEXT_COMPACT_AT = 0.95;

/**
 * One Nod session: turns run one at a time off a queue, every engine report becomes an
 * event-log record, and the goal is checked each time the agent stops.
 */
export class NodRuntime {
  readonly gate: PermissionGate;
  readonly stager: HunkStager;
  readonly goal?: GoalEvaluator;
  private queue: Pending[] = [];
  private steerBuffer: string[] = [];
  private turn = 0;
  private running?: Promise<void>;
  private busy = false;
  private stopRequested = false;
  private compactRequested = false;
  private runFailed = false;
  private goalContinuations = 0;
  /** Set once the goal holds: later turns are follow-up chat, never sent back to the goal. */
  private goalMet = false;
  private toolStarts = new Map<string, { tool: string; at: number }>();
  private recentTools: string[] = [];
  private lastUsage?: UsageReport;
  private runCostBaseline = 0;
  private costSoFar = 0;
  private conversationID = "";
  private model = "";
  private closed = false;
  private idleWaiters: (() => void)[] = [];
  private readonly unattended: boolean;
  private readonly graph: GraphcodeToolContext;
  /** `mailDraft` id → the loop it is addressed to, for `sendDraft`. */
  private drafts = new Map<string, string>();

  constructor(private readonly options: RuntimeOptions) {
    const { log, settings, cwd } = options;
    this.unattended = options.unattended ?? options.loopType === "timed";
    this.gate = new PermissionGate({
      settings,
      worktree: cwd,
      unattended: this.unattended,
      log,
      onAwaiting: (awaiting) => void this.options.presence.presence(awaiting ? "awaitingInput" : "busy"),
    });
    const { projectPath } = options;
    this.graph = {
      nodeID: options.nodeID,
      projectPath: projectPath ?? "",
      daemon: projectPath ? (options.daemon ?? daemonClient()) : noProject,
      messagesOtherLoops: options.messagesOtherLoops ?? (() => settings.messagesOtherLoops),
      emit: (draft) => {
        this.drafts.set(draft.draftID, draft.toNodeID);
        log.append(draft);
      },
    };
    this.stager = new HunkStager(log, cwd);
    this.stager.onLateDecision = (hunk) => this.steer(lateDecisionNote(hunk));
    if (options.goal?.trim()) {
      // Copilot has no fixed cheap model to name; its judge runs on the session's default.
      const evaluatorModel = settings.goalEvaluatorModel ?? (options.engine.kind === "claude" ? "haiku" : "default");
      this.goal = new GoalEvaluator(
        options.goal,
        (prompt, model) => options.engine.ask(prompt, model === "default" ? undefined : model),
        evaluatorModel,
        log,
      );
    }
  }

  get currentTurn(): number {
    return this.turn;
  }

  get isBusy(): boolean {
    return this.busy;
  }

  async start(firstPrompt?: string): Promise<void> {
    const { engine, log, presence, nodeID, cwd } = this.options;
    const systemAppend = this.options.briefing ? `GraphCode briefing for this loop:\n\n${this.options.briefing}` : undefined;
    const inherit = this.options.resume ? undefined : this.options.inherit;
    const session = await engine.start({
      cwd,
      model: this.options.model,
      resume: this.options.resume,
      forkFrom: inherit?.fork?.conversationID,
      systemAppend,
      mcp: { graphcode: createGraphcodeTools(this.graph), servers: this.options.mcpServers ?? {} },
    });
    this.conversationID = session.conversationID;
    this.model = session.model;
    log.append({
      type: "sessionStarted",
      engine: engine.kind,
      model: session.model,
      conversationID: session.conversationID,
      resumed: Boolean(this.options.resume),
    });
    this.writeConversation();
    presence.sessionID(nodeID, session.conversationID, cwd);
    void presence.presence("idle");
    if (inherit) this.send(inherit.text, "queue", inherit.attachments, "handoff", inherit.fromNodeID);
    if (firstPrompt?.trim()) this.send(firstPrompt, "queue", [], "user");
    else if (this.goal && !this.options.resume && !inherit) this.send(this.goal.goal, "queue", [], "user");
  }

  /** Resolves once no turn is running and nothing is queued. */
  whenIdle(): Promise<void> {
    if (!this.busy && this.queue.length === 0) return Promise.resolve();
    return new Promise((resolve) => this.idleWaiters.push(resolve));
  }

  async handle(command: NodCommand): Promise<void> {
    switch (command.type) {
      case "send":
        this.send(command.text, command.delivery, command.attachments);
        return;
      case "stop":
        await this.stop();
        return;
      case "resolveHunk":
        this.stager.resolve(command.hunkID, command.decision, command.note);
        return;
      case "resolvePermission":
        this.gate.resolve(command.askID, command.decision);
        return;
      case "runPlan":
        if (command.mode === "composite") throw new Error("composite plans are run by the graph layer, not the runtime");
        this.send(
          ["Run this plan, step by step:", ...command.steps.map((s, i) => `${i + 1}. ${s.text}${s.editedByHuman ? " (edited by the human — keep it as written)" : ""}`)].join("\n"),
          "queue",
          [],
        );
        return;
      case "fork":
        throw new Error("fork is not supported by this runtime yet");
      case "sendDraft": {
        const toNodeID = this.drafts.get(command.draftID) ?? this.loggedDraftTarget(command.draftID);
        if (!toNodeID) throw new Error(`no mail draft ${command.draftID}`);
        await sendDraft(this.graph, { toNodeID, text: command.text });
        this.drafts.delete(command.draftID);
        return;
      }
      case "compact":
        if (this.busy) this.compactRequested = true;
        else await this.compactNow();
        return;
      case "setModel":
        await this.options.engine.setModel(command.model);
        this.model = command.model;
        this.writeConversation();
        return;
      case "markGoalDone":
        if (!this.goal) throw new Error("this loop has no goal");
        this.goal.markDone();
        if (!this.busy && (await this.goal.check(this.turn, { lastMessage: "", toolResults: [] })).met) this.goalMet = true;
        return;
    }
  }

  /** A user message: queued for the next turn, or steered into this one at a tool boundary. */
  send(text: string, delivery: NodDelivery, attachments: NodAttachment[] = [], origin?: NodTurnOrigin, fromNodeID?: string): void {
    this.options.log.append({ type: "userMessage", id: randomUUID(), text, delivery, attachments, fromNodeID });
    this.goalContinuations = 0;
    if (delivery === "steer" && this.busy) {
      this.steerBuffer.push(text);
      return;
    }
    this.queue.push({ text, attachments, origin: origin ?? (this.busy ? "queue" : "user") });
    this.pump();
  }

  /** A note for the agent at its next tool boundary, without a user-message echo. */
  private steer(text: string): void {
    if (this.busy) this.steerBuffer.push(text);
    else {
      this.queue.push({ text, attachments: [], origin: "steer" });
      this.pump();
    }
  }

  async stop(): Promise<void> {
    this.queue = [];
    this.steerBuffer = [];
    if (!this.busy) return;
    this.stopRequested = true;
    this.stager.rejectPending("the turn was stopped");
    this.gate.denyAll();
    await this.options.engine.interrupt();
  }

  async close(): Promise<void> {
    this.closed = true;
    this.queue = [];
    if (this.busy) await this.stop();
    await this.running;
    await this.options.engine.close();
    await this.options.presence.presence("absent");
  }

  private pump(): void {
    if (this.running || this.closed) return;
    this.running = (async () => {
      while (this.queue.length > 0 && !this.closed) {
        const next = this.queue.shift()!;
        await this.runTurn(next);
      }
      this.running = undefined;
      if (!this.closed) void this.options.presence.presence("idle");
      for (const resolve of this.idleWaiters.splice(0)) resolve();
    })();
  }

  private async runTurn(pending: Pending): Promise<void> {
    const { log, presence, engine } = this.options;
    if (pending.origin !== "goalCheck" && pending.origin !== "steer") {
      this.runCostBaseline = this.costSoFar;
      this.runFailed = false;
    }
    this.turn += 1;
    const turn = this.turn;
    this.busy = true;
    this.stopRequested = false;
    this.recentTools = [];
    log.append({ type: "turnStarted", turn, origin: pending.origin });
    void presence.presence("busy");

    let result: TurnResult;
    try {
      result = await engine.runTurn(pending.text, pending.attachments, this.callbacks(turn));
    } catch (error) {
      result = { lastMessage: "", failure: { kind: "engineError", message: errorMessage(error) } };
    }
    if (result.failure) this.fail(result.failure);

    const tally = this.stager.tally(turn);
    log.append({ type: "turnEnded", turn, ...tally, summary: summaryLine(result.lastMessage) });
    this.stager.closeTurn(turn);
    this.busy = false;

    const leftover = this.steerBuffer.splice(0);
    if (leftover.length > 0) this.queue.unshift({ text: leftover.join("\n\n"), attachments: [], origin: "steer" });

    if (this.compactRequested || (this.lastUsage?.contextUsed ?? 0) >= CONTEXT_COMPACT_AT) {
      this.compactRequested = false;
      await this.compactNow();
    }

    const stoppedEarly = this.stopRequested || result.interrupted || this.runFailed;
    if (this.goal && !this.goalMet && !stoppedEarly && this.queue.length === 0) await this.checkGoal(turn, result.lastMessage);
  }

  private async checkGoal(turn: number, lastMessage: string): Promise<void> {
    const goal = this.goal!;
    void this.options.presence.presence("busy", "checking the goal");
    const verdict = await goal.check(turn, { lastMessage, toolResults: this.recentTools.slice(-20) });
    if (verdict.met) {
      this.goalMet = true;
      return;
    }
    const limit = this.options.maxGoalContinuations ?? 20;
    if (this.goalContinuations >= limit) {
      this.options.log.append({ type: "activity", line: `Goal not met after ${limit} checks · waiting for you` });
      return;
    }
    this.goalContinuations += 1;
    this.queue.push({ text: GoalEvaluator.continuation(verdict), attachments: [], origin: "goalCheck" });
  }

  private async compactNow(): Promise<void> {
    const { engine, log } = this.options;
    const throughTurn = this.turn;
    let compacted = false;
    const callbacks = { ...this.callbacks(this.turn), compacted: () => (compacted = true) };
    const result = await engine.compact(callbacks).catch((error) => ({
      lastMessage: "",
      failure: { kind: "contextFull" as const, message: `Compacting failed: ${errorMessage(error)}` },
    }));
    if (result.failure) this.fail(result.failure);
    if (compacted && throughTurn > 0) log.append({ type: "compacted", fromTurn: 1, throughTurn });
  }

  private callbacks(turn: number): TurnCallbacks {
    const { log, presence } = this.options;
    return {
      text: (messageID, delta, final) => log.append({ type: "assistantText", turn, messageID, delta, final }),
      toolCall: (callID, tool, input) => {
        const { title, activity } = describeTool(tool, input);
        this.toolStarts.set(callID, { tool, at: Date.now() });
        log.append({ type: "toolCall", turn, callID, tool, title });
        log.append({ type: "activity", line: `${capitalize(activity)} · turn ${turn}` });
        void presence.presence("busy", activity);
      },
      toolResult: (callID, status, summary, output, durationMs) => {
        const start = this.toolStarts.get(callID);
        if (status !== "running") this.toolStarts.delete(callID);
        const duration = durationMs ?? (start ? Date.now() - start.at : undefined);
        log.append({ type: "toolResult", callID, status, summary, output: truncate(output), durationMs: duration });
        if (status !== "running" && start) {
          this.recentTools.push(`${start.tool}: ${status} — ${summary}${output ? `\n${truncate(output, 1500)}` : ""}`);
        }
      },
      usage: (report) => this.recordUsage(report),
      compacted: () => log.append({ type: "compacted", fromTurn: 1, throughTurn: turn }),
      authorize: (request) => this.authorize(request, turn),
      takeSteer: () => {
        const text = this.steerBuffer.splice(0).join("\n\n");
        return text ? `The human steered while you worked: ${text}` : undefined;
      },
    };
  }

  private async authorize(request: ToolRequest, turn: number): Promise<Authorization> {
    const verdict = await this.gate.check(request.intent);
    switch (verdict.verdict) {
      case "allow":
        return { allow: true };
      case "deny":
        return { allow: false, message: verdict.message };
      case "fail":
        this.fail({ kind: "permissionUnavailable", message: verdict.message });
        return { allow: false, message: verdict.message, interrupt: true };
      case "stage": {
        const auto = this.options.settings.editsInWorktree === "auto";
        if (!request.edit) {
          // Nothing to diff (a notebook, or an edit whose old text isn't in the file): in
          // review mode it must not land unreviewed.
          return auto
            ? { allow: true }
            : { allow: false, message: "This edit can't be staged for review. Re-read the file and make it as an exact text edit." };
        }
        if (!auto) void this.options.presence.presence("awaitingInput", "waiting for review");
        try {
          const outcome = await this.stager.stageEdit(request.edit.path, request.edit.after, turn, auto);
          if (!auto) void this.options.presence.presence("busy");
          return outcome.allAccepted ? { allow: true } : { allow: false, message: outcome.feedback };
        } catch (error) {
          return { allow: false, message: `This edit could not be staged: ${errorMessage(error)}` };
        }
      }
    }
  }

  private recordUsage(report: UsageReport): void {
    this.lastUsage = report;
    if (report.costUSD !== undefined) this.costSoFar = report.costUSD;
    this.options.log.append({ type: "usage", ...report });
    void this.options.presence.usage(report.inputTokens, report.outputTokens);
    this.enforceSpendCap();
  }

  /**
   * The cap is per run — from the turn a human or timer started, through the goal checks
   * it led to — so a timed loop's next firing starts from zero. Dollars only: Copilot
   * bills premium requests, which its plan caps.
   */
  private enforceSpendCap(): void {
    const cap = this.options.settings.spendCapUSD;
    if (!this.unattended || cap <= 0 || !this.busy || this.runFailed) return;
    const spent = this.costSoFar - this.runCostBaseline;
    if (spent < cap) return;
    this.fail({ kind: "spendCap", message: `Hit its $${cap.toFixed(2)} cap this run ($${spent.toFixed(2)} spent). Stopped mid-turn ${this.turn}.` });
    void this.stop();
  }

  private fail(failure: EngineFailure): void {
    if (this.runFailed && failure.kind !== "signInExpired") return;
    this.runFailed = true;
    this.options.log.append({ type: "failure", kind: failure.kind, message: failure.message });
  }

  /** A draft from before a resume is only in the log. */
  private loggedDraftTarget(draftID: string): string | undefined {
    const path = this.options.log.path;
    if (!existsSync(path)) return undefined;
    for (const line of readFileSync(path, "utf8").split("\n")) {
      if (!line.includes(draftID)) continue;
      const record = JSON.parse(line) as { type?: string; draftID?: string; toNodeID?: string };
      if (record.type === "mailDraft" && record.draftID === draftID) return record.toNodeID;
    }
    return undefined;
  }

  private writeConversation(): void {
    const conversation = { engine: this.options.engine.kind, model: this.model, conversationID: this.conversationID };
    writeFileSync(join(this.options.stateDir, "conversation.json"), JSON.stringify(conversation, null, 2) + "\n");
  }
}

const noProject: GraphDaemon = {
  snapshot: unreachable,
  mailbox: unreachable,
  graphCommand: unreachable,
};

async function unreachable(): Promise<never> {
  throw new DaemonError("This loop was launched without its project path (NOD_PROJECT_PATH), so the graph is out of reach.");
}

function lateDecisionNote(hunk: StagedHunk): string {
  const verb = hunk.state === "rejected" ? "rejected" : "sent back";
  return `The reviewer ${verb} an edit you made to ${hunk.file} and it has been reverted on disk${hunk.note ? `: ${hunk.note}` : "."}`;
}

function summaryLine(text: string): string | undefined {
  const line = text.split("\n").map((l) => l.trim()).find(Boolean);
  if (!line) return undefined;
  return line.length > 140 ? line.slice(0, 139) + "…" : line;
}

function truncate(text: string | undefined, max = 8000): string | undefined {
  if (text === undefined) return undefined;
  return text.length > max ? text.slice(0, max) + `\n… ${text.length - max} more characters` : text;
}

function capitalize(text: string): string {
  return text.charAt(0).toUpperCase() + text.slice(1);
}

function errorMessage(error: unknown): string {
  return error instanceof Error ? error.message : String(error);
}

