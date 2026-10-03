import { randomUUID } from "node:crypto";
import { existsSync } from "node:fs";
import { isAbsolute, resolve } from "node:path";
import {
  CopilotClient,
  RuntimeConnection,
  type CopilotClientOptions,
  type CopilotSession,
  type PermissionRequest,
  type PermissionRequestResult,
  type SessionConfig,
  type SessionEvent,
} from "@github/copilot-sdk";
import type {
  Engine,
  EngineFailure,
  EngineSession,
  EngineStart,
  ModelListing,
  ToolRequest,
  TurnCallbacks,
  TurnResult,
} from "./engine";
import { serverName } from "./mcp";
import { copilotGraphcodeTools, copilotMcpServers, copilotToolPrefix } from "./mcpServers";
import type { NodAttachment } from "./protocol";
import { summarizeResult } from "./tools";

interface ActiveTurn {
  callbacks: TurnCallbacks;
  lastMessage: string;
  streamed: Set<string>;
  failure?: EngineFailure;
  interrupted: boolean;
  premiumCounted: boolean;
  resolve: (result: TurnResult) => void;
}

export interface CopilotEngineOptions {
  /** A token from Nod's Keychain entry; without it the Copilot CLI's own login is used. */
  githubToken?: string;
  /** The Copilot runtime to spawn; the SDK's bundled one when absent. */
  cliPath?: string;
  /** Tests pass a fake client to see the config a session opens with. */
  client?: (options: CopilotClientOptions) => CopilotClient;
}

/**
 * The GitHub Copilot SDK engine. Copilot asks permission through one handler for every
 * shell, write, URL and MCP request, so the gate sits there; a write carries the file's
 * new contents, which is all hunk staging needs. Steering rides `onPostToolUse`'s
 * `additionalContext`, the same tool boundary the Claude engine uses.
 */
export class CopilotEngine implements Engine {
  readonly kind = "copilot" as const;
  private client?: CopilotClient;
  private session?: CopilotSession;
  private start_?: EngineStart;
  private turn?: ActiveTurn;
  private model = "";
  private tokens = { input: 0, output: 0 };
  private premiumRequests = 0;
  private contextUsed = 0;
  private tools = new Map<string, { name: string; at: number }>();
  /** Copilot folds `additionalContext` into the tool's result; it is cut back out for the card. */
  private injectedSteer?: string;

  constructor(private readonly options: CopilotEngineOptions) {}

  async start(start: EngineStart): Promise<EngineSession> {
    this.start_ = start;
    const client = this.makeClient(start.cwd);
    this.client = client;
    await client.start();
    const config: SessionConfig = {
      model: start.model,
      workingDirectory: start.cwd,
      streaming: true,
      systemMessage: start.systemAppend ? { mode: "append", content: start.systemAppend } : undefined,
      onPermissionRequest: (request) => this.onPermission(request),
      tools: copilotGraphcodeTools(start.mcp?.graphcode ?? []),
      mcpServers: copilotMcpServers(start.mcp ?? { graphcode: [], servers: {} }),
      hooks: {
        onPostToolUse: () => {
          const steer = this.turn?.callbacks.takeSteer();
          if (!steer) return undefined;
          this.injectedSteer = steer;
          return { additionalContext: steer };
        },
      },
    };
    const session = start.resume
      ? await client.resumeSession(start.resume, config)
      : await client.createSession({ ...config, sessionId: randomUUID() });
    this.session = session;
    session.on((event) => this.onEvent(event));
    this.model = start.model ?? (await this.currentModel()) ?? "default";
    return { conversationID: session.sessionId, model: this.model };
  }

  private makeClient(cwd: string): CopilotClient {
    const path = this.options.cliPath;
    const options: CopilotClientOptions = {
      workingDirectory: cwd,
      logLevel: "error",
      ...(this.options.githubToken ? { gitHubToken: this.options.githubToken, useLoggedInUser: false } : { useLoggedInUser: true }),
      ...(path ? { connection: RuntimeConnection.forStdio({ path }) } : {}),
    };
    return this.options.client ? this.options.client(options) : new CopilotClient(options);
  }

  private async currentModel(): Promise<string | undefined> {
    const events = await this.session?.getEvents().catch(() => []);
    for (const event of [...(events ?? [])].reverse()) {
      if (event.type === "session.model_change") return (event.data as { newModel?: string }).newModel;
      if (event.type === "session.start") return (event.data as { selectedModel?: string }).selectedModel;
    }
    return undefined;
  }

