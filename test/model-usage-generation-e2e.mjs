#!/usr/bin/env node
import assert from "node:assert/strict";
import net from "node:net";
import { once } from "node:events";
import { spawn } from "node:child_process";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { WebSocket } = require("../pi-ios-extension/node_modules/ws");

const TOKEN = "test-token-generation-0123456789";

function log(...args) {
  console.log("[gen-e2e]", ...args);
}

async function freePort() {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  server.close();
  await once(server, "close");
  return port;
}

async function startRelay() {
  const port = await freePort();
  const child = spawn(process.execPath, ["relay-server/server.mjs"], {
    cwd: process.cwd(),
    env: { ...process.env, PORT: String(port), RELAY_TOKEN: TOKEN, ALLOW_QUERY_TOKEN: "1" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk) => { output += chunk.toString(); });
  const deadline = Date.now() + 5000;
  while (!output.includes("relay listening")) {
    if (child.exitCode !== null) throw new Error(output || "relay exited");
    if (Date.now() > deadline) throw new Error(`relay start timeout: ${output}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { child, port };
}

function stopRelay(child) {
  if (child?.exitCode === null) child.kill();
}

function normalize(path) {
  return String(path || "").replace(/\\/g, "/");
}

class Projection {
  constructor() {
    this.currentAgentId = null;
    this.currentSessionId = null;
    this.currentSessionFile = null;
    this.pendingSessionFile = null;
    this.currentSnapshotGeneration = 0;
    this.pendingUsageGeneration = null;
    this.pendingModelGeneration = null;
    this.currentModel = null;
    this.availableModels = [];
    this.usageInfo = null;
    this.pendingSelectionRequestId = null;
    this.modelLock = null;
  }

  switchAgent(agentId) {
    this.currentAgentId = agentId;
    this.currentSessionId = null;
    this.currentSessionFile = null;
    this.pendingSessionFile = null;
    this.currentModel = null;
    this.availableModels = [];
    this.usageInfo = null;
    this.pendingUsageGeneration = null;
    this.pendingModelGeneration = null;
    this.pendingSelectionRequestId = null;
    this.modelLock = null;
  }

  beginSessionSwitch(sessionFile) {
    this.pendingSessionFile = normalize(sessionFile);
    this.currentSessionId = null;
    this.currentSessionFile = null;
    this.currentModel = null;
    this.availableModels = [];
    this.usageInfo = null;
  }

  beginSnapshot(generation) {
    this.currentSnapshotGeneration = generation;
    this.pendingUsageGeneration = generation;
    this.pendingModelGeneration = generation;
  }

  beginSelection(requestId, modelId) {
    this.pendingSelectionRequestId = requestId;
    this.pendingSelectionModelId = modelId;
  }

  accept(message) {
    const payload = message.payload || {};
    const agentId = payload.agentId ?? null;
    const sessionId = payload.sessionId ?? null;
    const sessionFile = normalize(payload.sessionFile ?? null);
    const generation = typeof payload.generation === "number" ? payload.generation : null;
    const requestId = payload.selectionRequestId ?? null;

    if (message.type.startsWith("relay.")) return;
    if (this.currentAgentId && agentId && agentId !== this.currentAgentId) return;
    if (this.pendingSessionFile && sessionFile && sessionFile !== this.pendingSessionFile) return;
    if (!this.pendingSessionFile && this.currentSessionFile && sessionFile && sessionFile !== this.currentSessionFile) return;

    switch (message.type) {
      case "session.info":
      case "session.update":
        if (this.pendingSessionFile && sessionFile === this.pendingSessionFile) {
          this.pendingSessionFile = null;
        }
        this.currentSessionId = sessionId;
        this.currentSessionFile = sessionFile;
        return;
      case "usage.info":
        if (generation !== null && generation < this.currentSnapshotGeneration) return;
        if (generation !== null && generation === this.pendingUsageGeneration) {
          this.pendingUsageGeneration = null;
        }
        this.usageInfo = { ...payload };
        if (payload.model) {
          if (this.modelLock && payload.model !== this.modelLock.modelId && (generation === null || generation <= this.modelLock.generation)) {
            this.usageInfo.model = this.modelLock.modelId;
          } else {
            this.currentModel = payload.model;
            if (this.modelLock && generation !== null && generation > this.modelLock.generation) {
              this.modelLock = null;
            }
          }
        }
        return;
      case "model.list":
        if (generation === null || generation < this.currentSnapshotGeneration) return;
        if (generation === this.pendingModelGeneration) {
          this.pendingModelGeneration = null;
        }
        this.availableModels = payload.models || [];
        return;
      case "model.select_ack":
        if (this.pendingSelectionRequestId && requestId !== this.pendingSelectionRequestId) return;
        if (payload.ok && payload.modelId) {
          this.currentModel = payload.modelId;
          this.modelLock = { requestId, modelId: payload.modelId, generation: this.currentSnapshotGeneration };
          if (this.usageInfo) this.usageInfo.model = payload.modelId;
        }
        this.pendingSelectionRequestId = null;
        return;
      default:
        return;
    }
  }
}

function makeAgentState(agentId, sessions, currentFile) {
  return {
    agentId,
    sessions,
    currentFile,
    availableModels: ["Claude", "GPT", "Gemini", "Omega"],
    delayByGeneration: new Map(),
  };
}

function scopedPayload(state, extra = {}) {
  const session = state.sessions[state.currentFile];
  return {
    agentId: state.agentId,
    sessionId: session.id,
    sessionFile: session.file,
    ...extra,
  };
}

function attachAgent(socket, state) {
  socket.on("message", (raw) => {
    const msg = JSON.parse(raw.toString());
    const payload = msg.payload || {};
    const session = state.sessions[state.currentFile];
    const send = (type, extra, delay = 0) => {
      const body = { id: msg.id, type, timestamp: Date.now(), payload: scopedPayload(state, extra) };
      setTimeout(() => socket.send(JSON.stringify(body)), delay);
    };

    if (msg.type === "session.resume") {
      send("session.info", {
        sessionId: session.id,
        sessionFile: session.file,
        name: session.name,
        leafId: null,
        entryCount: 2,
        reason: "resume"
      });
      return;
    }

    if (msg.type === "session.switch") {
      const nextFile = normalize(payload.sessionFile);
      state.currentFile = nextFile;
      const next = state.sessions[nextFile];
      send("session.switch_ack", { sessionFile: next.file, ok: true });
      return;
    }

    if (msg.type === "usage.request") {
      const generation = payload.generation;
      const delay = state.delayByGeneration.get(`usage:${generation}`) ?? 0;
      const active = state.sessions[state.currentFile];
      send("usage.info", {
        generation,
        model: active.model,
        contextTokens: 0,
        contextWindow: 200000,
        contextPercent: 0,
        totalInput: active.usage.input,
        totalOutput: active.usage.output,
        totalCacheRead: active.usage.cacheRead,
        totalCacheWrite: active.usage.cacheWrite,
        totalReasoning: active.usage.reasoning,
        totalTokens: active.usage.total,
        totalCost: active.usage.cost,
      }, delay);
      return;
    }

    if (msg.type === "model.request") {
      const generation = payload.generation;
      const delay = state.delayByGeneration.get(`model:${generation}`) ?? 0;
      send("model.list", { generation, models: state.availableModels }, delay);
      return;
    }

    if (msg.type === "model.select") {
      const active = state.sessions[state.currentFile];
      const requestId = payload.selectionRequestId;
      const target = payload.modelId;
      if (target === "FAIL") {
        send("model.select_ack", { modelId: target, ok: false, selectionRequestId: requestId });
        return;
      }
      active.model = target;
      send("model.select_ack", { modelId: target, ok: true, selectionRequestId: requestId });
      return;
    }
  });
}

async function connectAgent(baseUrl, state) {
  const socket = new WebSocket(`${baseUrl}?role=agent&agentId=${state.agentId}&token=${TOKEN}`);
  await once(socket, "open");
  attachAgent(socket, state);
  return socket;
}

async function connectClient(baseUrl) {
  const socket = new WebSocket(`${baseUrl}?role=client&client_id=ios-e2e-client&token=${TOKEN}`);
  await once(socket, "open");
  return socket;
}

async function wait(ms) {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function waitFor(predicate, timeout = 2000) {
  const deadline = Date.now() + timeout;
  while (Date.now() < deadline) {
    const value = predicate();
    if (value) return value;
    await wait(20);
  }
  throw new Error("waitFor timeout");
}

async function main() {
  const relay = await startRelay();
  const baseUrl = `ws://127.0.0.1:${relay.port}`;
  const results = [];
  const record = (name, pass, detail = "") => {
    results.push({ name, pass, detail });
    log(`${pass ? "✅" : "❌"} ${name}${detail ? ` — ${detail}` : ""}`);
  };

  const agentAState = makeAgentState("agent-test-a", {
    "sessions/a.jsonl": { id: "session-a", file: "sessions/a.jsonl", name: "A", model: "Claude", usage: { input: 400, output: 600, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 1000, cost: 1 } },
    "sessions/b.jsonl": { id: "session-b", file: "sessions/b.jsonl", name: "B", model: "GPT", usage: { input: 80, output: 120, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 200, cost: 0.2 } },
    "sessions/c.jsonl": { id: "session-c", file: "sessions/c.jsonl", name: "C", model: "Gemini", usage: { input: 200, output: 100, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 300, cost: 0.3 } }
  }, "sessions/a.jsonl");
  const agentBState = makeAgentState("agent-test-b", {
    "sessions/b1.jsonl": { id: "session-b1", file: "sessions/b1.jsonl", name: "B1", model: "GPT", usage: { input: 500, output: 500, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 1000, cost: 1 } },
    "sessions/b2.jsonl": { id: "session-b2", file: "sessions/b2.jsonl", name: "B2", model: "Claude", usage: { input: 250, output: 350, cacheRead: 0, cacheWrite: 0, reasoning: 0, total: 600, cost: 0.6 } }
  }, "sessions/b1.jsonl");

  const agentA = await connectAgent(baseUrl, agentAState);
  const agentB = await connectAgent(baseUrl, agentBState);
  const client = await connectClient(baseUrl);
  const projection = new Projection();
  projection.switchAgent("agent-test-a");
  client.on("message", (raw) => projection.accept(JSON.parse(raw.toString())));

  const send = (type, payload) => client.send(JSON.stringify({ id: `${type}-${Math.random().toString(36).slice(2, 8)}`, type, timestamp: Date.now(), payload }));
  let generation = 0;
  const snapshot = (reason, targetAgentId) => {
    generation += 1;
    projection.beginSnapshot(generation);
    send("session.resume", { targetAgentId, generation });
    send("usage.request", { targetAgentId, generation });
    send("model.request", { targetAgentId, generation });
    return generation;
  };

  // T1 initial snapshot
  snapshot("initial", "agent-test-a");
  await waitFor(() => projection.currentModel === "Claude" && projection.usageInfo?.totalTokens === 1000 && projection.availableModels.length > 0);
  record("Initial snapshot", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T2 A -> B session
  projection.beginSessionSwitch("sessions/b.jsonl");
  send("session.switch", { targetAgentId: "agent-test-a", sessionFile: "sessions/b.jsonl" });
  snapshot("session-a-b", "agent-test-a");
  await waitFor(() => projection.currentSessionFile === "sessions/b.jsonl" && projection.currentModel === "GPT" && projection.usageInfo?.totalTokens === 200);
  record("Session A→B", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T3 B -> A session
  projection.beginSessionSwitch("sessions/a.jsonl");
  send("session.switch", { targetAgentId: "agent-test-a", sessionFile: "sessions/a.jsonl" });
  snapshot("session-b-a", "agent-test-a");
  await waitFor(() => projection.currentSessionFile === "sessions/a.jsonl" && projection.currentModel === "Claude" && projection.usageInfo?.totalTokens === 1000);
  record("B→A", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T4 Agent A -> B
  projection.switchAgent("agent-test-b");
  snapshot("agent-a-b", "agent-test-b");
  await waitFor(() => projection.currentModel === "GPT" && projection.usageInfo?.totalTokens === 1000);
  record("Agent A→B", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T5 stale late response ignored by generation
  projection.switchAgent("agent-test-a");
  agentAState.currentFile = "sessions/a.jsonl";
  agentAState.delayByGeneration.set("usage:5", 160);
  agentAState.delayByGeneration.set("model:5", 160);
  snapshot("stale-old", "agent-test-a"); // generation 5
  projection.beginSessionSwitch("sessions/b.jsonl");
  send("session.switch", { targetAgentId: "agent-test-a", sessionFile: "sessions/b.jsonl" });
  snapshot("stale-new", "agent-test-a"); // generation 6
  await waitFor(() => projection.currentSessionFile === "sessions/b.jsonl" && projection.currentModel === "GPT" && projection.usageInfo?.totalTokens === 200);
  await wait(220);
  record("旧响应晚到", projection.currentModel === "GPT" && projection.usageInfo?.totalTokens === 200, `${projection.currentModel}/${projection.usageInfo?.totalTokens}`);
  agentAState.delayByGeneration.clear();

  // T6 fast A -> B -> A -> C
  projection.switchAgent("agent-test-a");
  for (const file of ["sessions/b.jsonl", "sessions/a.jsonl", "sessions/c.jsonl"]) {
    projection.beginSessionSwitch(file);
    send("session.switch", { targetAgentId: "agent-test-a", sessionFile: file });
    snapshot(`fast-${file}`, "agent-test-a");
  }
  await waitFor(() => projection.currentSessionFile === "sessions/c.jsonl" && projection.currentModel === "Gemini" && projection.usageInfo?.totalTokens === 300);
  record("快速 A→B→A→C", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T7 model select success
  const successRequestId = "sel-success";
  projection.beginSelection(successRequestId, "Omega");
  send("model.select", { targetAgentId: "agent-test-a", modelId: "Omega", selectionRequestId: successRequestId });
  await waitFor(() => projection.currentModel === "Omega");
  record("Model select success", true, projection.currentModel);

  // T8 model select failure
  const failRequestId = "sel-fail";
  projection.beginSelection(failRequestId, "FAIL");
  send("model.select", { targetAgentId: "agent-test-a", modelId: "FAIL", selectionRequestId: failRequestId });
  await wait(80);
  record("Model select failure", projection.currentModel === "Omega", projection.currentModel);

  // T9 old usage does not override new model
  const oldGen = projection.currentSnapshotGeneration;
  const staleUsage = {
    id: "late-usage",
    type: "usage.info",
    timestamp: Date.now(),
    payload: {
      agentId: "agent-test-a",
      sessionId: agentAState.sessions[agentAState.currentFile].id,
      sessionFile: agentAState.sessions[agentAState.currentFile].file,
      generation: oldGen,
      model: "Claude",
      contextTokens: 0,
      contextWindow: 200000,
      contextPercent: 0,
      totalInput: 1,
      totalOutput: 1,
      totalCacheRead: 0,
      totalCacheWrite: 0,
      totalReasoning: 0,
      totalTokens: 2,
      totalCost: 0,
    }
  };
  agentA.send(JSON.stringify(staleUsage));
  await wait(80);
  record("旧 usage 不覆盖新 model", projection.currentModel === "Omega", projection.currentModel);

  // T10 agent continues running -> live usage update should be accepted without generation
  const liveUsage = {
    id: "live-usage",
    type: "usage.info",
    timestamp: Date.now(),
    payload: {
      agentId: "agent-test-a",
      sessionId: agentAState.sessions[agentAState.currentFile].id,
      sessionFile: agentAState.sessions[agentAState.currentFile].file,
      model: "Omega",
      contextTokens: 0,
      contextWindow: 200000,
      contextPercent: 0,
      totalInput: 220,
      totalOutput: 230,
      totalCacheRead: 0,
      totalCacheWrite: 0,
      totalReasoning: 0,
      totalTokens: 450,
      totalCost: 0.45,
    }
  };
  agentA.send(JSON.stringify(liveUsage));
  await waitFor(() => projection.usageInfo?.totalTokens === 450);
  record("Agent continue running", projection.currentModel === "Omega" && projection.usageInfo?.totalTokens === 450, `${projection.currentModel}/${projection.usageInfo?.totalTokens}`);

  // T11 history no double count (covered by extension unit test)
  record("历史 usage no double count", true, "covered by usage-accumulator.test.ts");

  // T12 reconnect to agent-b session-b2
  projection.switchAgent("agent-test-b");
  send("session.switch", { targetAgentId: "agent-test-b", sessionFile: "sessions/b2.jsonl" });
  projection.beginSessionSwitch("sessions/b2.jsonl");
  snapshot("pre-reconnect", "agent-test-b");
  await waitFor(() => projection.currentSessionFile === "sessions/b2.jsonl");
  client.close();
  await wait(80);
  const client2 = await connectClient(baseUrl);
  client2.on("message", (raw) => projection.accept(JSON.parse(raw.toString())));
  const send2 = (type, payload) => client2.send(JSON.stringify({ id: `${type}-${Math.random().toString(36).slice(2, 8)}`, type, timestamp: Date.now(), payload }));
  generation += 1;
  projection.beginSnapshot(generation);
  send2("session.resume", { targetAgentId: "agent-test-b", generation });
  send2("usage.request", { targetAgentId: "agent-test-b", generation });
  send2("model.request", { targetAgentId: "agent-test-b", generation });
  await waitFor(() => projection.currentSessionFile === "sessions/b2.jsonl" && projection.currentModel === "Claude" && projection.usageInfo?.totalTokens === 600);
  record("Reconnect", true, `${projection.currentSessionFile}/${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  // T12 background resume
  agentBState.sessions["sessions/b2.jsonl"].model = "GPT";
  agentBState.sessions["sessions/b2.jsonl"].usage.total = 777;
  generation += 1;
  projection.beginSnapshot(generation);
  send2("session.resume", { targetAgentId: "agent-test-b", generation });
  send2("usage.request", { targetAgentId: "agent-test-b", generation });
  send2("model.request", { targetAgentId: "agent-test-b", generation });
  await waitFor(() => projection.currentModel === "GPT" && projection.usageInfo?.totalTokens === 777);
  record("Background resume", true, `${projection.currentModel}/${projection.usageInfo.totalTokens}`);

  client2.close();
  agentA.close();
  agentB.close();
  stopRelay(relay.child);

  const passed = results.filter((item) => item.pass).length;
  console.log(`\n通过 ${passed}/${results.length}`);
  if (passed !== results.length) process.exit(1);
}

main().catch((error) => {
  console.error(error);
  process.exit(1);
});
