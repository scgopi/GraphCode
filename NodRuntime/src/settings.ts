import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { isAbsolute, join } from "node:path";
import type { NodEngineKind } from "./protocol";

export type Ask = "always" | "ask" | "never";

/** `NodSettings` in GraphcodeKit, read from the same `settings.json` the app writes. */
export interface NodSettings {
  engine: NodEngineKind;
  modelsByLoopType: Record<string, string>;
  compositeChildModel?: string;
  goalEvaluatorModel?: string;
  shell: Ask;
  network: Ask;
  editsInWorktree: "reviewHunks" | "auto";
  editsOutsideWorktree: Ask;
  messagesOtherLoops: "draftForMe" | "send" | "never";
  shellAllowlist: string[];
  spendCapUSD: number;
  /** `.mcp.json` servers switched off for Nod; the built-in graphcode server never is. */
  disabledMCPServers: string[];
}

export const defaultSettings: NodSettings = {
  engine: "claude",
  modelsByLoopType: {},
  shell: "ask",
  network: "ask",
  editsInWorktree: "auto",
  editsOutsideWorktree: "never",
  messagesOtherLoops: "draftForMe",
  shellAllowlist: [],
  spendCapUSD: 2,
  disabledMCPServers: [],
};

/** `~/.graphcode`, or `GRAPHCODE_SUPPORT_DIR` resolved against home, as `SupportDirectory` does. */
export function supportDirectory(env: Record<string, string | undefined> = process.env): string {
  const configured = env.GRAPHCODE_SUPPORT_DIR?.trim();
  if (!configured) return join(homedir(), ".graphcode");
  return isAbsolute(configured) ? configured : join(homedir(), configured);
}

/** Falls back field by field, like the Swift decoder, so a partial or missing file still works. */
export function loadSettings(path = join(supportDirectory(), "settings.json")): NodSettings {
  if (!existsSync(path)) return { ...defaultSettings };
  let nod: Record<string, unknown> = {};
  try {
    const parsed = JSON.parse(readFileSync(path, "utf8")) as { nod?: unknown };
    if (parsed.nod && typeof parsed.nod === "object") nod = parsed.nod as Record<string, unknown>;
  } catch {
    return { ...defaultSettings };
  }
  const pick = <T>(key: keyof NodSettings, valid: (value: unknown) => boolean): T =>
    (valid(nod[key]) ? nod[key] : defaultSettings[key]) as T;
  const oneOf = (...values: string[]) => (value: unknown) => typeof value === "string" && values.includes(value);
  const isString = (value: unknown) => typeof value === "string";
  return {
    engine: pick("engine", oneOf("claude", "copilot")),
    modelsByLoopType: pick("modelsByLoopType", (v) => typeof v === "object" && v !== null && !Array.isArray(v)),
    compositeChildModel: isString(nod.compositeChildModel) ? (nod.compositeChildModel as string) : undefined,
    goalEvaluatorModel: isString(nod.goalEvaluatorModel) ? (nod.goalEvaluatorModel as string) : undefined,
    shell: pick("shell", oneOf("always", "ask", "never")),
    network: pick("network", oneOf("always", "ask", "never")),
    editsInWorktree: pick("editsInWorktree", oneOf("reviewHunks", "auto")),
    editsOutsideWorktree: pick("editsOutsideWorktree", oneOf("always", "ask", "never")),
    messagesOtherLoops: pick("messagesOtherLoops", oneOf("draftForMe", "send", "never")),
    shellAllowlist: pick("shellAllowlist", (v) => Array.isArray(v) && v.every(isString)),
    spendCapUSD: pick("spendCapUSD", (v) => typeof v === "number" && Number.isFinite(v) && v >= 0),
    disabledMCPServers: pick("disabledMCPServers", (v) => Array.isArray(v) && v.every(isString)),
  };
}
