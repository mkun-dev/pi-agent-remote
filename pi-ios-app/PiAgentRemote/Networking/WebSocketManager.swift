import Foundation
import Starscream

/// WebSocket 连接管理（使用 Starscream，底层不走 NSURLSession，不受 ATS 限制）
class WebSocketManager: ObservableObject {
    // Business messages & picker state all live in ConversationStore via RemoteEvent.
    // This class only transports.
    
    private var status: String = "已断开"
    private var isConnected = false
    private var currentAgentId: String? = nil
    private var session: SessionInfo = .empty
    private var questionnaireId: String?
    private var questionnaireQuestions: [ProtocolMessage.QuestionPayload] = []
    /// Phase 4: 会话切换结果回调 (sessionFile, ok)
    var onSessionSwitchAck: ((String, Bool) -> Void)?
    /// 模型切换结果回调（model.select_ack）
    var onModelSelectAck: ((String, Bool) -> Void)?
    
    private var socket: WebSocket?

    private var currentHost: String
    private var currentPort: Int
    private var currentToken: String
    private let clientId: String
    var onDeliveryResult: ((String, Bool) -> Void)?
    var onConnected: (() -> Void)?
    /// 连接状态变更回调（connected: 是否已连接, status: 描述），供上层同步 ConversationStore。
    var onConnectionStateChanged: ((Bool, String) -> Void)?
    var onRemoteEvent: ((RemoteEvent) -> Void)?
    /// 目标窗口离线回调（relay.error code=agent_offline）：供上层主动 fallback，不等 relay.agents（N1）。
    var onTargetAgentOffline: (() -> Void)?
    /// 统一 Agent 状态事件回调，由 ChatViewModel 的 Reducer 消费。
    var onAgentStateEvent: ((AgentStateEvent) -> Void)?
    
    // 自动重连
    private var reconnectTimer: Timer?
    private var reconnectDelay: TimeInterval = 3
    private var shouldAutoReconnect = false  // 仅手动连接后为 true
    
    init(
        host: String = "82.156.158.106",
        port: Int = 3002,
        token: String = "",
        clientId: String = UUID().uuidString.lowercased()
    ) {
        self.currentHost = host
        self.currentPort = port
        self.currentToken = token
        self.clientId = clientId
    }
    
    var currentURL: String {
        endpointURL.absoluteString
    }
    
    /// 支持现有 ws:// IP，也允许 Host 直接填写 wss:// 域名；默认行为不变。
    private var endpointURL: URL {
        let value = currentHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("ws://") || value.lowercased().hasPrefix("wss://") {
            if var components = URLComponents(string: value) {
                if components.port == nil { components.port = currentPort }
                if let url = components.url { return url }
            }
        } else if let url = URL(string: "ws://\(value):\(currentPort)") {
            return url
        }
        return URL(string: "ws://127.0.0.1:3002")!
    }
    
    /// Token 放在 Authorization Header，避免出现在 URL、代理访问日志和截图中。
    private var connectURL: URL {
        guard var components = URLComponents(url: endpointURL, resolvingAgainstBaseURL: false) else {
            return endpointURL
        }
        var items = components.queryItems ?? []
        items.removeAll { ["role", "clientId", "client_id", "token"].contains($0.name) }
        items.append(URLQueryItem(name: "role", value: "client"))
        items.append(URLQueryItem(name: "client_id", value: clientId))
        components.queryItems = items
        return components.url ?? endpointURL
    }
    
    func updateConnection(host: String, port: Int, token: String = "") {
        disconnect()
        currentHost = host
        currentPort = port
        currentToken = token
        connect()
    }
    
    func connect() {
        // 防重复：已有活跃连接时不重复创建
        if socket != nil {
            disconnect()
        }
        
        shouldAutoReconnect = true
        cancelReconnect()
        isConnected = false
        // 手动连接重置退避延迟，避免上次累积的 30s 等待影响本次体验
        reconnectDelay = 3
        RemoteLogger.ws("连接中 → \(endpointURL.host ?? "?"):\(endpointURL.port ?? 0)")
        
        var request = URLRequest(url: connectURL)
        request.timeoutInterval = 60
        if !currentToken.isEmpty {
            request.setValue("Bearer \(currentToken)", forHTTPHeaderField: "Authorization")
        }
        
        // Starscream 默认 useCustomEngine=true → WSEngine(TCPTransport) 纯 socket 实现，
        // 不经过 NSURLSession，不受 ATS 限制，支持 ws:// 明文
        let ws = WebSocket(request: request)
        ws.delegate = self
        ws.callbackQueue = .main   // 回调统一在主线程
        socket = ws
        ws.connect()
    }

