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
