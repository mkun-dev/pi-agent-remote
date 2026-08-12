import assert from "node:assert/strict";
import { test } from "node:test";
// Node 22 直接执行 erasable TypeScript；生产代码仍以 .js specifier 交给 Pi 加载。
// @ts-ignore TS 默认不允许显式 .ts 扩展，但测试运行器需要它。
import { buildHistory } from "../src/session-history.ts";

function sessionManager(sessionId = "session-a") {
  const entries = [
    {
      id: "entry-user",
      type: "message",
      timestamp: "2025-01-01T00:00:00.000Z",
      message: { role: "user", content: "A" }
    },
    {
      id: "entry-assistant",
      type: "message",
      timestamp: "2025-01-01T00:00:01.000Z",
      message: {
        role: "assistant",
        content: [
          { type: "text", text: "最终回答" },
          { type: "toolCall", id: "call-1", name: "read", arguments: { path: "README.md" } }
        ]
      }
    },
    {
      id: "entry-result",
      type: "message",
      timestamp: "2025-01-01T00:00:02.000Z",
      message: { role: "toolResult", content: [{ type: "text", text: "done" }] }
    }
  ];
  return {
    getSessionId: () => sessionId,
    buildContextEntries: () => entries
  };
}

test("复用 SessionEntry.id 并为拆分内容生成稳定唯一 ID", () => {
  const history = buildHistory(sessionManager());
  assert.deepEqual(history.map((entry) => entry.entryId), [
    "entry-user:user",
    "entry-assistant:assistant",
    "entry-assistant:tool:call-1",
    "entry-result:terminal"
  ]);
  assert.equal(new Set(history.map((entry) => entry.entryId)).size, history.length);
  assert.ok(history.every((entry) => entry.sessionId === "session-a"));
  assert.ok(history.every((entry) => Number.isFinite(entry.ts)));
});

test("连续恢复十次产生完全相同的历史快照", () => {
  const manager = sessionManager();
  const first = buildHistory(manager);
  for (let attempt = 0; attempt < 10; attempt += 1) {
    assert.deepEqual(buildHistory(manager), first);
  }
});

test("不同 Session 的历史身份彼此隔离", () => {
  const first = buildHistory(sessionManager("session-a"));
  const second = buildHistory(sessionManager("session-b"));
  assert.notEqual(first[0]?.sessionId, second[0]?.sessionId);
  assert.equal(first[0]?.entryId, second[0]?.entryId);
});

test("历史条数上限保留最新条目且 ID 不随截断变化", () => {
  const manager = sessionManager();
  const all = buildHistory(manager);
  const tail = buildHistory(manager, 2);
  assert.deepEqual(tail, all.slice(-2));
  assert.deepEqual(buildHistory(manager, 0), []);
});
