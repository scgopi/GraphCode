import { expect, test } from "bun:test";
import { defaultSettings } from "../src/settings";

test("Nod runs uncapped unless a person sets a spend cap", () => {
  expect(defaultSettings.spendCapUSD).toBe(0);
});
