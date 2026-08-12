import { WebSocket } from "ws";

/** agent（PC 窗口）注册信息 */
export type AgentMeta = {
  agentId: string;   // 会话标识（sessionId）
  name?: string | null;
  cwd?: string | null;
  model?: string | null;
};

/**
 * RelayClient — 反向连接中继服务器（NAT 穿透，Phase 3）
 * 角色: agent（PC 扩展），把 Pi 事件转发到中继 → iOS
 * 多窗口：连接时携带 agentId + 元信息，中继据此区分并展示多个窗口
 */
export class RelayClient {
  private ws: WebSocket | null = null;
  private url: string;
  private token: string;
  private agentMeta: AgentMeta | null = null;
  private reconnectTimer: ReturnType<typeof setTimeout> | null = null;
  private stopped = false;
  private onMessage?: (data: string) => void;
  private onStatusChange?: (connected: boolean) => void;

  constructor(url: string, token: string) {
    this.url = url;
    this.token = token;
  }

  /** 收到中继转发的 iOS 消息（agent.input / session.resume 等） */
  public setOnMessage(cb: (data: string) => void): void {
    this.onMessage = cb;
  }

  /** 连接状态变化（用于日志/UI） */
  public setOnStatusChange(cb: (connected: boolean) => void): void {
    this.onStatusChange = cb;
  }

  /** 连接中继：agentId = 当前会话 ID，元信息供 iOS 端窗口列表展示 */
  public connect(meta?: AgentMeta): void {
    if (meta) this.agentMeta = meta;
    // session 切换后重新允许连接（close 只清理当前连接，不永久禁用）
    this.stopped = false;
    if (this.ws) return;

    const endpoint = new URL(this.url);
    endpoint.searchParams.set("role", "agent");
    endpoint.searchParams.delete("token");
    if (this.agentMeta?.agentId) endpoint.searchParams.set("agentId", this.agentMeta.agentId);
    if (this.agentMeta?.name) endpoint.searchParams.set("name", this.agentMeta.name);
    if (this.agentMeta?.cwd) endpoint.searchParams.set("cwd", this.agentMeta.cwd);
    if (this.agentMeta?.model) endpoint.searchParams.set("model", this.agentMeta.model);

    // Token 只放 Authorization Header，避免进入 URL/代理访问日志。
    const ws = new WebSocket(endpoint, {
      headers: { Authorization: `Bearer ${this.token}` },
      maxPayload: 20 * 1024 * 1024,
      perMessageDeflate: false
    });
    this.ws = ws;

    ws.on("open", () => {
      this.onStatusChange?.(true);
    });

    ws.on("message", (data) => {
      const text = data.toString();
      this.onMessage?.(text);
    });

    ws.on("close", () => {
      // 防止 Old socket 的 close 事件覆盖新连接（close → reconnect 时竞态）
      if (this.ws !== ws) return;
      this.ws = null;
      this.onStatusChange?.(false);
      this.scheduleReconnect();
    });

    ws.on("error", (err) => {
      console.error(`❌ 中继连接错误: ${err.message}`);
    });
  }

  /** 发送消息到中继（会转发给 iOS） */
  public send(event: unknown): void {
    if (this.ws && this.ws.readyState === WebSocket.OPEN) {
      this.ws.send(JSON.stringify(event));
    }
  }

  public isConnected(): boolean {
    return this.ws?.readyState === WebSocket.OPEN;
  }

  public close(): void {
    // stopped 用于阻止 close 回调触发重连；connect() 会重置，session 切换后仍可重连
    this.stopped = true;
    if (this.reconnectTimer) clearTimeout(this.reconnectTimer);
    this.reconnectTimer = null;
    if (this.ws) {
      try {
        this.ws.close();
      } catch {
        // ignore
      }
      this.ws = null;
    }
  }

  private scheduleReconnect(): void {
    if (this.stopped || this.reconnectTimer) return;
    this.reconnectTimer = setTimeout(() => {
      this.reconnectTimer = null;
      this.connect();
    }, 5000);
  }
}
