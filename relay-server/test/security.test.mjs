import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import net from "node:net";
import { once } from "node:events";
import { test } from "node:test";
import { WebSocket } from "ws";

const VALID_TOKEN = "0123456789abcdef0123456789abcdef";

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

async function startRelay(extraEnv = {}) {
  const port = await freePort();
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, PORT: String(port), RELAY_TOKEN: VALID_TOKEN, ...extraEnv },
    stdio: ["ignore", "pipe", "pipe"]
  });
  let output = "";
  child.stdout.on("data", (chunk) => { output += chunk.toString(); });
  child.stderr.on("data", (chunk) => { output += chunk.toString(); });
  const deadline = Date.now() + 5_000;
  while (!output.includes("relay listening")) {
    if (child.exitCode !== null) throw new Error(`Relay exited early: ${output}`);
    if (Date.now() > deadline) throw new Error(`Relay start timeout: ${output}`);
    await new Promise((resolve) => setTimeout(resolve, 25));
  }
  return { child, port };
}

async function closeCode(url, headers = {}) {
  const socket = new WebSocket(url, { headers });
  const [code] = await once(socket, "close");
  return code;
}

async function openSocket(url, headers) {
  const socket = new WebSocket(url, { headers });
  await once(socket, "open");
  return socket;
}

function stopRelay(child) {
  if (child.exitCode === null) child.kill();
}

test("未配置 Token 时 Relay 拒绝启动", async () => {
  const port = await freePort();
  const child = spawn(process.execPath, ["server.mjs"], {
    cwd: new URL("..", import.meta.url),
    env: { ...process.env, PORT: String(port), RELAY_TOKEN: "" },
    stdio: ["ignore", "pipe", "pipe"]
  });
  const [code] = await once(child, "exit");
  assert.equal(code, 1);
});

test("无 Token、错误 Token 被拒绝，正确 Token 可正常转发", async () => {
  const { child, port } = await startRelay({ ALLOW_QUERY_TOKEN: "0" });
  const base = `ws://127.0.0.1:${port}`;
  try {
    assert.equal(
      await closeCode(`${base}/?role=client&client_id=client-test-01`),
      4001
    );
    assert.equal(
      await closeCode(`${base}/?role=client&client_id=client-test-01`, { Authorization: "Bearer wrong-token" }),
      4001
    );

    const auth = { Authorization: `Bearer ${VALID_TOKEN}` };
    const agent = await openSocket(`${base}/?role=agent&agentId=win-agent-01`, auth);
    const client = await openSocket(`${base}/?role=client&client_id=client-test-01`, auth);

    const receivedByAgent = new Promise((resolve) => {
      agent.on("message", (data) => resolve(JSON.parse(data.toString())));
    });
    const ack = new Promise((resolve) => {
      client.on("message", (data) => {
        const message = JSON.parse(data.toString());
        if (message.type === "relay.ack") resolve(message);
      });
    });
    client.send(JSON.stringify({
      id: "message-1",
      type: "agent.input",
      payload: { text: "hello", targetAgentId: "win-agent-01" }
    }));

    assert.equal((await receivedByAgent).type, "agent.input");
    assert.equal((await ack).payload.id, "message-1");
    client.close();
    agent.close();
  } finally {
    stopRelay(child);
  }
});

test("仅转发当前目标窗口的事件，避免多窗口串流", async () => {
  const { child, port } = await startRelay({ ALLOW_QUERY_TOKEN: "0" });
  const base = `ws://127.0.0.1:${port}`;
  const auth = { Authorization: `Bearer ${VALID_TOKEN}` };
  try {
    const agentA = await openSocket(`${base}/?role=agent&agentId=win-agent-01`, auth);
    const agentB = await openSocket(`${base}/?role=agent&agentId=win-agent-02`, auth);
    const client = await openSocket(`${base}/?role=client&client_id=client-test-01`, auth);

    const received = [];
    client.on("message", (data) => {
      const message = JSON.parse(data.toString());
      if (message.type === "relay.ack" || message.type?.startsWith("relay.")) return;
      received.push(message);
    });

    client.send(JSON.stringify({
      id: "choose-agent-b",
      type: "usage.request",
      payload: { targetAgentId: "win-agent-02" }
    }));
    await new Promise((resolve) => setTimeout(resolve, 60));

    agentA.send(JSON.stringify({ type: "agent.status", payload: { status: "thinking" } }));
    agentB.send(JSON.stringify({ type: "agent.status", payload: { status: "completed" } }));
    await new Promise((resolve) => setTimeout(resolve, 120));

    assert.equal(received.length, 1);
    assert.equal(received[0].payload.status, "completed");

    client.close();
    agentA.close();
    agentB.close();
  } finally {
    stopRelay(child);
  }
});

