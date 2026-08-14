import assert from "node:assert/strict";
import test from "node:test";
// @ts-ignore Node test runner loads erasable TypeScript directly.
import { addUsage, maxUsage, summarizeBranchUsage, zeroUsageAccumulator, shouldSkipDuplicateTurnEnd } from "../src/usage-accumulator.ts";

test("summarizeBranchUsage totals assistant usage and discovers model", () => {
  const branch = [
    { type: "message", message: { role: "user", content: "hi" } },
    { type: "message", message: { role: "assistant", model: "claude", usage: { input: 10, output: 20, totalTokens: 30, cost: { total: 0.1 } } } },
    { type: "message", message: { role: "assistant", model: "gpt", usage: { input: 1, output: 2, total: 3, cacheRead: 4, cacheWrite: 5, reasoning: 6 } } }
  ];

  const result = summarizeBranchUsage(branch);
  assert.equal(result.discoveredModel, "gpt");
  assert.deepEqual(result.usage, {
    input: 11,
    output: 22,
    cacheRead: 4,
    cacheWrite: 5,
    reasoning: 6,
    totalTokens: 33,
    cost: 0.1,
  });
});

test("maxUsage preserves in-memory totals only within same session", () => {
  const historical = { input: 100, output: 50, cacheRead: 0, cacheWrite: 0, reasoning: 0, totalTokens: 150, cost: 1 };
  const inMemory = { input: 120, output: 55, cacheRead: 0, cacheWrite: 0, reasoning: 0, totalTokens: 175, cost: 1.2 };
  assert.equal(maxUsage(historical, inMemory).totalTokens, 175);
  assert.equal(historical.totalTokens, 150);
});

test("new session must not preserve previous session in-memory usage", () => {
  const previousSession = addUsage(zeroUsageAccumulator(), { input: 40, output: 60, totalTokens: 100 });
  const newSession = summarizeBranchUsage([]).usage;
  assert.equal(newSession.totalTokens, 0);
  assert.equal(previousSession.totalTokens, 100);
});

test("addUsage treats undefined or provider-missing fields as zero", () => {
  const acc = addUsage(zeroUsageAccumulator(), { input: undefined, output: 5, total: 9, cost: { total: undefined } });
  assert.deepEqual(acc, {
    input: 0,
    output: 5,
    cacheRead: 0,
    cacheWrite: 0,
    reasoning: 0,
    totalTokens: 9,
    cost: 0,
  });
});

test("shouldSkipDuplicateTurnEnd skips same messageId and updates seen", () => {
  // 首次出现：不跳过，记录 seen
  const [skip1, seen1] = shouldSkipDuplicateTurnEnd("msg-1", null);
  assert.equal(skip1, false);
  assert.equal(seen1, "msg-1");

  // 同一 messageId 再次出现：跳过，seen 不变
  const [skip2, seen2] = shouldSkipDuplicateTurnEnd("msg-1", "msg-1");
  assert.equal(skip2, true);
  assert.equal(seen2, "msg-1");

  // 不同 messageId：不跳过，更新 seen
  const [skip3, seen3] = shouldSkipDuplicateTurnEnd("msg-2", "msg-1");
  assert.equal(skip3, false);
  assert.equal(seen3, "msg-2");
});

test("shouldSkipDuplicateTurnEnd does not skip when messageId is empty or missing", () => {
  // 空 id（无法判定）→ 保守不跳过，seen 不变
  const [skipEmpty, seenEmpty] = shouldSkipDuplicateTurnEnd("", "msg-1");
  assert.equal(skipEmpty, false);
  assert.equal(seenEmpty, "msg-1");

  const [skipNull, seenNull] = shouldSkipDuplicateTurnEnd(null, "msg-1");
  assert.equal(skipNull, false);
  assert.equal(seenNull, "msg-1");

  const [skipUndef, seenUndef] = shouldSkipDuplicateTurnEnd(undefined, null);
  assert.equal(skipUndef, false);
  assert.equal(seenUndef, null);
});

test("shouldSkipDuplicateTurnEnd trims whitespace before comparing", () => {
  const [skip, seen] = shouldSkipDuplicateTurnEnd("  msg-1  ", "msg-1");
  assert.equal(skip, true);
  assert.equal(seen, "msg-1");
});
