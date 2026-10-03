#!/usr/bin/env bun
import { mkdirSync, readFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { createInterface } from "node:readline";
import { parseArgs } from "node:util";
import { claudeExecutable, copilotRuntime } from "./agentRuntimes";
import { ClaudeEngine } from "./claudeEngine";
import { ControlSocket } from "./controlSocket";
import { CopilotEngine } from "./copilotEngine";
import { anthropicAPIKey, githubToken } from "./credentials";
import type { Engine } from "./engine";
import { readBrief } from "./brief";
import { EventLog } from "./eventLog";
import { loadProjectMcpServers } from "./mcpServers";
import { PresenceReporter } from "./presence";
import type { NodEngineKind } from "./protocol";
import { NodRuntime, type LoopType } from "./runtime";
import { loadSettings, supportDirectory } from "./settings";
import { Transcript } from "./transcript";

const USAGE = `graphcode-nod --node <uuid> --cwd <dir> [--engine claude|copilot] [--model <id>]
              [--loop-type main|goal|timed|turn|composite] [--goal-file <path>]
              [--briefing <path>] [--resume <conversation-id>] [--inherit <brief.json>]
              [--prompt <text>] [--unattended]
graphcode-nod -p <prompt> [--engine claude|copilot] [--model <id>]
graphcode-nod --list-models [--engine copilot]     # JSON: the models this account may use`;

const loopTypes = new Set(["main", "goal", "timed", "turn", "composite"]);

/** Claude Code's config directory: Nod's own, beside the per-node state directories. */
function claudeConfigDirectory(): string {
  const state = process.env.NOD_STATE;
  return state ? join(dirname(state), "claude") : join(supportDirectory(), "nod", "claude");
}

export function makeEngine(kind: NodEngineKind): Engine {
  if (kind === "copilot") {
    return new CopilotEngine({ githubToken: githubToken(), cliPath: copilotRuntime() });
  }
  return new ClaudeEngine({
    apiKey: anthropicAPIKey(),
    configDir: claudeConfigDirectory(),
    executable: claudeExecutable(),
  });
}

async function main(argv: string[]): Promise<number> {
  const { values } = parseArgs({
    args: argv,
    options: {
      node: { type: "string" },
      cwd: { type: "string" },
      engine: { type: "string" },
      model: { type: "string" },
      "loop-type": { type: "string" },
      "goal-file": { type: "string" },
      briefing: { type: "string" },
      resume: { type: "string" },
      inherit: { type: "string" },
      prompt: { type: "string" },
      print: { type: "string", short: "p" },
      "list-models": { type: "boolean" },
      unattended: { type: "boolean" },
      "exit-when-idle": { type: "boolean" },
      help: { type: "boolean", short: "h" },
    },
    strict: true,
  });
  if (values.help) {
    process.stdout.write(USAGE + "\n");
    return 0;
  }
  const settings = loadSettings();
  const engineKind = (values.engine ?? settings.engine) as NodEngineKind;
  if (engineKind !== "claude" && engineKind !== "copilot") throw new Error(`unknown engine ${engineKind}`);

  if (values["list-models"]) {
    const engine = makeEngine(engineKind);
    try {
      const models = engine.listModels ? await engine.listModels() : undefined;
      process.stdout.write(JSON.stringify({ engine: engineKind, models: models ?? null }) + "\n");
      return 0;
    } finally {
      await engine.close();
    }
  }

  if (values.print !== undefined) {
    const engine = makeEngine(engineKind);
    try {
      const answer = await engine.ask(values.print, values.model);
      process.stdout.write(answer.endsWith("\n") ? answer : answer + "\n");
      return 0;
    } finally {
      await engine.close();
    }
  }

  const nodeID = values.node ?? process.env.NOD_NODE_ID;
  if (!nodeID || !values.cwd) throw new Error(`--node (or NOD_NODE_ID) and --cwd are required\n${USAGE}`);
  const loopType = (values["loop-type"] ?? "main") as LoopType;
  if (!loopTypes.has(loopType)) throw new Error(`unknown loop type ${loopType}`);
  const cwd = resolve(values.cwd);
  // The launcher always sets NOD_STATE; a launch may not carry GRAPHCODE_SUPPORT_DIR.
  const stateDir = process.env.NOD_STATE || join(supportDirectory(), "nod", nodeID);
  mkdirSync(stateDir, { recursive: true });

  const log = new EventLog(join(stateDir, "events.jsonl"));
  const transcript = new Transcript((text) => process.stdout.write(text));
  log.onRecord((record) => transcript.render(record));
  const presence = new PresenceReporter(process.env.ZMX_SESSION);
  const engine = makeEngine(engineKind);
  const runtime = new NodRuntime({
    nodeID,
    cwd,
    stateDir,
    loopType,
    settings,
    engine,
    log,
    presence,
    model: values.model ?? settings.modelsByLoopType[loopType],
    goal: values["goal-file"] ? readFileSync(values["goal-file"], "utf8") : undefined,
    briefing: values.briefing ? readFileSync(values.briefing, "utf8") : undefined,
    resume: values.resume,
    inherit: values.inherit && !values.resume ? readBrief(values.inherit) : undefined,
    unattended: values.unattended || undefined,
    projectPath: process.env.NOD_PROJECT_PATH || undefined,
    messagesOtherLoops: () => loadSettings().messagesOtherLoops,
    mcpServers: loadProjectMcpServers(cwd, settings.disabledMCPServers),
  });
  const control = new ControlSocket(join(stateDir, "control.sock"), (command) => runtime.handle(command));
  await control.listen();

  let closing = false;
  const shutdown = async (code: number) => {
    if (closing) return;
    closing = true;
    await runtime.close().catch(() => {});
    await control.close().catch(() => {});
    process.exit(code);
  };
  process.on("SIGTERM", () => void shutdown(0));
  process.on("SIGHUP", () => void shutdown(0));
  // Ctrl-C in an attached terminal stops the turn first, as Esc does in the chat pane.
  process.on("SIGINT", () => void (runtime.isBusy ? runtime.stop() : shutdown(0)));

  await runtime.start(values.prompt);

  // A plain line typed into the PTY — a `.message` edge, `graphcode node send` — is a
  // queued send, so every existing way of talking to a loop reaches Nod unchanged.
  if (!values["exit-when-idle"]) {
    const lines = createInterface({ input: process.stdin, terminal: false });
    lines.on("line", (line) => {
      const text = line.trim();
      if (text) runtime.send(text, "queue");
    });
  }

  if (values["exit-when-idle"]) {
    await runtime.whenIdle();
    await shutdown(0);
  }
  return await new Promise<number>(() => {});
}

if (import.meta.main) {
  main(process.argv.slice(2)).then(
    (code) => process.exit(code),
    (error) => {
      process.stderr.write(`graphcode-nod: ${error instanceof Error ? error.message : String(error)}\n`);
      process.exit(1);
    },
  );
}