  runTurn(text: string, attachments: NodAttachment[], callbacks: TurnCallbacks): Promise<TurnResult> {
    const session = this.session;
    if (!session) return Promise.resolve({ lastMessage: "", failure: { kind: "engineError", message: "Copilot session is not running." } });
    return new Promise<TurnResult>((resolve) => {
      this.turn = { callbacks, lastMessage: "", streamed: new Set(), interrupted: false, premiumCounted: false, resolve };
      session
        .send({ prompt: withNotes(text, attachments), attachments: fileAttachments(attachments, this.start_!.cwd) })
        .catch((error) => this.finishTurn(classify(error)));
    });
  }

  async interrupt(): Promise<void> {
    if (!this.turn) return;
    this.turn.interrupted = true;
    await this.session?.abort().catch(() => {});
  }

  async setModel(model: string): Promise<void> {
    await this.session?.setModel(model);
    this.model = model;
  }

  compact(callbacks: TurnCallbacks): Promise<TurnResult> {
    return this.runTurn("/compact", [], callbacks);
  }

  async ask(prompt: string, model?: string): Promise<string> {
    const client = this.client ?? this.makeClient(this.start_?.cwd ?? process.cwd());
    if (!this.client) await client.start();
    const session = await client.createSession({
      model: model || this.model || undefined,
      workingDirectory: this.start_?.cwd ?? process.cwd(),
      availableTools: [],
      onPermissionRequest: () => ({ kind: "reject" }),
    });
    try {
      const reply = await session.sendAndWait({ prompt }, 120_000);
      return (reply?.data as { content?: string } | undefined)?.content ?? "";
    } finally {
      await session.disconnect().catch(() => {});
      await client.deleteSession(session.sessionId).catch(() => {});
      if (!this.client) await client.stop();
    }
  }

  /** The SDK's own list for this account, minus models its policy has switched off. */
  async listModels(): Promise<ModelListing[]> {
    const client = this.makeClient(process.cwd());
    await client.start();
    try {
      const models = await client.listModels();
      return models
        .filter((model) => model.policy?.state !== "disabled")
        .map((model) => ({
          id: model.id,
          name: model.name,
          ...(model.billing?.multiplier !== undefined ? { multiplier: model.billing.multiplier } : {}),
        }));
    } finally {
      await client.stop();
    }
  }

  async close(): Promise<void> {
    await this.session?.disconnect().catch(() => {});
    await this.client?.stop().catch(() => {});
  }

  private finishTurn(failure?: EngineFailure): void {
    const turn = this.turn;
    if (!turn) return;
    this.turn = undefined;
    turn.resolve({ lastMessage: turn.lastMessage, failure: failure ?? turn.failure, interrupted: turn.interrupted });
  }

  private async onPermission(request: PermissionRequest): Promise<PermissionRequestResult> {
    const turn = this.turn;
    if (!turn) return { kind: "reject", feedback: "No turn is running." } as PermissionRequestResult;
    const authorization = await turn.callbacks.authorize(toolRequest(request, this.start_!.cwd));
    if (authorization.allow) return { kind: "approve-once" } as PermissionRequestResult;
    if (authorization.interrupt) {
      turn.interrupted = true;
      void this.session?.abort().catch(() => {});
    }
    return { kind: "reject", feedback: authorization.message } as PermissionRequestResult;
  }

