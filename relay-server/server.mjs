// =====================================================
// pi-ios Relay Server — 单租户 NAT 中继
// 安全边界：共享 RELAY_TOKEN；可选 RELAY_CLIENT_ID 绑定唯一 iOS 设备。
// 公网部署应由 Caddy/Nginx 等终止 TLS，对外只暴露 wss://。
// =====================================================
import { timingSafeEqual } from "node:crypto";
import { WebSocketServer, WebSocket } from "ws";

const TOKEN = String(process.env.RELAY_TOKEN || "").trim();
const ALLOWED_CLIENT_ID = String(process.env.RELAY_CLIENT_ID || "").trim();
const ALLOW_QUERY_TOKEN = process.env.ALLOW_QUERY_TOKEN !== "0"; // 仅兼容旧客户端
const PORT = parseInt(process.env.PORT || "3002", 10);
const MAX_PAYLOAD_BYTES = parseInt(process.env.MAX_PAYLOAD_BYTES || String(20 * 1024 * 1024), 10);
const HEARTBEAT_INTERVAL = 30_000;
const ROLE_AGENT = "agent";
const ROLE_CLIENT = "client";

if (!TOKEN || TOKEN === "CHANGE_ME_32_HEX") {
  console.error("❌ 未设置有效 RELAY_TOKEN，Relay 拒绝启动");
  process.exit(1);
}
if (TOKEN.length < 24) {
  console.error("❌ RELAY_TOKEN 过短，至少需要 24 个字符");
  process.exit(1);
}

const wss = new WebSocketServer({
  port: PORT,
  maxPayload: MAX_PAYLOAD_BYTES,
  perMessageDeflate: false,
});

// 同一个 Token 是一个个人安全域：其下可包含多个 Pi 窗口/Session。
const agents = new Map();
const agentMeta = new Map();
let client = null;
let connectedClientId = null;
let currentTargetAgentId = null;
let agentSeq = 0;

function log(msg) {
  console.log(`[${new Date().toISOString()}] ${msg}`);
}

function safeSend(ws, obj) {
  if (ws && ws.readyState === WebSocket.OPEN) {
    ws.send(JSON.stringify(obj));
  }
}

