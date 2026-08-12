import assert from "node:assert/strict";
import { once } from "node:events";
import net from "node:net";
import { test } from "node:test";
import { WebSocket } from "ws";
// @ts-ignore Node 22 测试运行器直接执行 erasable TypeScript。
import { WebSocketServerManager } from "../src/websocket-server.ts";

const TOKEN = "abcdef0123456789abcdef0123456789";

async function freePort(): Promise<number> {
  const server = net.createServer();
  server.listen(0, "127.0.0.1");
  await once(server, "listening");
  const address = server.address();
  const port = typeof address === "object" && address ? address.port : 0;
  server.close();
  await once(server, "close");
  return port;
}

async function rejectedCode(url: string, headers: Record<string, string> = {}): Promise<number> {
  const socket = new WebSocket(url, { headers });
  const [code] = await once(socket, "close") as [number];
  return code;
}

test("局域网 WebSocket 拒绝无 Token 和错误 Token", async () => {
  const port = await freePort();
  const manager = new WebSocketServerManager(port);
  manager.start(TOKEN);
  await new Promise((resolve) => setTimeout(resolve, 30));
  try {
    const url = `ws://127.0.0.1:${port}/?client_id=local-client-01`;
    assert.equal(await rejectedCode(url), 4001);
    assert.equal(await rejectedCode(url, { Authorization: "Bearer wrong" }), 4001);
  } finally {
    manager.close();
  }
});

test("局域网 WebSocket 接受正确 Token 与 client_id", async () => {
  const port = await freePort();
  const manager = new WebSocketServerManager(port);
  manager.start(TOKEN);
  await new Promise((resolve) => setTimeout(resolve, 30));
  try {
    const socket = new WebSocket(`ws://127.0.0.1:${port}/?client_id=local-client-01`, {
      headers: { Authorization: `Bearer ${TOKEN}` }
    });
    await once(socket, "open");
    assert.equal(manager.hasClients(), true);
    assert.equal(
      await rejectedCode(`ws://127.0.0.1:${port}/?client_id=other-client-01`, {
        Authorization: `Bearer ${TOKEN}`
      }),
      4004
    );
    socket.close();
    await once(socket, "close");
  } finally {
    manager.close();
  }
});
