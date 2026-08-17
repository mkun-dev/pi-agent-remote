import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";
import { SessionManager } from "@earendil-works/pi-coding-agent";
import type { WebSocket } from "ws";
import { randomUUID } from "node:crypto";
import { readFileSync, existsSync, writeFileSync, mkdirSync, rmSync, statSync, readdirSync } from "node:fs";
import { injectFileContext } from "./file-context.js";
import { readWorkspaceFilePayload } from "./workspace-file.js";
import { cp } from "node:fs/promises";
import { homedir } from "node:os";
import { join, resolve, relative, basename, sep, isAbsolute } from "node:path";
import { wsServer } from "./websocket-server.js";
import { ProtocolHandler, withScope } from "./protocol.js";
import { RelayClient } from "./relay-client.js";
import { countPatchChanges, countTextLines, extractFilePath, isFileMutationTool } from "./file-change-utils.js";
import { buildHistory } from "./session-history.js";
import { saveUploadedImage } from "./media-upload.js";
import { addUsage, maxUsage, summarizeBranchUsage, zeroUsageAccumulator, shouldSkipDuplicateTurnEnd, type UsageAccumulator } from "./usage-accumulator.js";
import type { SessionInfo, SessionListItem, ProtocolMessage } from "./types.js";

/**
 * 读取中继配置，优先级:
 *   1. 环境变量 RELAY_URL / RELAY_TOKEN / PI_IOS_TOKEN
 *   2. ~/.pi/pi-ios-relay.json（推荐，token 不进仓库）
 *   3. 项目内 config.json
 * 同一 Token 同时用于 Relay 和局域网 WebSocket，不创建第二套认证。
 */
function loadRelayConfig(): { url: string | null; token: string | null } {
  const environmentUrl = process.env.RELAY_URL ?? null;
  const environmentToken = process.env.RELAY_TOKEN ?? process.env.PI_IOS_TOKEN ?? null;
  if (environmentToken) return { url: environmentUrl, token: environmentToken };

  const candidates = [
    join(homedir(), ".pi", "pi-ios-relay.json"),
    join(process.cwd(), "config.json")
  ];
  for (const path of candidates) {
    try {
      if (existsSync(path)) {
        const cfg = JSON.parse(readFileSync(path, "utf8"));
        const url = cfg.relayUrl ?? cfg.url ?? null;
        const token = cfg.relayToken ?? cfg.localToken ?? cfg.token ?? null;
        if (token) return { url, token };
      }
    } catch (e) {
      console.error(`❌ 读取配置失败 ${path}:`, e);
    }
  }
  return { url: null, token: null };
}

function writeSecureConfig(path: string, value: Record<string, string>): void {
  mkdirSync(join(homedir(), ".pi"), { recursive: true });
  writeFileSync(path, JSON.stringify(value, null, 2), { encoding: "utf8", mode: 0o600 });
}

