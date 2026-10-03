import { expect, test } from "bun:test";
import type { CopilotClient } from "@github/copilot-sdk";
import { CopilotEngine } from "../src/copilotEngine";
import { defaultSettings } from "../src/settings";

test("the Copilot engine lists the account's models, without ones its policy switched off", async () => {
  let stopped = false;
  const client = {
    start: async () => {},
    stop: async () => {
      stopped = true;
      return [];
    },
    listModels: async () => [
      { id: "claude-sonnet-5", name: "Claude Sonnet 5", capabilities: {}, billing: { multiplier: 1 } },
      { id: "gpt-6-sol", name: "GPT-6 Sol", capabilities: {}, policy: { state: "disabled", terms: "" } },
      { id: "auto", name: "Auto", capabilities: {} },
    ],
  } as unknown as CopilotClient;
  const engine = new CopilotEngine({ client: () => client });

  const models = await engine.listModels();

  expect(models).toEqual([
    { id: "claude-sonnet-5", name: "Claude Sonnet 5", multiplier: 1 },
    { id: "auto", name: "Auto" },
  ]);
  expect(stopped).toBe(true);
});

test("edits in the loop's worktree are auto-accepted unless a person chose review", () => {
  expect(defaultSettings.editsInWorktree).toBe("auto");
});
