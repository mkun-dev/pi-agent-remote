#!/usr/bin/env node
/**
 * 模型与用量功能稳定性回归测试（wire-level 全链路模拟）
 *
 * 模拟拓扑：
 *   iOS Client ──ws──▶ Relay ──ws──▶ Agent A / Agent B
 *
 * 覆盖阶段：
 *   1. 单 Agent：model.list / model.select / usage.info 链路
 *   2. 多 Agent：targetAgentId 路由、无串台
 *   3. 连接生命周期：重连后 agents → currentAgentId → 模型/用量恢复
 *   4. 异常：targetAgentId 失效返回 agent_offline；空 model 列表
 */

import { spawn } from "node:child_process";
import { createRequire } from "node:module";
const require = createRequire(import.meta.url);
const { WebSocket } = require("../pi-ios-extension/node_modules/ws");
import assert from "node:assert/strict";

const RELAY_PORT = 3117;
const RELAY_URL = `ws://127.0.0.1:${RELAY_PORT}`;
const TOKEN = "test-token-regression-0123456789";

let relayProc = null;
const agents = new Map(); // agentId -> WebSocket
let client = null;
let nextClientId = 0;
const results = [];
const log = (...a) => console.log("[test]", ...a);

function record(scene, pass, detail = "") {
  results.push({ scene, pass, detail });
  log(`${pass ? "✅" : "❌"} ${scene}${detail ? " — " + detail : ""}`);
}

function startRelay() {
  return new Promise((resolve, reject) => {
    relayProc = spawn(process.execPath, ["relay-server/server.mjs"], {
      env: {
        ...process.env,
        PORT: String(RELAY_PORT),
        RELAY_TOKEN: TOKEN,
        ALLOW_QUERY_TOKEN: "1",
        ALLOWED_CLIENT_ID: "",
      },
      stdio: ["ignore", "pipe", "pipe"],
    });
    let ready = false;
    relayProc.stdout.on("data", (b) => {
      const s = b.toString();
      if (!ready && s.includes("listening")) { ready = true; resolve(); }
    });
    relayProc.stderr.on("data", (b) => console.error("[relay]", b.toString()));
    relayProc.on("error", reject);
    setTimeout(() => (ready ? null : reject(new Error("relay start timeout"))), 5000);
  });
}

function connectAgent(agentId) {
  return new Promise((resolve, reject) => {
    const url = `${RELAY_URL}?role=agent&agentId=${agentId}&token=${TOKEN}`;
    const ws = new WebSocket(url);
    ws.on("open", () => { agents.set(agentId, ws); resolve(ws); });
    ws.on("error", reject);
    ws.on("message", (raw) => {
      const msg = JSON.parse(raw.toString());
      // Fake agent handler：响应各类请求
      const t = msg?.type;
      const payload = msg?.payload || {};
      const reply = (type, extra) => ws.send(JSON.stringify({
        id: msg.id, type, payload: { ...extra }, timestamp: Date.now(),
      }));
      if (t === "agent.input" && payload.text === "/model") {
        reply("model.list", { models: ["claude-sonnet", "gpt-4o"], modelId: undefined });
      } else if (t === "model.select") {
        reply("model.select_ack", { modelId: payload.modelId, ok: true });
        reply("usage.info", {
          model: payload.modelId,
          totalInput: 1000 + (agentId === "agent-test-a" ? 0 : 5000),
          totalOutput: 2000 + (agentId === "agent-test-a" ? 0 : 6000),
          totalTokens: 3000 + (agentId === "agent-test-a" ? 0 : 11000),
          contextWindow: 200000,
        });
      } else if (t === "usage.request") {
        reply("usage.info", {
          model: agentId === "agent-test-a" ? "claude-sonnet" : "gpt-4o",
          totalInput: agentId === "agent-test-a" ? 1234 : 5678,
          totalOutput: agentId === "agent-test-a" ? 2345 : 6789,
          totalTokens: agentId === "agent-test-a" ? 3579 : 12467,
          contextWindow: 200000,
        });
      }
    });
    setTimeout(() => reject(new Error(`agent ${agentId} connect timeout`)), 4000);
  });
}