    // MARK: - 消息接收

    private func handle(_ text: String) {
        guard let decoded = RemoteEventDecoder.decodeWithCompatibility(text: text) else { return }
        let proto = decoded.protocolMessage

        // 唯一数据通道：转发类型化事件到 ConversationStore（单一业务状态源）。
        onRemoteEvent?(decoded.event)

        // transport 层仅保留轻量副作用（推送通知 / UI 信号 / 回调），
        // 不再构建任何 Message / Trace —— 全部由 ConversationStore.accept() 承担。

        if proto.type == "relay.agents" {
            // 同步 Transport 层的 currentAgentId，确保后续出站请求能携带有效的 targetAgentId。
            // 优先保持当前选择；若当前不可用则自动选第一个在线窗口。
            let incomingIds = (proto.payload.agents ?? []).compactMap { $0.agentId }
            if let current = currentAgentId, incomingIds.contains(current) {
                // 当前选择仍然有效
            } else if let first = incomingIds.first {
                currentAgentId = first
                RemoteLogger.ws("[AGENT] Transport currentAgentId synced → \(first)")
            } else {
                currentAgentId = nil
                RemoteLogger.ws("[AGENT] Transport currentAgentId cleared (no agents)")
            }
        } else if proto.type == "session.info" || proto.type == "session.update" {
            session = SessionInfo(
                sessionId: proto.payload.sessionId,
                sessionFile: proto.payload.sessionFile,
                name: proto.payload.name,
                leafId: proto.payload.leafId,
                entryCount: proto.payload.entryCount ?? 0,
                reason: proto.payload.reason
            )
        }

        if proto.type == "agent.status", let agentStatus = proto.payload.status {
            onAgentStateEvent?(.remoteStatus(
                status: agentStatus,
                tool: proto.payload.tool,
                description: proto.payload.description
            ))
        }

        if proto.type == "session.switch_ack" {
            onSessionSwitchAck?(proto.payload.sessionFile ?? "", proto.payload.ok ?? false)
        } else if proto.type == "model.list" {
            // model.list 由 RemoteEvent → ConversationStore.handleModel 处理，
            // 选择器触发由 ConversationStore.modelPickerRequested 管理（/model 命令）。
        } else if proto.type == "model.select_ack" {
            onModelSelectAck?(proto.payload.modelId ?? "", proto.payload.ok ?? false)
        } else if proto.type == "tool.start" {
            onAgentStateEvent?(.toolStarted(
                tool: proto.payload.tool ?? "tool",
                description: proto.payload.command ?? ""
            ))
        } else if proto.type == "tool.end" {
            onAgentStateEvent?(.toolEnded)
        } else if proto.type == "assistant.start" {
            onAgentStateEvent?(.assistantStarted)
        } else if proto.type == "assistant.delta" {
            onAgentStateEvent?(.assistantDelta)
        } else if proto.type == "assistant.end" {
            onAgentStateEvent?(.assistantEnded)
            if let finalText = proto.payload.text, !finalText.isEmpty {
                NotificationManager.shared.notifyAgentReply(finalText)
            }
        } else if proto.type == "questionnaire.show" {
            // 问卷状态由 RemoteEvent → ConversationStore.handleQuestionnaire 统一管理。
            // transport 层仅保留推送通知。
            questionnaireQuestions = proto.payload.questions ?? []
            questionnaireId = proto.id
            if !questionnaireQuestions.isEmpty {
                NotificationManager.shared.notifyQuestionnaire(
                    questionnaireQuestions.first?.question ?? "请回答 Pi 的提问"
                )
            }
        }

        // Phase 3 NAT 穿透: relay ACK / ERROR
        if proto.type == "relay.ack" || proto.type == "relay.error" {
            let ok = proto.type == "relay.ack"
            if let id = proto.payload.id {
                onDeliveryResult?(id, ok)
            }
            // 目标窗口离线：主动清空 Transport 目标并通知上层即时 fallback（N1）
            if proto.type == "relay.error", proto.payload.code == "agent_offline" {
                RemoteLogger.ws("[WS] target agent offline, fallback")
                currentAgentId = nil
                onTargetAgentOffline?()
            }
        }

        // Phase 3: 兼容旧 agent.output 的完成通知（正文已由 assistant.* 流式处理）
        if proto.type == "agent.output", proto.payload.type == "message",
           let text = proto.payload.text, !text.isEmpty {
            NotificationManager.shared.notifyAgentReply(text)
        }
    }