test("多窗口下缺省 target 返回 ambiguous_target，禁止猜测（B2）", async () => {
  const { child, port } = await startRelay({ ALLOW_QUERY_TOKEN: "0" });
  const base = `ws://127.0.0.1:${port}`;
  const auth = { Authorization: `Bearer ${VALID_TOKEN}` };
  try {
    const agentA = await openSocket(`${base}/?role=agent&agentId=win-agent-01`, auth);
    const agentB = await openSocket(`${base}/?role=agent&agentId=win-agent-02`, auth);
    const client = await openSocket(`${base}/?role=client&client_id=client-test-01`, auth);

    const agentAReceived = [];
    agentA.on("message", (data) => agentAReceived.push(JSON.parse(data.toString())));
    const agentBReceived = [];
    agentB.on("message", (data) => agentBReceived.push(JSON.parse(data.toString())));
    const clientErrors = [];
    client.on("message", (data) => {
      const msg = JSON.parse(data.toString());
      if (msg.type === "relay.error") clientErrors.push(msg);
    });

    // 两 Agent 在线，请求未指定 targetAgentId → 必须 ambiguous_target，绝不进入任一 Agent。
    client.send(JSON.stringify({ id: "no-target-1", type: "workspace.list", payload: { path: "" } }));
    client.send(JSON.stringify({ id: "no-target-2", type: "model.request", payload: {} }));
    client.send(JSON.stringify({ id: "no-target-3", type: "usage.request", payload: {} }));
    client.send(JSON.stringify({ id: "no-target-4", type: "session.list", payload: {} }));
    await new Promise((resolve) => setTimeout(resolve, 120));

    assert.equal(clientErrors.length, 4);
    for (const err of clientErrors) {
      assert.equal(err.payload.code, "ambiguous_target");
    }
    assert.equal(agentAReceived.length, 0);
    assert.equal(agentBReceived.length, 0);

    // 单窗口场景应保留 fallback（兼容单窗口模式）。
    agentB.close();
    await new Promise((resolve) => setTimeout(resolve, 60));
    clientErrors.length = 0;
    client.send(JSON.stringify({ id: "no-target-single", type: "workspace.list", payload: { path: "" } }));
    await new Promise((resolve) => setTimeout(resolve, 80));
    // 单窗口下允许路由给唯一 Agent，不返回 ambiguous_target。
    assert.equal(clientErrors.length, 0);
    assert.ok(agentAReceived.length >= 1, "单窗口应保留无歧义 fallback");

    client.close();
    agentA.close();
  } finally {
    stopRelay(child);
  }
});

test("relay.agents 按名称稳定排序，窗口集合相同时顺序一致（B4）", async () => {
  const { child, port } = await startRelay({ ALLOW_QUERY_TOKEN: "0" });
  const base = `ws://127.0.0.1:${port}`;
  const auth = { Authorization: `Bearer ${VALID_TOKEN}` };
  try {
    const client = await openSocket(`${base}/?role=client&client_id=client-test-01`, auth);

    const captureAgents = () => new Promise((resolve) => {
      const once = (handler) => {
        client.once("message", (data) => {
          const msg = JSON.parse(data.toString());
          if (msg.type === "relay.agents") handler(msg.payload.agents.map((a) => a.agentId));
          else once(handler);
        });
      };
      once(resolve);
    });

    // 故意逆序上线：zeta / alpha / middle
    await openSocket(`${base}/?role=agent&agentId=win-zeta&name=zeta`, auth);
    let first = await captureAgents();
    await openSocket(`${base}/?role=agent&agentId=win-alpha&name=alpha`, auth);
    let second = await captureAgents();
    await openSocket(`${base}/?role=agent&agentId=win-middle&name=middle`, auth);
    let third = await captureAgents();

    // 无论上线顺序，输出都应按 name 字母序稳定。
    assert.deepEqual(second, ["win-alpha", "win-zeta"], `got ${JSON.stringify(second)}`);
    assert.deepEqual(third, ["win-alpha", "win-middle", "win-zeta"], `got ${JSON.stringify(third)}`);

    client.close();
  } finally {
    stopRelay(child);
  }
});

test("可选 RELAY_CLIENT_ID 会拒绝未绑定设备", async () => {
  const { child, port } = await startRelay({
    ALLOW_QUERY_TOKEN: "0",
    RELAY_CLIENT_ID: "allowed-client-01"
  });
  try {
    const code = await closeCode(
      `ws://127.0.0.1:${port}/?role=client&client_id=other-client-01`,
      { Authorization: `Bearer ${VALID_TOKEN}` }
    );
    assert.equal(code, 4003);
  } finally {
    stopRelay(child);
  }
});