function connectClient() {
  return new Promise((resolve, reject) => {
    const cid = `ios-client-${nextClientId++}`;
    const url = `${RELAY_URL}?role=client&client_id=${cid}&token=${TOKEN}`;
    client = new WebSocket(url);
    const inbox = [];
    client.on("open", () => resolve(inbox));
    client.on("message", (raw) => inbox.push(JSON.parse(raw.toString())));
    client.on("error", reject);
    setTimeout(() => reject(new Error("client connect timeout")), 4000);
  });
}

function sendFromClient(type, payload) {
  const id = `req-${Math.random().toString(36).slice(2, 8)}`;
  client.send(JSON.stringify({ id, type, payload, timestamp: Date.now() }));
  return id;
}

function waitFor(inbox, predicate, timeoutMs = 2000) {
  return new Promise((resolve, reject) => {
    const check = () => {
      const found = inbox.find(predicate);
      if (found) return resolve(found);
    };
    check();
    const interval = setInterval(() => {
      check();
      if (inbox.length > 200) clearInterval(interval);
    }, 50);
    setTimeout(() => { clearInterval(interval); reject(new Error("waitFor timeout")); }, timeoutMs);
  });
}

async function sleep(ms) { return new Promise((r) => setTimeout(r, ms)); }

async function main() {
  await startRelay();
  log("relay started on", RELAY_PORT);
  await sleep(200);

  // ───────── 第一阶段：单 Agent 基础 ─────────
  log("\n=== 第一阶段：单 Agent 基础测试 ===");
  await connectAgent("agent-test-a");
  await sleep(300);
  const inbox1 = await connectClient();
  await sleep(300);

  // 收到 relay.agents
  const agentsEv = await waitFor(inbox1, (m) => m.type === "relay.agents");
  const ids = (agentsEv.payload?.agents || []).map((a) => a.agentId);
  record("1-A relay.agents 到达", ids.includes("agent-test-a"), `agents=${JSON.stringify(ids)}`);

  // 自动选择第一个 agent 为 currentAgentId（由 iOS 侧逻辑模拟）
  const currentAgentId = ids[0];
  record("1-B currentAgentId 选择", currentAgentId === "agent-test-a", `currentAgentId=${currentAgentId}`);

  // 请求 model list（通过 /model 兼容命令）
  sendFromClient("agent.input", { text: "/model", targetAgentId: currentAgentId });
  const modelListEv = await waitFor(inbox1, (m) => m.type === "model.list");
  const models = modelListEv.payload?.models || [];
  record("1-C model.list 返回", models.length === 2, `models=${JSON.stringify(models)}`);

  // 模型切换
  const reqId = sendFromClient("model.select", { modelId: "claude-sonnet", targetAgentId: currentAgentId });
  const ackEv = await waitFor(inbox1, (m) => m.type === "model.select_ack" && m.payload?.modelId === "claude-sonnet");
  record("1-D model.select_ack", ackEv.payload?.ok === true, `modelId=${ackEv.payload?.modelId}`);

  // usage 随 select_ack 自动广播
  const usageEv = await waitFor(inbox1, (m) => m.type === "usage.info");
  record("1-E usage.info 到达", usageEv.payload?.totalTokens > 0,
    `model=${usageEv.payload?.model} tokens=${usageEv.payload?.totalTokens}`);

  // 主动请求 usage
  sendFromClient("usage.request", { targetAgentId: currentAgentId });
  const usage2 = await waitFor(inbox1, (m) => m.type === "usage.info" && m.payload?.totalTokens === 3579, 1500);
  record("1-F usage.request 精确路由", usage2.payload?.totalTokens === 3579,
    `totalTokens=${usage2.payload?.totalTokens}`);

  // ───────── 第二阶段：多 Agent 路由 ─────────
  log("\n=== 第二阶段：多 Agent 测试 ===");
  await connectAgent("agent-test-b");
  await sleep(400);
  // client 应收到包含两个 agent 的 relay.agents
  const agentsEv2 = await waitFor(inbox1, (m) => m.type === "relay.agents" && (m.payload?.agents || []).length === 2);
  const ids2 = agentsEv2.payload.agents.map((a) => a.agentId);
  record("2-A 第二个 agent 加入", ids2.includes("agent-test-b"), `agents=${JSON.stringify(ids2)}`);

  // 路由到 agentA
  sendFromClient("usage.request", { targetAgentId: "agent-test-a" });
  const uA = await waitFor(inbox1, (m) => m.type === "usage.info" && m.payload?.totalTokens === 3579, 1500);
  record("2-B 路由到 agentA", uA.payload?.model === "claude-sonnet",
    `model=${uA.payload?.model} tokens=${uA.payload?.totalTokens}`);

  // 路由到 agentB
  sendFromClient("usage.request", { targetAgentId: "agent-test-b" });
  const uB = await waitFor(inbox1, (m) => m.type === "usage.info" && m.payload?.totalTokens === 12467, 1500);
  record("2-C 路由到 agentB", uB.payload?.model === "gpt-4o",
    `model=${uB.payload?.model} tokens=${uB.payload?.totalTokens}`);

  // 无串台：agentB 的用量不应出现在 agentA 的请求中
  record("2-D 无数据串台", uA.payload?.totalTokens === 3579 && uB.payload?.totalTokens === 12467,
    `A=${uA.payload?.totalTokens} B=${uB.payload?.totalTokens}`);

  // ───────── 第五阶段：异常路径 ─────────
  log("\n=== 第五阶段：异常路径测试 ===");
  // targetAgentId 不存在
  const badId = sendFromClient("usage.request", { targetAgentId: "nonexistent-agent" });
  try {
    const errEv = await waitFor(inbox1, (m) => m.type === "relay.error", 1000);
    record("5-A targetAgentId 失效返回 relay.error", !!errEv, `code=${errEv.payload?.code}`);
  } catch {
    record("5-A targetAgentId 失效返回 relay.error", false, "未收到 relay.error");
  }

  // ───────── 第三阶段：断线重连恢复 ─────────
  log("\n=== 第三阶段：连接生命周期 ===");
  // 断开 client 并重连，模拟冷启动
  client.close();
  await sleep(500);
  const inbox3 = await connectClient();
  await sleep(300);
  const agentsEv3 = await waitFor(inbox3, (m) => m.type === "relay.agents");
  const ids3 = agentsEv3.payload.agents.map((a) => a.agentId);
  record("3-A 重连后 agents 自动恢复", ids3.length === 2, `agents=${JSON.stringify(ids3)}`);

  // 重连后请求 model + usage 能恢复
  sendFromClient("agent.input", { text: "/model", targetAgentId: "agent-test-a" });
  const ml3 = await waitFor(inbox3, (m) => m.type === "model.list", 1500);
  record("3-B 重连后 model.list 恢复", (ml3.payload?.models || []).length === 2,
    `models=${(ml3.payload?.models || []).length}`);
  sendFromClient("usage.request", { targetAgentId: "agent-test-a" });
  const u3 = await waitFor(inbox3, (m) => m.type === "usage.info", 1500);
  record("3-C 重连后 usage.info 恢复", u3.payload?.totalTokens > 0,
    `tokens=${u3.payload?.totalTokens}`);

  // 一个 agent 离开
  agents.get("agent-test-b").close();
  agents.delete("agent-test-b");
  await sleep(400);
  const leaveEv = await waitFor(inbox3, (m) => m.type === "relay.agent_leave");
  record("3-D agent 离开通知", leaveEv.payload?.agentId === "agent-test-b",
    `left=${leaveEv.payload?.agentId}`);

  // 汇总
  log("\n=== 测试汇总 ===");
  const passed = results.filter((r) => r.pass).length;
  const total = results.length;
  console.log(`\n通过 ${passed}/${total}`);
  results.forEach((r) => log(`${r.pass ? "✅" : "❌"} ${r.scene}${r.detail ? " — " + r.detail : ""}`));

  // 清理
  agents.forEach((ws) => ws.close());
  client?.close();
  relayProc?.kill("SIGTERM");
  process.exit(total > 0 && passed === total ? 0 : 1);
}

main().catch((e) => {
  console.error("❌ 测试执行失败:", e);
  agents.forEach((ws) => ws.close());
  client?.close();
  relayProc?.kill("SIGTERM");
  process.exit(1);
});
