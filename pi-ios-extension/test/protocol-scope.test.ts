import assert from "node:assert/strict";
import test from "node:test";
// @ts-ignore Node test runner loads erasable TypeScript directly.
import { ProtocolHandler, withScope } from "../src/protocol.ts";

test("withScope attaches agent and session metadata", () => {
  const event = withScope(
    ProtocolHandler.createAssistantDelta("m1", "hello", 1),
    { agentId: "win-1", sessionId: "session-a", sessionFile: "sessions/a.jsonl" }
  );

  assert.equal(event.payload.agentId, "win-1");
  assert.equal(event.payload.sessionId, "session-a");
  assert.equal(event.payload.sessionFile, "sessions/a.jsonl");
  assert.equal(event.payload.messageId, "m1");
});

test("protocol helpers preserve generation and selection request id", () => {
  const usage = ProtocolHandler.createUsageInfo({
    model: "claude",
    contextTokens: 1,
    contextWindow: 10,
    contextPercent: 10,
    totalInput: 1,
    totalOutput: 2,
    totalCacheRead: 0,
    totalCacheWrite: 0,
    totalReasoning: 0,
    totalTokens: 3,
    totalCost: 0,
  }, 12);
  const ack = ProtocolHandler.createModelSelectAck("gpt", true, undefined, "sel-1");

  assert.equal(usage.payload.generation, 12);
  assert.equal(ack.payload.selectionRequestId, "sel-1");
});