  private onEvent(event: SessionEvent): void {
    const turn = this.turn;
    const data = event.data as Record<string, unknown>;
    // Sub-agent traffic stays inside its parent's card.
    if (typeof data?.parentToolCallId === "string") return;
    switch (event.type) {
      case "assistant.message_delta": {
        const id = String(data.messageId);
        turn?.streamed.add(id);
        turn?.callbacks.text(id, String(data.deltaContent ?? ""), false);
        return;
      }
      case "assistant.message": {
        if (!turn) return;
        const id = String(data.messageId);
        const content = String(data.content ?? "");
        if (!turn.streamed.has(id) && content) turn.callbacks.text(id, content, false);
        turn.callbacks.text(id, "", true);
        if (content.trim()) turn.lastMessage = content;
        return;
      }
      case "tool.execution_start": {
        const id = String(data.toolCallId);
        const name = String(data.toolName ?? "tool");
        this.tools.set(id, { name, at: Date.now() });
        turn?.callbacks.toolCall(id, name, data.arguments);
        return;
      }
      case "tool.execution_complete": {
        const id = String(data.toolCallId);
        const tool = this.tools.get(id);
        this.tools.delete(id);
        const ok = data.success === true;
        const result = data.result as { content?: string } | undefined;
        const error = data.error as { message?: string } | undefined;
        let output = ok ? (result?.content ?? "") : (error?.message ?? result?.content ?? "failed");
        if (this.injectedSteer && output.includes(this.injectedSteer)) {
          output = output
            .replace(this.injectedSteer, "")
            .replace(/\s*Additional guidance from postToolUse hooks:\s*$/, "")
            .trim();
          this.injectedSteer = undefined;
        }
        turn?.callbacks.toolResult(id, ok ? "ok" : "error", summarizeResult(tool?.name ?? "", output, !ok), output, tool ? Date.now() - tool.at : undefined);
        return;
      }
      case "assistant.usage": {
        this.tokens.input += Number(data.inputTokens ?? 0) + Number(data.cacheReadTokens ?? 0) + Number(data.cacheWriteTokens ?? 0);
        this.tokens.output += Number(data.outputTokens ?? 0);
        // One premium request per user turn, at the model's multiplier.
        if (turn && !turn.premiumCounted && typeof data.cost === "number") {
          turn.premiumCounted = true;
          this.premiumRequests += data.cost;
        }
        turn?.callbacks.usage(this.report());
        return;
      }
      case "session.usage_info": {
        const limit = Number(data.tokenLimit ?? 0);
        if (limit > 0) this.contextUsed = Math.min(1, Number(data.currentTokens ?? 0) / limit);
        turn?.callbacks.usage(this.report());
        return;
      }
      case "session.compaction_complete":
        if (data.success === true) turn?.callbacks.compacted();
        return;
      case "session.model_change":
        if (typeof data.newModel === "string") this.model = data.newModel;
        return;
      case "session.error": {
        if (turn) turn.failure = sessionFailure(String(data.errorType ?? ""), String(data.message ?? "Copilot reported an error."));
        return;
      }
      case "session.idle":
        if (turn && data.aborted === true) turn.interrupted = true;
        this.finishTurn();
        return;
    }
  }

  private report() {
    return {
      inputTokens: this.tokens.input,
      outputTokens: this.tokens.output,
      premiumRequests: Math.round(this.premiumRequests),
      contextUsed: this.contextUsed,
    };
  }
}

export function toolRequest(request: PermissionRequest, cwd: string): ToolRequest {
  const r = request as unknown as Record<string, unknown> & { kind: string };
  const str = (key: string) => (typeof r[key] === "string" ? (r[key] as string) : "");
  const abs = (path: string) => (isAbsolute(path) ? path : resolve(cwd, path));
  switch (r.kind) {
    case "shell":
      return { intent: { kind: "shell", command: str("fullCommandText") } };
    case "write": {
      const path = abs(str("resolvedPath") || str("fileName"));
      const after = typeof r.newFileContents === "string" ? r.newFileContents : undefined;
      return { intent: { kind: "edit", path }, ...(after === undefined ? {} : { edit: { path, after } }) };
    }
    case "url":
      return { intent: { kind: "fetch", url: str("url") } };
    case "mcp":
      return { intent: { kind: "mcp", server: str("serverName"), tool: str("toolName") } };
    case "custom-tool": {
      const name = str("toolName");
      if (name.startsWith(copilotToolPrefix)) return { intent: { kind: "mcp", server: serverName, tool: name.slice(copilotToolPrefix.length) } };
      return { intent: { kind: "read" } };
    }
    case "read":
      return { intent: { kind: "read" } };
  }
  return { intent: { kind: "read" } };
}

function sessionFailure(errorType: string, message: string): EngineFailure {
  switch (errorType) {
    case "authentication":
    case "authorization":
      return { kind: "signInExpired", message: `Copilot sign-in expired. ${message}` };
    case "context_limit":
      return { kind: "contextFull", message };
    default:
      return { kind: "engineError", message };
  }
}

function classify(error: unknown): EngineFailure {
  const message = error instanceof Error ? error.message : String(error);
  if (/auth|login|token|401|403/i.test(message)) return { kind: "signInExpired", message };
  return { kind: "engineError", message };
}

function withNotes(text: string, attachments: NodAttachment[]): string {
  const notes = attachments
    .filter((a) => a.kind === "loopTranscript")
    .map((a) => `Attached: the transcript of loop ${a.label ?? a.reference} (${a.reference}).`);
  return notes.length > 0 ? `${notes.join("\n")}\n\n${text}` : text;
}

function fileAttachments(attachments: NodAttachment[], cwd: string) {
  return attachments
    .filter((a) => a.kind !== "loopTranscript")
    .map((a) => (isAbsolute(a.reference) ? a.reference : resolve(cwd, a.reference)))
    .filter((path) => existsSync(path))
    .map((path) => ({ type: "file" as const, path }));
}