    /// 断开（手动模式：不自动重连），显示断开原因帮助诊断
    private func onDisconnect(reason: String = "") {
        status = reason.isEmpty ? "已断开" : "已断开 (\(reason))"
        isConnected = false
        RemoteLogger.ws("已断开: \(reason)")
        onConnectionStateChanged?(false, status)
        onAgentStateEvent?(.disconnected)
        socket = nil  // 释放旧 socket，让后续重连能创建新连接
        session = .empty
        currentAgentId = nil
    }
    
    private func scheduleReconnectIfNeeded() {
        guard shouldAutoReconnect else { return }
        guard !isConnected else { return }  // 已有活跃连接
        cancelReconnect()
        let delay = reconnectDelay
        status = "已断开，\(Int(delay))s 后重连..."
        // 反馈重连状态到 UI，让用户知道正在自动恢复
        onConnectionStateChanged?(false, status)
        reconnectTimer = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in
            guard let self, self.reconnectTimer != nil else { return }  // 已被 cancelReconnect 取消
            RemoteLogger.ws("重连中...")
            self.status = "正在重连..."
            self.onConnectionStateChanged?(false, "正在重连...")
            self.connect()
        }
        // 指数退避: 3 → 5 → 10 → 20 → 30（最大 30s）
        reconnectDelay = min(reconnectDelay * 1.7, 30)
    }
    
    private func cancelReconnect() {
        reconnectTimer?.invalidate()
        reconnectTimer = nil
    }
    
    func send(_ text: String, id: String = UUID().uuidString, context: MessageContext? = nil) {
        let p = ProtocolMessage(
            id: id,
            type: "agent.input",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(
                text: text, status: nil, tool: nil, command: nil, data: nil,
                success: nil, path: nil, action: nil, type: nil,
                sessionId: nil, sessionFile: nil, name: nil, leafId: nil,
                entryCount: nil, reason: nil,
                entries: nil,
                targetAgentId: currentAgentId,
                agents: nil, agent: nil,
                agentId: nil,
                sessions: nil, ok: nil,
                id: nil,
                context: context
            )
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    // Phase 3: 请求恢复会话
    func setPreferredTargetAgentId(_ agentId: String?) {
        currentAgentId = agentId
    }
    
    func requestSessionResume(generation: Int? = nil) {
        RemoteLogger.session("[SESSION] request resume agent=\(currentAgentId ?? "nil") session=\(session.sessionId ?? "nil") generation=\(generation.map(String.init) ?? "nil")")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "session.resume",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(
                text: nil, status: nil, tool: nil, command: nil, data: nil,
                success: nil, path: nil, action: nil, type: nil,
                sessionId: session.sessionId, sessionFile: nil, name: nil, leafId: nil,
                entryCount: nil, reason: nil,
                entries: nil,
                targetAgentId: currentAgentId,
                agents: nil, agent: nil,
                agentId: nil,
                sessions: nil, ok: nil,
                id: nil,
                generation: generation
            )
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    /// Phase 4: 切换对话目标窗口（多 agent）
    /// 注意：消息清空与增量计数重置由 ChatViewModel 完成（switchTarget + clearMessages）
    func switchTarget(to agentId: String) {
        guard agentId != currentAgentId else { return }
        RemoteLogger.session("[AGENT] switch target -> \(agentId)")
        currentAgentId = agentId
        session = .empty
    }
    
    /// Phase 4: 请求目标窗口列出历史会话
    func sendSessionList() {
        RemoteLogger.session("[SESSION] request list agent=\(currentAgentId ?? "nil")")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "session.list",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(
                text: nil, status: nil, tool: nil, command: nil, data: nil,
                success: nil, path: nil, action: nil, type: nil,
                sessionId: nil, sessionFile: nil, name: nil, leafId: nil,
                entryCount: nil, reason: nil,
                entries: nil,
                targetAgentId: currentAgentId,
                agents: nil, agent: nil,
                agentId: nil,
                sessions: nil, ok: nil,
                id: nil
            )
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    /// Phase 4: 让当前目标窗口切换到指定历史会话
    func sendSessionSwitch(_ path: String) {
        RemoteLogger.session("[SESSION] request switch agent=\(currentAgentId ?? "nil") path=\(path)")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "session.switch",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(
                text: nil, status: nil, tool: nil, command: nil, data: nil,
                success: nil, path: nil, action: nil, type: nil,
                sessionId: nil, sessionFile: path, name: nil, leafId: nil,
                entryCount: nil, reason: nil,
                entries: nil,
                targetAgentId: currentAgentId,
                agents: nil, agent: nil,
                agentId: nil,
                sessions: nil, ok: nil,
                id: nil
            )
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    func selectModel(_ modelId: String, selectionRequestId: String) {
        RemoteLogger.model("[MODEL] request select agent=\(currentAgentId ?? "nil") requestId=\(selectionRequestId) model=\(modelId)")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "model.select",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, modelId: modelId, selectionRequestId: selectionRequestId)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    /// 提交问卷答案
    func submitQuestionnaire(_ answers: [ProtocolMessage.AnswerPayload], questionnaireId: String? = nil) {
        let qid = questionnaireId ?? self.questionnaireId
        let p = ProtocolMessage(
            id: qid ?? UUID().uuidString,
            type: "questionnaire.answer",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, id: qid, answers: answers)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    /// iOS → PC：上传图片（base64）
    func uploadMedia(fileName: String, base64: String, dir: String = "pi-ios-uploads") {
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "media.upload",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, fileName: fileName, base64: base64, dir: dir)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }
    
    /// 请求模型与用量信息
    func requestUsage(generation: Int? = nil) {
        RemoteLogger.usage("[USAGE] request agent=\(currentAgentId ?? "nil") generation=\(generation.map(String.init) ?? "nil")")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "usage.request",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, generation: generation)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    /// 请求当前可用模型列表（连接后自动同步）
    func requestModelList(generation: Int? = nil) {
        RemoteLogger.model("[MODEL] request list agent=\(currentAgentId ?? "nil") generation=\(generation.map(String.init) ?? "nil")")
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "model.request",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, generation: generation)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    /// 重连后请求待处理问卷同步
    func requestQuestionnaireSync(generation: Int? = nil) {
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "questionnaire.sync",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, generation: generation)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    /// 请求目录树（workspace.list）— 懒加载，只请求目标目录
    func requestWorkspaceList(path: String = "") {
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "workspace.list",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(path: path, targetAgentId: currentAgentId)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    /// 请求文件内容（workspace.readFile）
    func requestWorkspaceFile(path: String) {
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "workspace.readFile",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(path: path, targetAgentId: currentAgentId)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    /// 请求全项目文件名搜索（workspace.search）—— 不局限于已加载目录
    func requestWorkspaceSearch(query: String) {
        let p = ProtocolMessage(
            id: UUID().uuidString,
            type: "workspace.search",
            timestamp: Int(Date().timeIntervalSince1970 * 1000),
            payload: ProtocolMessage.Payload(targetAgentId: currentAgentId, query: query)
        )
        guard let data = try? JSONEncoder().encode(p),
              let json = String(data: data, encoding: .utf8) else { return }
        socket?.write(string: json)
    }

    func disconnect() {
        shouldAutoReconnect = false  // 手动断开 → 不自动重连
        cancelReconnect()
        socket?.disconnect()
        socket = nil
        isConnected = false
        status = "已断开"
        // socket 已置 nil，Starscream 回调会被 guard 拦截，这里显式同步 UI 状态。
        onConnectionStateChanged?(false, "已断开")
        // 断开时清空窗口状态，避免切换到其他连接后残留
        currentAgentId = nil
        session = .empty
    }
}

// MARK: - Starscream WebSocketDelegate

extension WebSocketManager: WebSocketDelegate {
    func didReceive(event: WebSocketEvent, client: WebSocketClient) {
        // 忽略已销毁的旧 socket 回调，避免竞态覆盖新连接状态
        guard (client as? WebSocket) === socket else { return }
        switch event {
        case .connected:
            isConnected = true
            reconnectDelay = 3
            cancelReconnect()
            onConnectionStateChanged?(true, "已连接")
            onConnected?()
        case .disconnected(let reason, let code):
            onDisconnect(reason: reason.isEmpty ? "code \(code)" : reason)
            scheduleReconnectIfNeeded()
        case .text(let string):
            handle(string)
        case .binary(let data):
            if let s = String(data: data, encoding: .utf8) {
                handle(s)
            }
        case .cancelled:
            onDisconnect()
            scheduleReconnectIfNeeded()
        case .error(let error):
            onDisconnect(reason: error?.localizedDescription ?? "")
            scheduleReconnectIfNeeded()
        case .ping, .pong, .viabilityChanged, .reconnectSuggested, .peerClosed:
            break
        }
    }
}