function tokenMatches(candidate) {
  const expected = Buffer.from(TOKEN, "utf8");
  const actual = Buffer.from(String(candidate || ""), "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

function requestToken(req, url) {
  const authorization = String(req.headers.authorization || "");
  const match = authorization.match(/^Bearer\s+(.+)$/i);
  if (match) return match[1].trim();
  return ALLOW_QUERY_TOKEN ? (url.searchParams.get("token") || "") : "";
}

function validIdentifier(value) {
  return typeof value === "string" && /^[a-zA-Z0-9._:-]{8,128}$/.test(value);
}

function agentList() {
  const list = [];
  for (const [id, ws] of agents) {
    list.push({
      agentId: id,
      online: ws.readyState === WebSocket.OPEN,
      ...(agentMeta.get(id) || {}),
    });
  }
  return list;
}

function syncCurrentTargetAgent() {
  if (currentTargetAgentId && agents.has(currentTargetAgentId)) return;
  currentTargetAgentId = agents.keys().next().value ?? null;
}

function pushAgentList() {
  syncCurrentTargetAgent();
  safeSend(client, { type: "relay.agents", payload: { agents: agentList() } });
}

function pushAgentJoin(agentId) {
  const meta = agentMeta.get(agentId) || {};
  safeSend(client, {
    type: "relay.agent_join",
    payload: { agent: { agentId, ...meta } },
  });
}

function pushAgentLeave(agentId) {
  safeSend(client, { type: "relay.agent_leave", payload: { agentId } });
}

function notifyAgentStatus() {
  safeSend(client, {
    type: "relay.status",
    payload: { status: agents.size > 0 ? "agent_online" : "agent_offline" },
  });
}

const heartbeatTimer = setInterval(() => {
  wss.clients.forEach((ws) => {
    if (!ws.isAlive) {
      log(`💀 心跳超时，关闭连接 (${ws.remoteAddr || "unknown"})`);
      ws.terminate();
      return;
    }
    ws.isAlive = false;
    ws.ping();
  });
}, HEARTBEAT_INTERVAL);

wss.on("close", () => clearInterval(heartbeatTimer));

wss.on("connection", (ws, req) => {
  ws.isAlive = true;
  ws.remoteAddr = req.socket.remoteAddress;
  ws.on("pong", () => { ws.isAlive = true; });

  const url = new URL(req.url, "http://localhost");
  const role = url.searchParams.get("role") || "";
  const providedToken = requestToken(req, url);

  if (!tokenMatches(providedToken)) {
    log(`❌ 拒绝连接: 认证失败 (${ws.remoteAddr})`);
    ws.close(4001, "authentication failed");
    return;
  }

  if (role === ROLE_AGENT) {
    const requestedAgentId = url.searchParams.get("agentId");
    const agentId = validIdentifier(requestedAgentId)
      ? requestedAgentId
      : `agent-${++agentSeq}`;
    const name = url.searchParams.get("name") || null;
    const cwd = url.searchParams.get("cwd") || null;
    const model = url.searchParams.get("model") || null;

    const old = agents.get(agentId);
    if (old && old.readyState === WebSocket.OPEN) {
      log(`⚠️  agent "${agentId}" 重连，关闭旧连接`);
      old.close(4000, "agent reconnected");
    }

    agents.set(agentId, ws);
    agentMeta.set(agentId, { name, cwd, model });
    log(`✅ agent (${agentId}) 已认证，共 ${agents.size} 个窗口`);
    notifyAgentStatus();
    pushAgentJoin(agentId);
    pushAgentList();

    ws.on("message", (data) => {
      syncCurrentTargetAgent();
      if (agentId !== currentTargetAgentId) return;
      if (client && client.readyState === WebSocket.OPEN) {
        client.send(data.toString());
      }
    });
    ws.on("close", (code) => {
      if (agents.get(agentId) === ws) {
        agents.delete(agentId);
        agentMeta.delete(agentId);
        log(`🔌 agent (${agentId}) 已断开 (code=${code})，剩余 ${agents.size} 个`);
        pushAgentLeave(agentId);
        syncCurrentTargetAgent();
        notifyAgentStatus();
      }
    });
  } else if (role === ROLE_CLIENT) {
    const requestedClientId = url.searchParams.get("client_id") || url.searchParams.get("clientId") || "";
    // 仅在显式开启旧 URL Token 且未配置设备绑定时兼容旧 iOS；新客户端始终发送 UUID。
    const clientId = requestedClientId || (
      ALLOW_QUERY_TOKEN && !ALLOWED_CLIENT_ID && url.searchParams.has("token")
        ? "legacy-client"
        : ""
    );
    if (!validIdentifier(clientId)) {
      log(`❌ 拒绝 client: client_id 无效 (${ws.remoteAddr})`);
      ws.close(4003, "invalid client id");
      return;
    }
    if (ALLOWED_CLIENT_ID && clientId !== ALLOWED_CLIENT_ID) {
      log(`❌ 拒绝 client: 设备未绑定 (${ws.remoteAddr})`);
      ws.close(4003, "client not allowed");
      return;
    }
    if (client && client.readyState === WebSocket.OPEN) {
      if (connectedClientId !== clientId) {
        log(`❌ 拒绝 client: 已有其他设备在线 (${ws.remoteAddr})`);
        ws.close(4004, "another client is connected");
        return;
      }
      log(`⚠️  client (${clientId.slice(0, 8)}) 重连，关闭旧连接`);
      client.close(4000, "client reconnected");
    }

    client = ws;
    connectedClientId = clientId;
    syncCurrentTargetAgent();
    ws.messageWindowStartedAt = Date.now();
    ws.messageCount = 0;
    log(`✅ client (${clientId.slice(0, 8)}) 已认证`);
    pushAgentList();
    notifyAgentStatus();

    ws.on("message", (data) => {
      const now = Date.now();
      if (now - ws.messageWindowStartedAt > 10_000) {
        ws.messageWindowStartedAt = now;
        ws.messageCount = 0;
      }
      ws.messageCount += 1;
      if (ws.messageCount > 200) {
        log(`❌ client 消息速率异常，关闭连接 (${clientId.slice(0, 8)})`);
        ws.close(4008, "rate limit exceeded");
        return;
      }

      let msg;
      try {
        msg = JSON.parse(data.toString());
      } catch {
        log(`⚠️  client 发送了无效 JSON (${data.length} bytes)`);
        return;
      }

      const msgId = msg?.id;
      const targetAgentId = msg?.payload?.targetAgentId;
      let target = null;
      if (targetAgentId) {
        target = agents.get(targetAgentId);
        if (!target || target.readyState !== WebSocket.OPEN) {
          safeSend(ws, { type: "relay.error", payload: { id: msgId ?? null, code: "agent_offline" } });
          return;
        }
        currentTargetAgentId = targetAgentId;
      } else if (agents.size > 0) {
        syncCurrentTargetAgent();
        target = currentTargetAgentId ? agents.get(currentTargetAgentId) : null;
      }

      if (target && target.readyState === WebSocket.OPEN) {
        target.send(data.toString());
        if (msgId) safeSend(ws, { type: "relay.ack", payload: { id: msgId } });
      } else {
        safeSend(ws, { type: "relay.error", payload: { id: msgId ?? null, code: "agent_offline" } });
      }
    });
    ws.on("close", (code) => {
      if (client === ws) {
        client = null;
        connectedClientId = null;
        currentTargetAgentId = null;
        log(`🔌 client (${clientId.slice(0, 8)}) 已断开 (code=${code})`);
      }
    });
  } else {
    log(`❌ 拒绝连接: 未知 role (${ws.remoteAddr})`);
    ws.close(4002, "invalid role");
  }

  ws.on("error", (error) => log(`⚠️  ws 错误: ${error.message}`));
});

wss.on("listening", () => {
  log(`🚀 pi-ios relay listening on ws://0.0.0.0:${PORT}（公网请通过反向代理暴露 wss://）`);
  if (ALLOW_QUERY_TOKEN) {
    log("⚠️  兼容旧版 URL Token；确认所有客户端升级后设置 ALLOW_QUERY_TOKEN=0");
  }
  if (ALLOWED_CLIENT_ID) {
    log(`🔒 已绑定 iOS client_id: ${ALLOWED_CLIENT_ID.slice(0, 8)}…`);
  }
});

wss.on("error", (error) => {
  console.error("❌ WebSocket server error:", error.message);
  process.exit(1);
});
