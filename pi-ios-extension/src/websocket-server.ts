import { timingSafeEqual } from "node:crypto";
import { WebSocket, WebSocketServer } from "ws";

/**
 * pi-ios 局域网 WebSocket 服务器。
 * 与 Relay 复用同一个共享 Token；未配置 Token 时不开放端口。
 */
export class WebSocketServerManager {
  private wss: WebSocketServer | null = null;
  private clients: Set<WebSocket> = new Set();
  private activeClientId: string | null = null;
  private onClientMessage?: (ws: WebSocket, text: string) => void;
  private port: number;

  constructor(port = 3001) {
    this.port = port;
  }

  public start(authToken: string, onError?: (err: Error) => void): void {
    if (this.wss) return;
    const token = authToken.trim();
    if (token.length < 24) {
      console.error("❌ 本地 WebSocket 未启动：请配置至少 24 字符的 Token");
      return;
    }

    this.wss = new WebSocketServer({
      port: this.port,
      maxPayload: 20 * 1024 * 1024,
      perMessageDeflate: false
    });

    this.wss.on("connection", (ws: WebSocket, req) => {
      const url = new URL(req.url ?? "/", "http://localhost");
      const authorization = String(req.headers.authorization ?? "");
      const bearer = authorization.match(/^Bearer\s+(.+)$/i)?.[1]?.trim() ?? "";
      const allowQueryToken = process.env.PI_IOS_ALLOW_QUERY_TOKEN !== "0";
      const queryToken = allowQueryToken ? (url.searchParams.get("token") ?? "") : "";
      const provided = bearer || queryToken; // query 仅兼容旧 iOS
      const requestedClientId = url.searchParams.get("client_id") ?? url.searchParams.get("clientId") ?? "";
      const clientId = requestedClientId || (queryToken ? "legacy-client" : "");

      if (!secureEqual(token, provided)) {
        console.warn("❌ 拒绝本地 WebSocket：认证失败");
        ws.close(4001, "authentication failed");
        return;
      }
      if (!/^[a-zA-Z0-9._:-]{8,128}$/.test(clientId)) {
        console.warn("❌ 拒绝本地 WebSocket：client_id 无效");
        ws.close(4003, "invalid client id");
        return;
      }
      if (this.clients.size > 0 && this.activeClientId !== clientId) {
        console.warn("❌ 拒绝本地 WebSocket：已有其他设备在线");
        ws.close(4004, "another client is connected");
        return;
      }
      // 同一设备重连时替换旧 socket；不同设备不能读取当前 Session。
      this.clients.forEach((client) => {
        client.close(4000, "client reconnected");
        this.clients.delete(client);
      });
      this.activeClientId = clientId;
      this.clients.add(ws);
      ws.on("message", (data: Buffer | string) => {
        this.onClientMessage?.(ws, data.toString());
      });
      ws.on("close", () => {
        this.clients.delete(ws);
        if (this.clients.size === 0) this.activeClientId = null;
      });
      ws.on("error", (err) => console.error("WS client error:", err.message));
    });

    this.wss.on("error", (err) => {
      if ((err as any).code === "EADDRINUSE") {
        console.error(`❌ 端口 ${this.port} 已被占用！`);
        console.error("   原因: 另一个 Pi 实例或程序正在使用该端口。");
      } else {
        console.error("WebSocket server error:", err.message);
      }
      this.wss = null;
      onError?.(err);
    });
  }

  public setOnClientMessage(callback: (ws: WebSocket, text: string) => void): void {
    this.onClientMessage = callback;
  }

  public hasClients(): boolean {
    return this.clients.size > 0;
  }

  public sendTo(ws: WebSocket, event: unknown): void {
    if (ws.readyState === WebSocket.OPEN) {
      ws.send(JSON.stringify(event));
    }
  }

  public broadcast(event: unknown): void {
    if (this.clients.size === 0) return;
    const message = JSON.stringify(event);
    this.clients.forEach((client) => {
      if (client.readyState === WebSocket.OPEN) {
        client.send(message);
      }
    });
  }

  public close(): void {
    this.clients.forEach((client) => client.close(1001, "server shutdown"));
    this.clients.clear();
    this.activeClientId = null;
    if (this.wss) {
      try {
        this.wss.close();
      } catch {
        // ignore
      }
      this.wss = null;
    }
  }
}

function secureEqual(expectedValue: string, actualValue: string): boolean {
  const expected = Buffer.from(expectedValue, "utf8");
  const actual = Buffer.from(actualValue, "utf8");
  return expected.length === actual.length && timingSafeEqual(expected, actual);
}

export const wsServer = new WebSocketServerManager(3001);
