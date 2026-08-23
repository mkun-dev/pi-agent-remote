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
  private heartbeatTimer: ReturnType<typeof setInterval> | null = null;
  private stopped = false;
  private opened = false;  // 区分连接阶段错误 vs 运行中抖动
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
      this.opened = true;
      this.onStatusChange?.(true);
      // 心跳保活：每 30s 发一个 ping，防止 NAT/防火墙清理空闲连接
      // （偶发 socket hang up 的根因就是中间设备悄悄丢弃了空闲 TCP）
      this.heartbeatTimer = setInterval(() => {
        if (this.ws === ws && ws.readyState === WebSocket.OPEN) {
          try { ws.ping(); } catch { /* 连接已断，等 close 回调清理 */ }
        }
      }, 30_000);
    });

    ws.on("message", (data) => {
      const text = data.toString();
      this.onMessage?.(text);
    });

    ws.on("close", () => {
      // 防止 Old socket 的 close 事件覆盖新连接（close → reconnect 时竞态）
      if (this.ws !== ws) return;
      this.ws = null;
      this.opened = false;
      if (this.heartbeatTimer) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = null; }
      this.onStatusChange?.(false);
      this.scheduleReconnect();
    });

    ws.on("error", (err) => {
      // 连接阶段错误（从未 open 过）= 服务端不可达，标红；
      // 运行中错误（已经 open 过）= 网络抖动 / NAT 清理，偶发且有自动重连兑底，降级为 warn。
      if (this.opened) {
        console.warn(`⚠️ 中继网络抖动（将自动重连）: ${err.message}`);
      } else {
        console.error(`❌ 中继连接失败: ${err.message}`);
      }
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
    if (this.heartbeatTimer) { clearInterval(this.heartbeatTimer); this.heartbeatTimer = null; }
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
