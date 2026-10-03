import type { NodAttachment, NodEngineKind, NodFailureKind, NodToolStatus } from "./protocol";
import type { McpMount } from "./mcpServers";
import type { ToolIntent } from "./permissions";

export interface EngineStart {
  cwd: string;
  model?: string;
  /** Continue this conversation instead of starting one. */
  resume?: string;
  /** Start as a copy of this conversation (a fork); engines that can't fork start fresh. */
  forkFrom?: string;
  /** Appended to the engine's own system prompt: the briefing and Nod's identity. */
  systemAppend?: string;
  /** The graphcode server and the project's `.mcp.json` servers; nothing else is mounted. */
  mcp?: McpMount;
}

export interface EngineSession {
  conversationID: string;
  model: string;
}

export interface UsageReport {
  inputTokens: number;
  outputTokens: number;
  /** Dollars spent so far this process, cumulative — Claude only. */
  costUSD?: number;
  /** Copilot bills premium requests instead of dollars; cumulative. */
  premiumRequests?: number;
  /** 0…1 of the context window in use. */
  contextUsed: number;
}

export interface ToolRequest {
  intent: ToolIntent;
  /** For an edit the runtime can stage: the file and its full content afterwards. */
  edit?: { path: string; after: string };
}

export type Authorization =
  | { allow: true }
  /** `interrupt` ends the turn too — an unattended loop that hit a question it can't ask. */
  | { allow: false; message: string; interrupt?: boolean };

export interface EngineFailure {
  kind: NodFailureKind;
  message: string;
}

/** What an engine reports while a turn runs; the runtime turns these into events. */
export interface TurnCallbacks {
  text(messageID: string, delta: string, final: boolean): void;
  toolCall(callID: string, tool: string, input: unknown): void;
  toolResult(callID: string, status: NodToolStatus, summary: string, output?: string, durationMs?: number): void;
  usage(report: UsageReport): void;
  compacted(): void;
  /** Called before a gated tool runs; may wait on a human. */
  authorize(request: ToolRequest): Promise<Authorization>;
  /** Steer text waiting for the next tool boundary, consumed by the call. */
  takeSteer(): string | undefined;
}

export interface TurnResult {
  /** The agent's final words this turn. */
  lastMessage: string;
  failure?: EngineFailure;
  interrupted?: boolean;
}

/**
 * One engine behind Nod: the Claude Agent SDK or the GitHub Copilot SDK. Everything Nod
 * adds — the event log, staging, the gate, the goal — sits above this and never
 * branches on which engine it has.
 */
/** One model the signed-in account can pick, as `graphcode-nod --list-models` prints it. */
export interface ModelListing {
  id: string;
  name: string;
  /** Premium-request multiplier, when the engine bills that way. */
  multiplier?: number;
}

export interface Engine {
  readonly kind: NodEngineKind;
  start(options: EngineStart): Promise<EngineSession>;
  /** Runs one turn to its end. Only one turn runs at a time. */
  runTurn(text: string, attachments: NodAttachment[], callbacks: TurnCallbacks): Promise<TurnResult>;
  interrupt(): Promise<void>;
  setModel(model: string): Promise<void>;
  /** Summarises older turns; reports `compacted` through the callbacks. */
  compact(callbacks: TurnCallbacks): Promise<TurnResult>;
  /** A one-shot question with no tools and no conversation — the goal judge and `-p`. */
  ask(prompt: string, model?: string): Promise<string>;
  /** The models this account may use, when the engine can say; undefined when it can't. */
  listModels?(): Promise<ModelListing[]>;
  close(): Promise<void>;
}