export default function (pi: ExtensionAPI) {

  // ================= NAT 穿透（Phase 3）：中继模式 =================
  // 配置优先级: 环境变量 > ~/.pi/pi-ios-relay.json > ./config.json
  const relayCfg = loadRelayConfig();
  let relay: RelayClient | null = null;
  if (relayCfg.url && relayCfg.token) {
    relay = new RelayClient(relayCfg.url, relayCfg.token);
  } else {
  }

  // ================= Session 管理（Phase 3） =================
  let sessionProvider: (() => SessionInfo) | null = null;
  
  function currentEventScope() {
    const info = sessionProvider?.();
    return {
      agentId: windowAgentId,
      sessionId: info?.sessionId ?? null,
      sessionFile: info?.sessionFile ?? null
    };
  }
  
  function scopeEvent<T extends ProtocolMessage>(event: T): T {
    return withScope(event, currentEventScope());
  }
  
  // 统一广播：本地 WS 客户端 + 中继（iOS）
  function broadcast(event: unknown): void {
    const scoped = (event && typeof event === "object" && "type" in (event as Record<string, unknown>) && "payload" in (event as Record<string, unknown>))
      ? scopeEvent(event as ProtocolMessage)
      : event;
    wsServer.broadcast(scoped);
    relay?.send(scoped);
  }

  // ================= 模型与用量统计 =================
  let usageAcc: UsageAccumulator = zeroUsageAccumulator();
  let usageSessionKey: string | null = null;
  // 最近一次 turn_end 的 messageId（N2：防止同 turn 重复触发导致 usage 翻倍）
  let lastTurnEndMessageId: string | null = null;
  // 最近一次已知模型（ctx.model 在非 turn 期间可能为 undefined）
  let lastModel: string | null = null;

  function currentUsageSessionKey(ctx: any = sessionCtx): string | null {
    const sessionId = String(ctx?.sessionManager?.getSessionId?.() ?? sessionProvider?.()?.sessionId ?? "").trim();
    if (sessionId) return `id:${sessionId}`;
    const sessionFile = String(ctx?.sessionManager?.getSessionFile?.() ?? sessionProvider?.()?.sessionFile ?? "").trim();
    return sessionFile ? `file:${sessionFile}` : null;
  }
  
  function resetUsageAccumulator(sessionKey: string | null = currentUsageSessionKey()): void {
    usageAcc = zeroUsageAccumulator();
    usageSessionKey = sessionKey;
    lastTurnEndMessageId = null;
  }
  
  // 从会话历史累计用量（与 hud-footer 同法：provider 流式不报 usage，但历史消息有真实值）
  function accumulateFromSession(): void {
    try {
      const branch = sessionManagerRef?.getBranch?.();
      if (!branch || !Array.isArray(branch)) return;
      const sessionKey = currentUsageSessionKey();
      const sameSession = !!sessionKey && sessionKey == usageSessionKey;
      const inMemory = sameSession ? usageAcc : zeroUsageAccumulator();
      const summary = summarizeBranchUsage(branch);
      usageAcc = sameSession ? maxUsage(summary.usage, inMemory) : summary.usage;
      usageSessionKey = sessionKey;
      if (!lastModel && summary.discoveredModel) {
        lastModel = summary.discoveredModel;
      }
    } catch { /* 会话未就绪时忽略 */ }
  }

  function accumulateUsage(u: any): void {
    usageAcc = addUsage(usageAcc, u);
    usageSessionKey = currentUsageSessionKey();
  }

  function buildUsageInfo(recalculateFromSession = true, generation?: number): ProtocolMessage {
    // 请求/恢复时从会话历史重算；turn_end/agent_end 则保留刚刚累计的 provider usage，
    // 避免 session manager 尚未落盘当前消息时把最新增量覆盖掉。
    if (recalculateFromSession) accumulateFromSession();
    // 运行时模型优先于历史消息中的“最近使用模型”。
    const model = sessionCtx?.model?.id ?? lastModel ?? null;
    const ctxUsage = sessionCtx?.getContextUsage?.();
    return ProtocolHandler.createUsageInfo({
      model,
      contextTokens: ctxUsage?.tokens ?? null,
      contextWindow: ctxUsage?.contextWindow ?? 0,
      contextPercent: ctxUsage?.percent ?? null,
      totalInput: usageAcc.input,
      totalOutput: usageAcc.output,
      totalCacheRead: usageAcc.cacheRead,
      totalCacheWrite: usageAcc.cacheWrite,
      totalReasoning: usageAcc.reasoning,
      totalTokens: usageAcc.totalTokens,
      totalCost: usageAcc.cost
    }, generation);
  }

  async function resolveAvailableModels(): Promise<any[]> {
    if (sessionCtx?.scopedModels?.length) {
      return sessionCtx.scopedModels.map((s: any) => s.model);
    }
    if (sessionCtx?.modelRegistry) {
      return (await sessionCtx.modelRegistry.getAvailable?.()) ?? [];
    }
    return [];
  }

  function broadcastUsageInfo(recalculateFromSession = true, generation?: number): void {
    try {
      const usage = buildUsageInfo(recalculateFromSession, generation);
      broadcast(usage);
    } catch (e) {
      console.error("❌ usage.info 广播失败:", e);
    }
  }

  async function handleUsageRequest(msg: any, respond: (event: unknown) => void): Promise<void> {
    const generation = typeof msg?.payload?.generation === "number" ? msg.payload.generation : undefined;
    try {
      respond(buildUsageInfo(true, generation));
    } catch (e) {
      console.error("❌ usage.request failed:", e);
      respond(ProtocolHandler.createUsageInfo({
        model: null, contextTokens: null, contextWindow: 0, contextPercent: null,
        totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
        totalReasoning: 0, totalTokens: 0, totalCost: 0
      }, generation));
    }
  }
  // Phase 3.5: 会话管理器引用（供 session.resume 时提取对话历史）
  let sessionManagerRef: any = null;
  // Phase 4: 命令上下文（供 session.list / session.switch）
  let sessionCtx: any = null;
  // Phase 4: 窗口稳定 ID（进程生命周期不变；切会话不改变 agentId，iOS 目标不变）
  const windowAgentId = `win-${randomUUID().slice(0, 8)}`;

  // iOS 问卷答案缓存：toolCallId → answers（供 tool_result 替换）
  const iosAnswersCache = new Map<string, any[]>();
  // 问卷消息 ID ↔ toolCallId 映射
  const questionnaireToToolCall = new Map<string, string>();
  // 待处理问卷（iOS 断开重连后同步重发）
  let pendingQuestionnaire: ProtocolMessage | null = null;

  // ================= iOS → Pi: 统一消息处理 =================
  let agentBusy = false;
  // before_agent_start → agent_start 兜底：极端情况下 agent_start 未触发时，
  // receiving 状态会卡住；定时器负责收口回 idle（#5）。
  let receivingFallbackTimer: ReturnType<typeof setTimeout> | null = null;
  let awaitingAgentStart = false;

  // ─── 消息排队（飞书式：Pi 忙时排队，空闲时处理） ───
  const pendingQueue: { text: string; respond: (event: unknown) => void }[] = [];
  let queueFlushTimer: ReturnType<typeof setTimeout> | null = null;
  let ctxRef: any = null;  // 供 abort/compact 使用
  // Steer（打断重发）：abort 后挂起的消息，agent_end 时优先发出（不走队列）（P3）
  let pendingInterruptSend: { text: string; respond: (event: unknown) => void } | null = null;

  /** 入队并尝试处理 */
  function enqueueText(text: string, respond: (event: unknown) => void): void {
    pendingQueue.push({ text, respond });
    // 通知 iOS 已排队
    respond(ProtocolHandler.createAgentOutput(`📥 已排队 (前面还有 ${pendingQueue.length - 1} 条)`, "message"));
    void flushQueue();
  }

  /** 空闲时处理队列下一条 */
  async function flushQueue(): Promise<void> {
    if (agentBusy || pendingQueue.length === 0) return;
    const item = pendingQueue.shift()!;
    try {
      pi.sendUserMessage(item.text);
    } catch (e) {
      console.error("❌ sendUserMessage failed:", e);
    }
  }

  /** Steer：中断当前 turn，挂起重发；agent_end 后优先发出（P3）。 */
  function interruptAndSend(text: string, respond: (event: unknown) => void): void {
    pendingInterruptSend = { text, respond };
    pendingQueue.length = 0;  // 打断时清掉旧队列，避免歧义
    try {
      if (ctxRef && !ctxRef.isIdle?.()) {
        ctxRef.abort?.();
        respond(ProtocolHandler.createAgentOutput("⏭️ 已打断当前任务，即将发送新消息", "message"));
      } else {
        // 已经空闲：直接发
        pendingInterruptSend = null;
        try { pi.sendUserMessage(text); }
        catch (e) { console.error("❌ steer sendUserMessage failed:", e); }
      }
    } catch (e) {
      pendingInterruptSend = null;
      respond(ProtocolHandler.createAgentOutput(`❌ 打断失败: ${e}`, "message"));
    }
  }

  /** agent 空闲后触发队列刷新（延迟，等完全空闲） */
  function scheduleFlush(): void {
    if (queueFlushTimer) clearTimeout(queueFlushTimer);
    queueFlushTimer = setTimeout(() => void flushQueue(), 800);
  }

  /**
   * 构建当前 Agent 状态消息（供 iOS 重连/恢复后同步）。
   * 只读 agentBusy + activeToolStatuses，不产生副作用。
   */
  function buildCurrentAgentStatus(): ProtocolMessage {
    if (agentBusy) {
      const running = Array.from(activeToolStatuses.values()).pop();
      if (running) {
        return ProtocolHandler.createStatus("using_tool", {
          tool: running.tool,
          description: running.description
        });
      }
      return ProtocolHandler.createStatus("thinking", {
        description: "Pi 正在处理"
      });
    }
    return ProtocolHandler.createStatus("idle");
  }

  /**
   * Relay agent 重连后主动恢复客户端快照。
   * 仅依赖 iOS 主动重连是不够的：如果只有 PC→Relay 断线，iOS 连接仍在，
   * 断线期间的 assistant 事件会丢失，客户端不会再次发送 session.resume。
   */
  function sendRelaySnapshot(): void {
    if (!relay?.isConnected() || !sessionProvider) return;
    const info = sessionProvider();
    relay.send(scopeEvent(ProtocolHandler.createSessionInfo(info)));
    if (sessionManagerRef) {
      relay.send(scopeEvent(ProtocolHandler.createSessionHistory(
        buildHistory(sessionManagerRef),
        info.sessionId
      )));
    }
    relay.send(scopeEvent(buildUsageInfo()));
    relay.send(scopeEvent(buildCurrentAgentStatus()));
    if (pendingQuestionnaire) relay.send(scopeEvent(pendingQuestionnaire));
  }

  relay?.setOnStatusChange((connected) => {
    if (connected) sendRelaySnapshot();
  });

  function handleClientMessage(text: string, respond: (event: unknown) => void): void {
    const emit = (event: unknown): void => {
      if (event && typeof event === "object" && "type" in (event as Record<string, unknown>) && "payload" in (event as Record<string, unknown>)) {
        respond(scopeEvent(event as ProtocolMessage));
      } else {
        respond(event);
      }
    };
    let msg: any;
    try {
      msg = JSON.parse(text);
    } catch (e) {
      console.error("❌ 消息解析失败:", text.slice(0, 80));
      return;
    }

    if (msg?.type === "agent.input") {
      const t = msg.payload?.text;
      if (typeof t === "string" && t.trim()) {
        const trimmed = t.trim();
        // 拦截 /model 命令：iOS 端切换模型（不发给 LLM）
        if (trimmed.startsWith("/model")) {
          void handleModelCommand(trimmed, emit);
          return;
        }
        // 拦截 /ios-config 命令：iOS 端查看中继配置
        if (trimmed.startsWith("/ios-config")) {
          void handleIosConfig(emit);
          return;
        }
        // 拦截飞书式控制命令：/new /stop /queue /compact /status
        if (handleControlCommand(trimmed, emit)) {
          return;
        }
        // 附带 Workspace 文件上下文（来自 iOS「询问Agent」）：在消息前注入路径块，让 Agent 知道用户在问哪个文件。
        const finalText = injectFileContext(trimmed, msg.payload?.context);
        // Steer（P3）：打断当前 turn 并作为新 turn 发送，不排队
        if (msg.payload?.steer === true) {
          interruptAndSend(finalText, emit);
          return;
        }
        // 转发给 Pi Agent（Pi 忙时排队，飞书式）
        if (agentBusy) {
          enqueueText(finalText, emit);
        } else {
          try {
            pi.sendUserMessage(finalText);
          } catch (e) {
            console.error("❌ sendUserMessage failed:", e);
          }
        }
      } else {
        console.warn("⚠️ Empty agent.input ignored");
      }
    } else if (msg?.type === "session.resume") {
      if (sessionProvider) {
        const info = sessionProvider();
        emit(ProtocolHandler.createSessionInfo(info));
        // Phase 3.5: 随 session.info 一起回放对话历史
        if (sessionManagerRef) {
          const history = buildHistory(sessionManagerRef);
          // 空历史也必须发送，iOS 才能在切换到空会话时清除旧快照。
          emit(ProtocolHandler.createSessionHistory(history, info.sessionId));
        }
        // 重连/恢复后同步当前 Agent 状态，避免 iOS 断线重连后显示"就绪"
        emit(buildCurrentAgentStatus());
      }
    } else if (msg?.type === "session.list") {
      void handleSessionList(emit);
    } else if (msg?.type === "session.switch") {
      const path = msg.payload?.sessionFile;
      if (typeof path === "string") {
        void handleSessionSwitch(path, emit);
      }
    } else if (msg?.type === "usage.request") {
      void handleUsageRequest(msg, emit);
    } else if (msg?.type === "model.request") {
      void handleModelRequest(msg, emit);
    } else if (msg?.type === "model.select") {
      void handleModelSelect(msg, emit);
    } else if (msg?.type === "questionnaire.answer") {
      handleQuestionnaireAnswer(msg, emit);
      // 缓存 iOS 答案（供 tool_result 替换使用）
      const qid = msg?.id;
      if (qid && msg?.payload?.answers && questionnaireToToolCall.has(qid)) {
        const toolCallId = questionnaireToToolCall.get(qid)!;
        iosAnswersCache.set(toolCallId, msg.payload.answers);
        questionnaireToToolCall.delete(qid);
        if (pendingQuestionnaire?.id === qid) pendingQuestionnaire = null;  // 已回答，清除缓存
        // 自动跳过终端 TUI：注入 Esc 取消弹窗（触发 tool_result → 替换为 iOS 答案）。
        // 注意：依赖 Pi 内部监听 stdin 的问卷实现，属于脆弱方案；非 TTY 环境可能失效。
        // 即使失效，iOS 答案仍会通过 iosAnswersCache 在 tool_result 时替换，仅终端可能仍弹出。
        try {
          process.stdin.push("\x1b");
          console.warn("⚠️ 已注入 Esc 跳过终端问卷（依赖 stdin，非 TTY 环境可能失效）");
        } catch (e) {
          console.warn("⚠️ stdin 注入失败，终端问卷可能仍显示（iOS 答案已缓存将替换）:", e);
        }
      }
    } else if (msg?.type === "questionnaire.sync") {
      // iOS 重连后同步：重发待处理问卷
      if (pendingQuestionnaire) {
        broadcast(pendingQuestionnaire);
      }
    } else if (msg?.type === "media.upload") {
      // iOS → PC：保存上传的图片/文件
      void handleMediaUpload(msg, emit);
    } else if (msg?.type === "workspace.list") {
      void handleWorkspaceList(msg, emit);
    } else if (msg?.type === "workspace.readFile") {
      void handleWorkspaceReadFile(msg, emit);
    } else if (msg?.type === "workspace.search") {
      void handleWorkspaceSearch(msg, emit);
    } else if (msg?.type === "message.rewind") {
      handleRewind(msg, emit);
    } else {
    }
  }

  /**
   * /model 命令：列出/切换模型（iOS 端远程控制）
   * 用法: /model            列出可用模型
   *       /model <关键词>    切换匹配的模型
   */
  async function handleModelCommand(cmd: string, respond: (event: unknown) => void): Promise<void> {
    const reply = (text: string) => respond(ProtocolHandler.createAgentOutput(text, "message"));
    try {
      const parts = cmd.trim().split(/\s+/);
      const query = (parts[1] ?? "").toLowerCase();

      // 获取可用模型列表
      const models = await resolveAvailableModels();

      if (models.length === 0) {
        reply("❌ 无法获取模型列表");
        return;
      }

      const modelId = (m: any) => m?.id ?? m?.modelId ?? String(m);

      if (!query) {
        // 发送模型列表（iOS 端弹出选择器）
        const ids = models.map((m: any) => modelId(m));

        respond(ProtocolHandler.createModelList(ids));
        return;
      }

      // 查找匹配模型
      const target = models.find((m) => modelId(m).toLowerCase().includes(query));
      if (!target) {
        reply(`❌ 未找到包含 "${parts[1]}" 的模型`);
        return;
      }
      const targetId = modelId(target);
      const ok = await pi.setModel(target);
      if (ok) {
        lastModel = targetId;
        reply(`✅ 已切换到模型: **${targetId}**`);
        broadcastUsageInfo();
      } else {
        reply(`❌ 切换模型失败: ${targetId}`);
      }
    } catch (e) {
      console.error("❌ /model 处理失败:", e);
      reply(`❌ /model 执行出错: ${e}`);
    }
  }

  async function handleModelRequest(msg: any, respond: (event: unknown) => void): Promise<void> {
    const generation = typeof msg?.payload?.generation === "number" ? msg.payload.generation : undefined;
    const models = await resolveAvailableModels();
    const modelId = (m: any) => m?.id ?? m?.modelId ?? String(m);
    const ids = models.map((m: any) => modelId(m));

    respond(ProtocolHandler.createModelList(ids, generation));
  }

  /** iOS 端模型选择器回调：切换模型 */
  async function handleModelSelect(msg: any, respond: (event: unknown) => void): Promise<void> {
    const modelId = msg?.payload?.modelId;
    const selectionRequestId = typeof msg?.payload?.selectionRequestId === "string" ? msg.payload.selectionRequestId : undefined;
    if (!modelId || typeof modelId !== "string") {
      respond(ProtocolHandler.createModelSelectAck("", false, "❌ 未指定模型", selectionRequestId));
      return;
    }
    try {
      const models = await resolveAvailableModels();
      const resolveId = (m: any) => m?.id ?? m?.modelId ?? String(m);
      const target = models.find((m) => resolveId(m) === modelId);
      if (!target) {
        respond(ProtocolHandler.createModelSelectAck(modelId, false, `❌ 未找到模型: ${modelId}`, selectionRequestId));
        return;
      }
      const ok = await pi.setModel(target);
      if (ok) {
        lastModel = modelId;

        respond(ProtocolHandler.createModelSelectAck(modelId, true, undefined, selectionRequestId));
        broadcastUsageInfo();
      } else {

        respond(ProtocolHandler.createModelSelectAck(modelId, false, undefined, selectionRequestId));
      }
    } catch (e) {
      console.error("❌ model.select 失败:", e);
      respond(ProtocolHandler.createModelSelectAck(modelId, false, `❌ 切换出错: ${e}`, selectionRequestId));
    }
  }

  /** iOS 端查看中继配置 */
  async function handleIosConfig(respond: (event: unknown) => void): Promise<void> {
    const reply = (text: string) => respond(ProtocolHandler.createAgentOutput(text, "message"));
    try {
      const cfgPath = join(homedir(), ".pi", "pi-ios-relay.json");
      const lines: string[] = [];
      if (existsSync(cfgPath)) {
        const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
        const token = String(cfg.relayToken ?? cfg.localToken ?? "");
        const masked = token.length > 8 ? `${token.slice(0, 4)}...${token.slice(-4)}` : "***";
        lines.push(`📡 中继: ${cfg.relayUrl ?? "未启用（安全局域网模式）"}`);
        lines.push(`🔑 Token: ${masked}`);
      } else {
        lines.push("📡 未配置：Relay 与局域网 WebSocket 均不会接受连接");
      }
      lines.push(`🔌 连接: ${relay ? (relay.isConnected() ? "✅ 已连接" : "❌ 未连接") : "未启用"}`);
      lines.push(`📱 iOS 客户端: ${wsServer.hasClients() ? "在线" : "无"}`);
      const name = pi.getSessionName?.() ?? null;
      lines.push(`📋 会话: ${name ?? "（未命名）"}`);
      lines.push(`🪟 窗口: ${windowAgentId}`);
      reply(lines.join("\n"));
    } catch (e) {
      reply(`❌ 读取配置失败: ${e}`);
    }
  }

  /** 飞书式控制命令：/new /stop /queue /compact /status。返回 true 表示已处理 */
  function handleControlCommand(trimmed: string, respond: (event: unknown) => void): boolean {
    const reply = (text: string) => respond(ProtocolHandler.createAgentOutput(text, "message"));
    const parts = trimmed.split(/\s+/);
    const cmd = (parts[0] ?? "").toLowerCase();

    switch (cmd) {
      case "/new": {
        // 重置会话：清空队列 + 中断 + 压缩上下文
        pendingQueue.length = 0;
        try {
          if (ctxRef && !ctxRef.isIdle?.()) ctxRef.abort?.();
          if (ctxRef) ctxRef.compact?.();
          reply("✅ 会话已重置，上下文已清空。");
        } catch (e) {
          reply(`❌ 重置失败: ${e}`);
        }
        return true;
      }
      case "/stop": {
        // 中断当前处理 + 清空队列
        const cleared = pendingQueue.length;
        pendingQueue.length = 0;
        try {
          if (ctxRef && !ctxRef.isIdle?.()) {
            ctxRef.abort?.();
            reply("⏹ 已中断当前处理，队列已清空。");
          } else if (cleared > 0) {
            reply(`✅ 已清空 ${cleared} 条排队消息。`);
          } else {
            reply("当前没有正在处理的任务。");
          }
        } catch (e) {
          reply(`❌ 中断失败: ${e}`);
        }
        return true;
      }
      case "/queue": {
        const count = pendingQueue.length;
        reply(`状态: ${agentBusy ? "处理中" : "空闲"}\n排队中: ${count} 条消息`);
        return true;
      }
      case "/compact": {
        try {
          if (ctxRef) ctxRef.compact?.();
          reply("✅ 已触发上下文压缩。");
        } catch (e) {
          reply(`❌ 压缩失败: ${e}`);
        }
        return true;
      }
      case "/status": {
        try {
          const ctxUsage = ctxRef?.getContextUsage?.();
          let r = `🖥 Pi 状态:\n- 连接: ${agentBusy ? "处理中" : "空闲"}\n- 排队: ${pendingQueue.length} 条`;
          if (ctxUsage && ctxUsage.tokens !== null) {
            r += `\n- 上下文: ${ctxUsage.tokens}/${ctxUsage.contextWindow} tokens (${ctxUsage.percent ?? "?"}%)`;
          }
          reply(r);
        } catch {
          reply("🖥 Pi 状态查询失败");
        }
        return true;
      }
      default:
        return false;
    }
  }

  /** iOS → PC：图片固定保存到当前项目 pi-ios-uploads，客户端路径和文件名不参与落盘。 */
  async function handleMediaUpload(msg: any, respond: (event: unknown) => void): Promise<void> {
    const reply = (text: string) => respond(ProtocolHandler.createAgentOutput(text, "message"));
    try {
      const base64 = String(msg?.payload?.base64 ?? "");
      const requestedDir = String(msg?.payload?.dir ?? "pi-ios-uploads").trim();
      // 仅允许简单目录名（防止路径穿越）；非法或缺失时回退默认目录（#8）
      const dirName = /^[a-zA-Z0-9._-]+$/.test(requestedDir) ? requestedDir : "pi-ios-uploads";
      const uploadRoot = resolve(sessionCtx?.cwd ?? process.cwd(), dirName);
      const saved = saveUploadedImage(base64, uploadRoot);
      reply(`📁 已保存: ${saved.path}`);
      broadcast(ProtocolHandler.createFileChange(saved.path, "created"));
    } catch (error) {
      const reason = error instanceof Error ? error.message : "未知错误";
      reply(`❌ 保存失败: ${reason}`);
    }
  }

  // ================= Workspace Explorer（Phase 5） =================
  // 只读浏览：列出目录树 + 读取文件内容。不提供写入/编辑。
  const WORKSPACE_MAX_TEXT_BYTES = 2 * 1024 * 1024; // 文本 2MB 上限
  const WORKSPACE_MAX_IMAGE_BYTES = 8 * 1024 * 1024; // 图片 8MB 上限（点击后懒加载）
  const WORKSPACE_MAX_ENTRIES = 500;                 // 单目录最多返回条目
  const WORKSPACE_SEARCH_MAX_DIRS = 500;             // 搜索最多扫描目录数
  const WORKSPACE_SEARCH_MAX_HITS = 200;             // 搜索最多返回结果数
  const WORKSPACE_IGNORE = new Set([
    "node_modules", ".git", ".svn", ".hg", "dist", "build",
    "DerivedData", "Pods", ".build", "__pycache__",
    ".venv", "venv", ".next", ".nuxt", "coverage", "pi-ios-uploads"
  ]);

  /** 项目根（规范化为 resolve 结果，避免尾部分隔符 / 大小写差异导致切片错位）。 */
  function workspaceRoot(): string {
    return resolve(sessionCtx?.cwd ?? process.cwd());
  }

  /** 把任意相对路径统一成正斜杠、无前缀的形式（跨平台一致 key）。 */
  function normalizeWorkspacePath(p: string): string {
    return p.split(sep).join("/").replace(/^\.?\/+/, "");
  }

  /** 将相对路径规范化并限定在项目根内，防止目录穿越。返回绝对路径或 null。 */
  function resolveWorkspacePath(relPath: string | undefined): string | null {
    const root = workspaceRoot();
    const cleaned = normalizeWorkspacePath(String(relPath ?? ""));
    if (!cleaned || cleaned === ".") return root;
    const abs = resolve(root, cleaned);
    // 优先用大小写不敏感的 startsWith 判断（Windows 盘符 / 路径大小写不一致时
    // node 的 relative 可能误判），再用 relative 兜底处理符号链接等特殊情况。
    const absNorm = abs.replace(/\\/g, "/").toLowerCase();
    const rootNorm = root.replace(/\\/g, "/").toLowerCase();
    if (absNorm === rootNorm || absNorm.startsWith(rootNorm + "/")) {
      return abs;
    }
    const rel = relative(root, abs);
    if (rel.startsWith("..") || isAbsolute(rel)) return null;
    return abs;
  }

  /** 读取目录（懒加载一层），返回 WorkspaceNode[]。path 统一正斜杠、相对项目根。 */
  function readWorkspaceDir(absPath: string): { nodes: any[]; name: string } {
    const root = workspaceRoot();
    const entries = readdirSync(absPath, { withFileTypes: true });
    const nodes: any[] = [];
    for (const entry of entries) {
      if (WORKSPACE_IGNORE.has(entry.name)) continue;
      if (entry.name.startsWith(".")) continue; // 隐藏文件不展示
      if (nodes.length >= WORKSPACE_MAX_ENTRIES) break;
      // 用 path.relative 正确处理跨平台分隔符，避免手动 slice 错位
      const rel = normalizeWorkspacePath(relative(root, resolve(absPath, entry.name)));
      nodes.push({
        name: entry.name,
        path: rel,
        type: entry.isDirectory() ? "directory" : "file"
      });
    }
    // 目录在前，文件在后，各自按名称排序
    nodes.sort((a, b) => {
      if (a.type !== b.type) return a.type === "directory" ? -1 : 1;
      return a.name.localeCompare(b.name);
    });
    return { nodes, name: basename(absPath) };
  }

  /** workspace.list → 返回当前目录的 children（懒加载，不嵌套深层）。 */
  async function handleWorkspaceList(msg: any, respond: (event: unknown) => void): Promise<void> {
    const rawPayloadPath = msg?.payload?.path;
    const root = workspaceRoot();
  
    try {
      const requestPath = normalizeWorkspacePath(String(rawPayloadPath ?? ""));
      const abs = resolveWorkspacePath(requestPath);
      if (!abs) {
        const root = workspaceRoot();
        console.error(`[workspace] list 拒绝: rawPath=${JSON.stringify(msg?.payload?.path)} cleaned=${JSON.stringify(requestPath)} root=${JSON.stringify(root)}`);
        respond(ProtocolHandler.createWorkspaceError(requestPath, `路径超出项目范围 (root=${root})`));
        return;
      }
      const stat = statSync(abs);
      if (!stat.isDirectory()) {
        respond(ProtocolHandler.createWorkspaceError(requestPath, "不是目录"));
        return;
      }
      const { nodes, name } = readWorkspaceDir(abs);
    
      // 回传规范化后的 path 作为 key，确保 iOS 查找与展开一致
      respond(ProtocolHandler.createWorkspaceTree(requestPath, name, nodes));
    } catch (error) {
      const reason = error instanceof Error ? error.message : "未知错误";
      respond(ProtocolHandler.createWorkspaceError(msg?.payload?.path, reason));
    }
  }

  /** workspace.readFile → 读取文件内容（大小受限）。 */
  async function handleWorkspaceReadFile(msg: any, respond: (event: unknown) => void): Promise<void> {
    try {
      const requestPath = normalizeWorkspacePath(String(msg?.payload?.path ?? ""));
      const abs = resolveWorkspacePath(requestPath);
      if (!abs) {
        const root = workspaceRoot();
        console.error(`[workspace] readFile 拒绝: rawPath=${JSON.stringify(msg?.payload?.path)} cleaned=${JSON.stringify(requestPath)} root=${JSON.stringify(root)}`);
        respond(ProtocolHandler.createWorkspaceError(requestPath, `路径超出项目范围 (root=${root})`));
        return;
      }
      const stat = statSync(abs);
      if (!stat.isFile()) {
        respond(ProtocolHandler.createWorkspaceError(requestPath, "不是文件"));
        return;
      }
      const file = readWorkspaceFilePayload(abs, requestPath, stat.size, {
        maxTextBytes: WORKSPACE_MAX_TEXT_BYTES,
        maxImageBytes: WORKSPACE_MAX_IMAGE_BYTES,
      });
    
      respond(ProtocolHandler.createWorkspaceFile(file));
    } catch (error) {
      const reason = error instanceof Error ? error.message : "未知错误";
      respond(ProtocolHandler.createWorkspaceError(normalizeWorkspacePath(String(msg?.payload?.path ?? "")), reason));
    }
  }

  /**
   * workspace.search → 全项目递归按文件名模糊匹配。
   * 复用 readWorkspaceDir 的忽略规则（WORKSPACE_IGNORE + 隐藏文件），保证搜索范围与浏览一致。
   * 限制：最多扫描 WORKSPACE_SEARCH_MAX_DIRS 个目录、返回 WORKSPACE_SEARCH_MAX_HITS 条结果，
   * 防止超大项目阻塞。
   */
  async function handleWorkspaceSearch(msg: any, respond: (event: unknown) => void): Promise<void> {
    const rawQuery = String(msg?.payload?.query ?? "").trim();
    try {
      if (!rawQuery) {
        respond(ProtocolHandler.createWorkspaceSearchResult(rawQuery, []));
        return;
      }
      const root = workspaceRoot();
      const lower = rawQuery.toLowerCase();
      const hits: { path: string; filename: string; type: "file" | "directory" }[] = [];
      let visitedDirs = 0;
      // BFS 逐层扫描，优先返回浅层匹配
      const queue: string[] = [root];
      const seen = new Set<string>();
      while (queue.length > 0 && visitedDirs < WORKSPACE_SEARCH_MAX_DIRS && hits.length < WORKSPACE_SEARCH_MAX_HITS) {
        const current = queue.shift()!;
        const currentKey = resolve(current);
        if (seen.has(currentKey)) continue;
        seen.add(currentKey);
        visitedDirs++;
        let entries: import("fs").Dirent[];
        try {
          entries = readdirSync(current, { withFileTypes: true });
        } catch { continue; }
        for (const entry of entries) {
          if (WORKSPACE_IGNORE.has(entry.name)) continue;
          if (entry.name.startsWith(".")) continue;
          const absChild = resolve(current, entry.name);
          const rel = normalizeWorkspacePath(relative(root, absChild));
          const isDir = entry.isDirectory();
          // 文件名匹配优先（用户输入更可能是片段），完整路径匹配兜底
          if (entry.name.toLowerCase().includes(lower) || rel.toLowerCase().includes(lower)) {
            hits.push({ path: rel, filename: entry.name, type: isDir ? "directory" : "file" });
            if (hits.length >= WORKSPACE_SEARCH_MAX_HITS) break;
          }
          if (isDir) queue.push(absChild);
        }
      }
      // 文件优先于目录，浅层优先于深层（path 短在前）
      hits.sort((a, b) => {
        if (a.type !== b.type) return a.type === "file" ? -1 : 1;
        if (a.path.length !== b.path.length) return a.path.length - b.path.length;
        return a.filename.localeCompare(b.filename);
      });
    
      respond(ProtocolHandler.createWorkspaceSearchResult(rawQuery, hits));
    } catch (error) {
      const reason = error instanceof Error ? error.message : "未知错误";
      console.error("[workspace] search 失败:", reason);
      respond(ProtocolHandler.createWorkspaceSearchResult(rawQuery, []));
    }
  }

  /** iOS 端问卷回答 → tool_result 将替换终端答案 */
  function handleQuestionnaireAnswer(msg: any, respond: (event: unknown) => void): void {
    respond(ProtocolHandler.createAgentOutput("✅ 问卷已提交，终端按 Enter 继续", "message"));
  }

  /**
   * P4 git 式撤回：把 session leaf 移到“倒数第 N 条用户消息”之前，
   * 之后用户重发消息即形成新分支，旧消息与后续回复从 LLM 上下文消失。
   *
   * 约束：必须在 Agent 空闲时进行；Pi 运行时 sessionManager 为完整对象
   * （类型声明是只读，实际 runner 内部存的是可写 SessionManager），用 as any 调用。
   */
  function handleRewind(msg: any, respond: (event: unknown) => void): void {
    const reply = (text: string) => respond(ProtocolHandler.createAgentOutput(text, "message"));
    // 忙时拒绝：处理中动 session 结构会损坏状态
    if (agentBusy) {
      reply("⏳ Agent 处理中，无法撤回，请等它空闲后再试");
      return;
    }
    const nFromEnd = Number(msg?.payload?.userMessageIndexFromEnd ?? 0);
    if (!Number.isInteger(nFromEnd) || nFromEnd < 1) {
      reply("❌ 无效的撤回位置");
      return;
    }
    const sm = sessionManagerRef as any;
    if (!sm || typeof sm.getBranch !== "function" || typeof sm.branch !== "function") {
      reply("❌ 会话未就绪，无法撤回");
      return;
    }
    let branch: any[];
    try {
      branch = sm.getBranch();
    } catch (e) {
      reply(`❌ 读取会话失败: ${e}`);
      return;
    }
    // 只允许编辑“文本用户消息”；和 iOS 端 Message(kind: .text, sender: .user) 的计数保持一致。
    const userEntries = branch.filter(
      (e: any) => e?.type === "message"
        && e?.message?.role === "user"
        && typeof e?.message?.content === "string"
    );
    if (nFromEnd > userEntries.length) {
      reply(`❌ 没有那么早的用户消息（仅有 ${userEntries.length} 条）`);
      return;
    }
    const target = userEntries[userEntries.length - nFromEnd];
    const parentId = target?.parentId ?? null;
    const targetContent = typeof target?.message?.content === "string"
      ? target.message.content
      : "";
    try {
      if (parentId === null) {
        if (typeof sm.resetLeaf === "function") sm.resetLeaf();
        else throw new Error("sessionManager.resetLeaf 不可用");
      } else {
        sm.branch(parentId);  // leaf 移到目标之前；下次 append 即新分支
      }
    } catch (e) {
      reply(`❌ 撤回失败: ${e}`);
      return;
    }
    // git 式撤回后，旧内存队列也必须一起丢弃；否则会把已撤回路径上的消息重新补发到新分支。
    pendingQueue.length = 0;
    pendingInterruptSend = null;
    if (queueFlushTimer) {
      clearTimeout(queueFlushTimer);
      queueFlushTimer = null;
    }
    // 手动 branch 不会自动刷新我们缓存的 session info；补一条 session.update 让 iOS 元数据同步。
    if (sessionProvider) {
      const current = sessionProvider();
      const nextInfo = {
        ...current,
        leafId: sm.getLeafId?.() ?? null,
        entryCount: sm.getEntries?.()?.length ?? current.entryCount,
        reason: "rewind"
      };
      sessionProvider = () => nextInfo;
      broadcast(ProtocolHandler.createSessionUpdate("rewind", nextInfo));
    }
    // 本地用量缓存随历史变化失效，重算（重算后新分支可能更小）
    resetUsageAccumulator(currentUsageSessionKey());
    const removed = nFromEnd;  // 语义：撤回目标及其后的全部用户消息（含目标）
    // 先广播新分支的完整历史，让 iOS 用现有 applyHistory() 全量重建消息/日志/活动。
    if (sessionManagerRef) {
      const info = sessionProvider?.();
      broadcast(scopeEvent(ProtocolHandler.createSessionHistory(
        buildHistory(sessionManagerRef),
        info?.sessionId ?? null
      )));
    }
    // 再发一条轻量控制事件：只负责把原消息文本回填到输入框。
    broadcast(scopeEvent(ProtocolHandler.createHistoryRewound(targetContent, removed)));
    reply(`↩️ 已撤回最近 ${removed} 条用户消息，输入框已回填，编辑后发送即生效`);
    // 同步刷新用量（基于新 leaf）
    broadcastUsageInfo();
  }

  /** Phase 4: 列出当前目录的历史会话（供 iOS 端管理） */
  async function handleSessionList(respond: (event: unknown) => void): Promise<void> {
    try {
      const sessions = await SessionManager.list(sessionCtx?.cwd ?? process.cwd());
      const items: SessionListItem[] = sessions
        .sort((a, b) => b.modified.getTime() - a.modified.getTime())
        .slice(0, 50)
        .map((s) => ({
          path: s.path,
          id: s.id,
          name: s.name ?? null,
          cwd: s.cwd || null,
          messageCount: s.messageCount,
          firstMessage: s.firstMessage,
          modified: s.modified.getTime()
        }));
      respond(ProtocolHandler.createSessionListResult(items));
    } catch (e) {
      console.error("❌ session.list failed:", e);
      respond(ProtocolHandler.createSessionListResult([]));
    }
  }

  /** Phase 4: 切换当前窗口到指定历史会话 */
  async function handleSessionSwitch(path: string, respond: (event: unknown) => void): Promise<void> {
    if (!sessionCtx) {
      respond(ProtocolHandler.createSessionSwitchAck(path, false));
      return;
    }
    try {
      // ExtensionAPI 类型无 switchSession，但运行时 pi 是 ExtensionRuntime（含 switchSession）
      const switcher = (pi as any).switchSession;
      if (typeof switcher !== "function") {
        respond(ProtocolHandler.createSessionSwitchAck(path, false));
        return;
      }
      await switcher.call(pi, path, {
        withSession: async (ctx: any) => {
          // 切换后重置模型/用量缓存，并立即绑定到新 session 上下文。
          lastModel = null;
          sessionManagerRef = ctx?.sessionManager ?? null;
          sessionCtx = ctx ?? null;
          ctxRef = ctx ?? null;
          resetUsageAccumulator(currentUsageSessionKey(ctx));
          sessionProvider = () => ({
            sessionId: ctx?.sessionManager?.getSessionId?.() ?? null,
            sessionFile: ctx?.sessionManager?.getSessionFile?.() ?? null,
            name: pi.getSessionName?.() ?? null,
            leafId: ctx?.sessionManager?.getLeafId?.() ?? null,
            entryCount: ctx?.sessionManager?.getEntries?.()?.length ?? 0,
            reason: "switch"
          });
        }
      });
      respond(ProtocolHandler.createSessionSwitchAck(path, true));
      // 主动广播新会话的 usage，让 iOS 立即获得权威值而非短暂残留旧值
      broadcastUsageInfo();
    } catch (e) {
      console.error("❌ session.switch failed:", e);
      respond(ProtocolHandler.createSessionSwitchAck(path, false));
    }
  }

  // 本地 WS 客户端消息
  wsServer.setOnClientMessage((ws: WebSocket, text: string) => {
    handleClientMessage(text, (event) => wsServer.sendTo(ws, event));
  });

  // 中继转发的消息（来自公网 iOS）
  relay?.setOnMessage((text: string) => {
    handleClientMessage(text, (event) => relay?.send(event));
  });

  // ================= WS 服务器生命周期（遵循 Pi 规范：session 级资源） =================
  pi.on("session_start", async (event, ctx) => {
    // 新会话不能沿用上一会话的历史模型/用量。
    lastModel = null;
    resetUsageAccumulator(currentUsageSessionKey(ctx));
    // 中继模式下不需要本地 WS 服务器（避免端口 3001 冲突）
    if (!relay) {
      // 局域网模式同样要求共享 Token；未配置时服务器不会开放 3001 端口。
      const started = wsServer.start(relayCfg.token ?? "");
      if (!started) {
        ctx?.ui?.notify?.(
          "❌ 本地 WebSocket 未启动：请配置至少 24 字符的 Token（/ios-config local <token>）",
          "warning"
        );
      }
    } else {
      // 中继已配置：自动连接（无需手动 /ios-connect），每次 session_start 同步最新 name/cwd（#1）
      relay.connect({
        agentId: windowAgentId,
        name: pi.getSessionName?.() ?? null,
        cwd: ctx.cwd
      });
    }

    // 建立会话信息提供器（供 session.resume / 广播使用）
    const reason = (event as any).reason ?? "startup";
    const info: SessionInfo = {
      sessionId: ctx.sessionManager?.getSessionId?.() ?? null,
      sessionFile: ctx.sessionManager?.getSessionFile?.() ?? null,
      name: pi.getSessionName?.() ?? null,
      leafId: ctx.sessionManager?.getLeafId?.() ?? null,
      entryCount: ctx.sessionManager?.getEntries?.()?.length ?? 0,
      reason
    };
    sessionProvider = () => info;
    sessionManagerRef = ctx.sessionManager; // Phase 3.5: 保存引用供历史提取
    sessionCtx = ctx;                      // Phase 4: 保存上下文供 session.list/switch
    ctxRef = ctx;                          // 保存上下文供 abort/compact（飞书式）

    // 会话状态通过 session.info / session.update 事件实时同步给 iOS，
    // 不需要持久化到 Agent 会话文件——
    // pi.appendEntry 会写入 Session 分支并显示在 Pi TUI / 会话历史中，
    // 属于“内部日志 ≠ Conversation”原则下禁止的会话污染。已移除（2026-08-12）。

    broadcast(ProtocolHandler.createSessionUpdate(reason, info));
    // 会话建立/切换后立即同步当前模型与用量快照。
    broadcastUsageInfo();
  });

  pi.on("session_info_changed", async (event, _ctx) => {
    const name = (event as any).name ?? null;
    if (sessionProvider) {
      const info = { ...sessionProvider(), name };
      sessionProvider = () => info;
      broadcast(ProtocolHandler.createSessionUpdate("renamed", info));
    }
  });

  pi.on("session_tree", async (event, _ctx) => {
    const newLeafId = (event as any).newLeafId ?? null;
    if (sessionProvider) {
      const info = { ...sessionProvider(), leafId: newLeafId };
      sessionProvider = () => info;
      broadcast(ProtocolHandler.createSessionUpdate("tree", info));
    }
  });

  pi.on("session_shutdown", async (_event, _ctx) => {
    lastModel = null;
    resetUsageAccumulator(null);
    sessionProvider = null;
    sessionManagerRef = null;
    sessionCtx = null;
    if (thinkingFlushTimer) clearTimeout(thinkingFlushTimer);
    thinkingFlushTimer = null;
    thinkingPending = "";
    awaitingAgentStart = false;
    if (receivingFallbackTimer) { clearTimeout(receivingFallbackTimer); receivingFallbackTimer = null; }
    resetAssistantStream();
    activeToolStatuses.clear();
    toolArgsCache.clear();
    fileBeforeCache.clear();
    relay?.close();
    wsServer.close();
  });

  // 注册会话查询命令
  pi.registerCommand("ios-connect", {
    description: "手动连接中继服务器（NAT 穿透），注册当前窗口到 iOS",
    handler: async (_args, ctx) => {
      if (!relay) {
        ctx.ui.notify("❌ 未配置中继。请先执行 /ios-config 设置中继地址和 token。", "error");
        return;
      }
      if (relay.isConnected()) {
        ctx.ui.notify("⏳ 已连接到中继服务器。先 /ios-disconnect 断开再重连。", "warning");
        return;
      }
      const name = pi.getSessionName?.() ?? null;

      relay.connect({ agentId: windowAgentId, name, cwd: ctx.cwd });
      ctx.ui.notify(
        `📱 正在连接中继…\n窗口 ID: ${windowAgentId}\n会话: ${name ?? "（未命名）"}\n目录: ${ctx.cwd}`,
        "info"
      );
    },
  });

  pi.registerCommand("ios-disconnect", {
    description: "断开中继连接",
    handler: async (_args, ctx) => {
      if (!relay || !relay.isConnected()) {
        ctx.ui.notify("⚠️ 未连接到中继服务器。", "warning");
        return;
      }
      relay.close();
      ctx.ui.notify("🔌 已断开中继连接。", "info");
    },
  });

  // ================= 连接配置命令（Relay 与局域网复用同一 Token） =================
  // /ios-config <relayUrl> <token>  设置公网中继
  // /ios-config local <token>       设置仅局域网鉴权
  // /ios-config off                 关闭中继，保留原 Token 用于局域网
  // /ios-config                     查看脱敏状态
  pi.registerCommand("ios-config", {
    description: "配置 pi-ios 安全连接：<url> <token> | local <token> | off",
    handler: async (args, ctx) => {
      const cfgPath = join(homedir(), ".pi", "pi-ios-relay.json");
      const parts = args.trim().split(/\s+/);

      if (parts[0] === "off") {
        try {
          let token = "";
          if (existsSync(cfgPath)) {
            const current = JSON.parse(readFileSync(cfgPath, "utf8"));
            token = String(current.relayToken ?? current.localToken ?? "");
          }
          if (token) {
            writeSecureConfig(cfgPath, { localToken: token });
            ctx.ui.notify("✅ 已关闭中继，Token 已保留用于安全局域网。重启 pi 生效。", "info");
          } else {
            if (existsSync(cfgPath)) rmSync(cfgPath);
            ctx.ui.notify("✅ 已关闭中继；未配置 Token，本地 WebSocket 将保持关闭。", "warning");
          }
        } catch (e) {
          ctx.ui.notify(`❌ 更新配置失败: ${e}`, "error");
        }
        return;
      }

      if (parts[0] === "local") {
        const token = parts[1] ?? "";
        if (token.length < 24) {
          ctx.ui.notify("❌ Token 至少需要 24 个字符", "warning");
          return;
        }
        try {
          writeSecureConfig(cfgPath, { localToken: token });
          ctx.ui.notify("✅ 安全局域网 Token 已保存。重启 pi 生效。", "info");
        } catch (e) {
          ctx.ui.notify(`❌ 写入配置失败: ${e}`, "error");
        }
        return;
      }

      if (!args.trim()) {
        try {
          const lines: string[] = [];
          if (existsSync(cfgPath)) {
            const cfg = JSON.parse(readFileSync(cfgPath, "utf8"));
            const token = String(cfg.relayToken ?? cfg.localToken ?? "");
            const masked = token.length > 8 ? `${token.slice(0, 4)}...${token.slice(-4)}` : "***";
            lines.push(`📡 模式: ${cfg.relayUrl ? `中继 ${cfg.relayUrl}` : "安全局域网"}`);
            lines.push(`🔑 Token: ${masked}`);
          } else {
            lines.push("📡 未配置：不会开放远程连接");
          }
          lines.push(`🔌 中继连接: ${relay ? (relay.isConnected() ? "✅ 已连接" : "❌ 未连接") : "未启用"}`);
          lines.push(`📱 本地 iOS 客户端: ${wsServer.hasClients() ? "在线" : "无"}`);
          const name = pi.getSessionName?.() ?? null;
          const sid = ctx.sessionManager?.getSessionId?.() ?? "ephemeral";
          lines.push(`📋 会话: ${name ?? "（未命名）"} (${String(sid).slice(0, 12)}…)`);
          lines.push(`🪟 窗口 ID: ${windowAgentId}`);
          lines.push("");
          lines.push("用法: <url> <token> | local <token> | off");
          ctx.ui.notify(lines.join("\n"), "info");
        } catch (e) {
          ctx.ui.notify(`❌ 读取配置失败: ${e}`, "error");
        }
        return;
      }

      const url = parts[0];
      const token = parts[1] ?? "";
      if (!url || !/^wss?:\/\//.test(url)) {
        ctx.ui.notify("❌ URL 必须以 ws:// 或 wss:// 开头", "warning");
        return;
      }
      if (token.length < 24) {
        ctx.ui.notify("❌ Token 至少需要 24 个字符", "warning");
        return;
      }

      try {
        writeSecureConfig(cfgPath, { relayUrl: url, relayToken: token, localToken: token });
        ctx.ui.notify(`✅ 中继配置已保存: ${url}（重启 pi 生效）`, "info");
      } catch (e) {
        ctx.ui.notify(`❌ 写入配置失败: ${e}`, "error");
      }
    },
  });

  // ================= Pi → iOS: 事件推送 =================

  type AgentFinalDisposition = "completed" | "error" | "idle";
  let agentFinalDisposition: AgentFinalDisposition = "completed";
  const activeToolStatuses = new Map<string, { tool: string; description: string }>();

  // Turn 结束：累计用量、收尾思考增量、处理错误（正文由 assistant.* 流式发送）
  pi.on("turn_end", async (event, _ctx) => {
    // 累计用量（模型/上下文/缓存命中统计）—— 同一 messageId 重复触发时跳过，防止翻倍（N2）
    const turnMessageId = (event as any)?.message?.id ?? null;
    const [skipDup, nextSeen] = shouldSkipDuplicateTurnEnd(turnMessageId, lastTurnEndMessageId);
    if (!skipDup) {
      lastTurnEndMessageId = nextSeen;
      accumulateUsage((event as any).message?.usage);
    }
    // 缓存当前模型（供 usage 查询；ctx.model 非 turn 期间可能为空）
    const modelId = (event as any).message?.model;
    if (typeof modelId === "string" && modelId) {
      lastModel = modelId;
    }

    if (thinkingFlushTimer) {
      clearTimeout(thinkingFlushTimer);
      thinkingFlushTimer = null;
    }
    flushThinking();
    const { message } = event;
    // 正文已由 message_update/message_end 通过 assistant.* 流式发送，turn_end 不再重复广播。
    // 这里仅保留 LLM 错误提示、状态与用量统计。
    const stopReason = (message as any).stopReason;
    if (message.role === "assistant" && stopReason === "error") {
      const errMsg = (message as any).errorMessage ?? "LLM 返回了未知错误";
      agentFinalDisposition = "error";
      broadcast(ProtocolHandler.createStatus("error", { description: String(errMsg) }));
      broadcast(ProtocolHandler.createAgentOutput(`⚠️ LLM 错误: ${errMsg}`, "message"));
    } else if (message.role === "assistant" && stopReason === "aborted") {
      agentFinalDisposition = "idle";
    }
    // 每轮完成后主动推送最新模型、上下文和累计用量，iOS 不再依赖轮询/手动刷新。
    // 不重算历史，避免当前 turn 尚未落盘时覆盖刚累计的 usage。
    broadcastUsageInfo(false);
  });

  // Agent 流式思考过程（增量 + 合并节流：每 60ms 静默后刷一次累积增量）
  let thinkingPending = "";
  let thinkingFlushTimer: ReturnType<typeof setTimeout> | null = null;

  function flushThinking(): void {
    if (!thinkingPending) return;
    const chunk = thinkingPending;
    thinkingPending = "";
    broadcast(ProtocolHandler.createAgentOutput(chunk, "thinking"));
  }

  function flushThinkingNow(): void {
    if (thinkingFlushTimer) clearTimeout(thinkingFlushTimer);
    thinkingFlushTimer = null;
    flushThinking();
  }

  // Agent 正文流式回复：text_delta 以 20ms 节流批量发送，平衡 UI 流畅度与同步延迟。
  let activeAssistantStreamId: string | null = null;
  let assistantStreamStarted = false;
  let assistantTextPending = "";
  let assistantTextFlushTimer: ReturnType<typeof setTimeout> | null = null;
  // 每个 assistant 流独立编号，iOS 用它防止 delta 重复或乱序。 
  let assistantDeltaSeq = 0;

  function ensureAssistantStream(): string {
    if (!activeAssistantStreamId) {
      activeAssistantStreamId = `assistant_${randomUUID()}`;
    }
    if (!assistantStreamStarted) {
      assistantStreamStarted = true;
      broadcast(ProtocolHandler.createAssistantStart(activeAssistantStreamId));
    }
    return activeAssistantStreamId;
  }

  function flushAssistantText(): void {
    if (!assistantTextPending) return;
    const messageId = ensureAssistantStream();
    const delta = assistantTextPending;
    assistantTextPending = "";
    const seq = ++assistantDeltaSeq;
    broadcast(ProtocolHandler.createAssistantDelta(messageId, delta, seq));
  }

  function resetAssistantStream(): void {
    if (assistantTextFlushTimer) clearTimeout(assistantTextFlushTimer);
    assistantTextFlushTimer = null;
    assistantTextPending = "";
    activeAssistantStreamId = null;
    assistantStreamStarted = false;
    assistantDeltaSeq = 0;
  }

  function extractAssistantText(message: any): string {
    if (!message || message.role !== "assistant") return "";
    if (typeof message.content === "string") return message.content;
    if (!Array.isArray(message.content)) return "";
    return message.content
      .filter((block: any) => block?.type === "text" && typeof block.text === "string")
      .map((block: any) => block.text)
      .join("");
  }

  pi.on("message_start", (event) => {
    if (event.message.role !== "assistant") return;
    resetAssistantStream();
    activeAssistantStreamId = `assistant_${randomUUID()}`;

  });

  pi.on("message_update", (event) => {
    const evt = event.assistantMessageEvent as any;
    if (!evt) return;

    if (evt.type === "thinking_delta") {
      const delta = typeof evt.delta === "string" ? evt.delta : "";
      if (!delta) return;
      thinkingPending += delta;
      if (thinkingFlushTimer) clearTimeout(thinkingFlushTimer);
      thinkingFlushTimer = setTimeout(flushThinking, 60);
      return;
    }

    if (evt.type === "text_start") {
      flushThinkingNow();
      ensureAssistantStream();
      return;
    }

    if (evt.type === "text_delta") {
      const delta = typeof evt.delta === "string" ? evt.delta : "";
      if (!delta) return;
      flushThinkingNow();
      ensureAssistantStream();
      assistantTextPending += delta;
      if (!assistantTextFlushTimer) {
        assistantTextFlushTimer = setTimeout(() => {
          assistantTextFlushTimer = null;
          flushAssistantText();
        }, 20);
      }
      return;
    }

    if (evt.type === "text_end") {
      if (assistantTextFlushTimer) clearTimeout(assistantTextFlushTimer);
      assistantTextFlushTimer = null;
      flushAssistantText();
    }
  });

  pi.on("message_end", (event) => {
    if (event.message.role !== "assistant") return;

    flushThinkingNow();
    const finalText = extractAssistantText(event.message);
    if (finalText || assistantStreamStarted) {
      const messageId = ensureAssistantStream();
      if (assistantTextFlushTimer) clearTimeout(assistantTextFlushTimer);
      assistantTextFlushTimer = null;
      flushAssistantText();
      // message_end 是权威完整消息；用于校正极端情况下遗漏的 delta，并保留标题降级。
      broadcast(ProtocolHandler.createAssistantEnd(
        messageId,
        finalText || undefined
      ));
    }
    resetAssistantStream();
  });

  // Tool 调用开始（Phase 2 完整版）
  // 缓存 args 供 tool_execution_end 提取文件路径（end 事件没有 args 字段）
  const toolArgsCache = new Map<string, any>();
  type FileSnapshot = { path: string; existed: boolean; content: string | null };
  const fileBeforeCache = new Map<string, FileSnapshot>();
  const MAX_FILE_SNAPSHOT_BYTES = 2 * 1024 * 1024;

  function captureFileSnapshot(toolCallId: string, toolName: string, args: any): void {
    if (!isFileMutationTool(toolName)) return;
    const path = extractFilePath(args);
    if (!path) return;
    const absolutePath = resolve(sessionCtx?.cwd ?? process.cwd(), path);
    try {
      const existed = existsSync(absolutePath);
      let content: string | null = null;
      if (existed) {
        const stat = statSync(absolutePath);
        if (stat.isFile() && stat.size <= MAX_FILE_SNAPSHOT_BYTES) {
          content = readFileSync(absolutePath, "utf8");
        }
      }
      fileBeforeCache.set(toolCallId, { path, existed, content });
    } catch {
      // 快照失败不影响工具执行；文件事件仍会发送，只省略无法可靠计算的行数。
      fileBeforeCache.set(toolCallId, { path, existed: true, content: null });
    }
  }

  pi.on("tool_execution_start", async (event, _ctx) => {
    // 事件结构: { toolCallId, toolName, args }（注意是 args 不是 input）
    const input = event.args ?? {};
    toolArgsCache.set(event.toolCallId, input);
    captureFileSnapshot(event.toolCallId, event.toolName, input);

    // 截获 ask_user_question：发送结构化问卷到 iOS
    if (event.toolName === "ask_user_question" && input?.questions) {
      try {
        const qmsg = ProtocolHandler.createQuestionnaireShow(input.questions);
        qmsg.id = `q_${event.toolCallId}`;
        questionnaireToToolCall.set(qmsg.id, event.toolCallId);
        pendingQuestionnaire = qmsg;  // 缓存待处理问卷（重连后同步）
        broadcast(qmsg);
      } catch { /* ignore parse errors */ }
    }

    let command = "";

    if (typeof input === "string") {
      command = input;
    } else if (input.command) {
      command = input.command;
    } else if (input.cmd) {
      command = input.cmd;
    } else if (input.path) {
      command = `${input.path}${input.offset ? ` (offset=${input.offset})` : ""}`;
    } else if (input.file) {
      command = input.file;
    } else if (Object.keys(input).length > 0) {
      command = JSON.stringify(input);
    }

    const statusDescription = command.length > 160 ? `${command.slice(0, 157)}...` : command;
    activeToolStatuses.set(event.toolCallId, {
      tool: event.toolName,
      description: statusDescription
    });
    broadcast(ProtocolHandler.createStatus("using_tool", {
      tool: event.toolName,
      description: statusDescription
    }));
    broadcast(ProtocolHandler.createToolStart(event.toolName, command, event.toolCallId));
  });

  // Tool 流式输出（Phase 2 加强）
  pi.on("tool_execution_update", async (event, _ctx) => {
    if (event.partialResult) {
      let data = typeof event.partialResult === "string"
        ? event.partialResult
        : JSON.stringify(event.partialResult, null, 2);
      broadcast(ProtocolHandler.createToolOutput(data));
    }
  });

  // Tool 结束（合并 status + tool.end + 文件变更广播，避免分散 handler 漏改，#7）
  pi.on("tool_execution_end", async (event, _ctx) => {
    activeToolStatuses.delete(event.toolCallId);

    const args = toolArgsCache.get(event.toolCallId);
    const snapshot = fileBeforeCache.get(event.toolCallId);
    toolArgsCache.delete(event.toolCallId);
    fileBeforeCache.delete(event.toolCallId);

    // 已处理的问卷清除（与 tool_result 的清理互不冲突）
    if (pendingQuestionnaire) {
      const qid = pendingQuestionnaire.id;
      if (qid && questionnaireToToolCall.get(qid) === event.toolCallId) {
        pendingQuestionnaire = null;
      }
    }

    // 1) tool.end + 状态
    broadcast(ProtocolHandler.createToolEnd(!event.isError, event.toolCallId));
    const remainingTool = Array.from(activeToolStatuses.values()).pop();
    if (remainingTool) {
      broadcast(ProtocolHandler.createStatus("using_tool", remainingTool));
    } else if (agentBusy) {
      broadcast(ProtocolHandler.createStatus("thinking", {
        description: event.isError ? "工具执行失败，正在继续分析" : "继续分析"
      }));
    }

    // 2) 文件变更广播（只接受成功的文件写入类工具）
    const toolName = event.toolName || "";
    if (event.isError || !isFileMutationTool(toolName)) return;
    const path = snapshot?.path ?? extractFilePath(args);
    if (!path) return;

    const normalizedTool = toolName.toLowerCase();
    let action: "modified" | "created" | "deleted" = "modified";
    if (/(delete|remove)/.test(normalizedTool)) {
      action = "deleted";
    } else if (/(write|create)/.test(normalizedTool) && snapshot && !snapshot.existed) {
      action = "created";
    }

    let stats: { additions?: number; deletions?: number } = {};
    const details = (event as any).result?.details;
    const patch = typeof details?.patch === "string"
      ? details.patch
      : (typeof details?.diff === "string" ? details.diff : "");

    if (patch) {
      stats = countPatchChanges(patch);
    } else if (Array.isArray(args?.edits)) {
      const additions = args.edits.reduce(
        (sum: number, edit: any) => sum + countTextLines(String(edit?.newText ?? "")),
        0
      );
      const deletions = args.edits.reduce(
        (sum: number, edit: any) => sum + countTextLines(String(edit?.oldText ?? "")),
        0
      );
      stats = { additions, deletions };
    } else if (typeof args?.oldText === "string" || typeof args?.newText === "string") {
      stats = {
        additions: countTextLines(String(args?.newText ?? "")),
        deletions: countTextLines(String(args?.oldText ?? ""))
      };
    } else if (typeof args?.content === "string") {
      stats.additions = countTextLines(args.content);
      if (action === "modified" && snapshot?.content !== null && snapshot?.content !== undefined) {
        stats.deletions = countTextLines(snapshot.content);
      }
    } else if (action === "deleted" && snapshot?.content !== null && snapshot?.content !== undefined) {
      stats.deletions = countTextLines(snapshot.content);
    }

    broadcast(ProtocolHandler.createFileChange(path, action, stats));
  });

  // tool_result: 双向同步答案（PC ↔ iOS）
  pi.on("tool_result", (event) => {
    // 工具完成 → 清除待处理问卷（无论谁回答）
    if (pendingQuestionnaire) {
      const qid = pendingQuestionnaire.id;
      if (qid && questionnaireToToolCall.get(qid) === event.toolCallId) {
        pendingQuestionnaire = null;
      }
    }
    if (event.toolCallId && iosAnswersCache.has(event.toolCallId)) {
      // iOS 先答：替换为 iOS 答案
      const answers = iosAnswersCache.get(event.toolCallId)!;
      iosAnswersCache.delete(event.toolCallId);
      const lines = answers.map((a: any, i: number) => {
        const v = a.selected?.length ? a.selected.join(", ") : (a.answer ?? "(未回答)");
        return `${i + 1}. ${a.question || "?"}: ${v}`;
      });
      return {
        content: [{ type: "text", text: `用户通过 iOS 回答:\n${lines.join("\n")}` }],
        isError: false
      };
    }
    // PC 先答：同步结果到 iOS
    const pcAnswers = (event as any).details?.answers;
    if (pcAnswers && Array.isArray(pcAnswers)) {
      broadcast({
        id: `pc_answer_${Date.now()}`,
        type: "questionnaire.answered",
        timestamp: Date.now(),
        payload: { answers: pcAnswers, source: "pc" }
      } as any);
    }
  });

  // Agent 状态：直接映射 Pi 生命周期，不增加新的运行时或服务。
  // PC 终端输入的实时同步：iOS 端能看到 Pi 收到的每条用户消息
  pi.on("input", async (event: any, _ctx) => {
    // 只广播 PC 终端（interactive）输入，忽略 iOS 自发（extension/rpc），避免回声
    if (event?.source !== "interactive") return;
    const text = typeof event?.text === "string" ? event.text.trim() : "";
    if (!text) return;
    broadcast(ProtocolHandler.createInput(text));
  });

  pi.on("before_agent_start", async (_event, _ctx) => {
    awaitingAgentStart = true;
    broadcast(ProtocolHandler.createStatus("receiving", {
      description: "Pi 收到请求"
    }));
    // 兜底：极端情况下 agent_start 未触发时，receiving 状态会卡住；15s 后收口回 idle（#5）。
    if (receivingFallbackTimer) clearTimeout(receivingFallbackTimer);
    receivingFallbackTimer = setTimeout(() => {
      if (awaitingAgentStart) {
        awaitingAgentStart = false;
        console.warn("⚠️ agent_start 超时未触发，回退到 idle 状态");
        broadcast(ProtocolHandler.createStatus("idle"));
      }
      receivingFallbackTimer = null;
    }, 15_000);
  });

  pi.on("agent_start", async (_event, _ctx) => {
    awaitingAgentStart = false;
    if (receivingFallbackTimer) { clearTimeout(receivingFallbackTimer); receivingFallbackTimer = null; }
    agentBusy = true;
    agentFinalDisposition = "completed";
    activeToolStatuses.clear();
    broadcast(ProtocolHandler.createStatus("thinking", {
      description: "Pi 正在思考"
    }));
  });

  pi.on("agent_end", async (_event, _ctx) => {
    agentBusy = false;
    awaitingAgentStart = false;
    if (receivingFallbackTimer) { clearTimeout(receivingFallbackTimer); receivingFallbackTimer = null; }
    activeToolStatuses.clear();
    if (agentFinalDisposition === "completed") {
      broadcast(ProtocolHandler.createStatus("completed", {
        description: "Pi 已完成"
      }));
    } else if (agentFinalDisposition === "idle") {
      broadcast(ProtocolHandler.createStatus("idle"));
    }
    // 保留 turn_end 刚累计的 usage，避免历史落盘时序导致数值回退。
    broadcastUsageInfo(false);
    // Steer 重发优先于普通队列（P3）：打断后 agent_end 触发，立即发出挂起的消息
    if (pendingInterruptSend) {
      const pending = pendingInterruptSend;
      pendingInterruptSend = null;
      try { pi.sendUserMessage(pending.text); }
      catch (e) {
        console.error("❌ steer resend failed:", e);
        pending.respond(ProtocolHandler.createAgentOutput(`❌ 打断后发送失败: ${e}`, "message"));
      }
      return;  // 已处理，跳过普通队列刷新
    }
    scheduleFlush();  // 空闲后处理排队消息（飞书式）
  });

  // Pi LLM 可主动发送消息到 iOS
  pi.registerTool({
    name: "send_to_ios",
    label: "Send to iOS",
    description: "Send message to connected iOS client",
    parameters: {
      type: "object",
      properties: { message: { type: "string" } },
      required: ["message"]
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      const msg = ProtocolHandler.createAgentOutput(String(params.message || ""), "message");
      broadcast(msg);
      return {
        content: [{ type: "text", text: "Message sent to iOS" }],
        details: {},
        isError: false
      };
    }
  });

  // Pi → iOS：发送图片（读取本地文件 → base64 → iOS 显示）
  pi.registerTool({
    name: "send_image_to_ios",
    label: "发送图片到 iOS",
    description: "读取本地图片文件并发送到 iOS 端显示",
    parameters: {
      type: "object",
      properties: { file_path: { type: "string", description: "本地图片文件路径" } },
      required: ["file_path"]
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      try {
        const filePath = String((params as any).file_path || "");
        if (!existsSync(filePath)) {
          return { content: [{ type: "text", text: "❌ 文件不存在: " + filePath }], details: {}, isError: true };
        }
        const data = readFileSync(filePath);
        const base64 = data.toString("base64");
        const fileName = filePath.split(/[\\/]/).pop() ?? "image.png";
        broadcast(ProtocolHandler.createMediaImage(fileName, base64));
        return { content: [{ type: "text", text: `📤 图片已发送到 iOS: ${fileName}` }], details: {}, isError: false };
      } catch (e) {
        return { content: [{ type: "text", text: `❌ 发送失败: ${e}` }], details: {}, isError: true };
      }
    }
  });

  // ================= 文件变更事件广播 =================
  // （已合并到上方 tool_execution_end 统一处理，避免分散 handler 漏改，#7）

  // ================= 文件同步工具（Phase 2 增强） =================
  pi.registerTool({
    name: "file_sync",
    label: "文件同步",
    description: "把文件同步到 iOS 远程终端或执行同步命令",
    parameters: {
      type: "object",
      properties: {
        path: { type: "string", description: "文件路径或命令" },
        target: { type: "string", description: "目标路径（可选）" }
      },
      required: ["path"]
    },
    async execute(toolCallId, params, signal, onUpdate, ctx) {
      // 手写 schema 无法推断泛型，显式转 string
      const path = String(params.path || "");
      let target = String(params.target || "");
      let result = "文件同步完成";
      let isError = false;

      try {
        if (target) {
          // 执行同步命令（Node 原生递归复制，跨平台，不依赖 shell）
          await cp(path, target, { recursive: true });
          result = `文件已同步到: ${target}`;
        } else {
          // 广播文件变更
          broadcast(ProtocolHandler.createFileChange(path, "modified"));
        }
      } catch (e) {
        result = String(e);
        isError = true;
      }

      return {
        content: [{ type: "text", text: result }],
        details: {},
        isError: isError
      };
    }
  });

}
