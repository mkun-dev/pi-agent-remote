import Foundation
import Combine

/// 负责 UI 交互 + WebSocket 通信
class ChatViewModel: ObservableObject {
    let conversationStore = ConversationStore()
    @Published var inputText: String = ""
    @Published var showModelPicker = false
    @Published var isLoadingSessions = false
    @Published var isSwitchingModel = false
    /// 当前激活的 Tab（0=聊天 1=文件 2=活动 3=设置）。由 Workspace/Chat 联动切换。
    @Published var activeTab: Int = 0
    
    private var ws: WebSocketManager
    private let settings: SettingsStore
    private var cancellables = Set<AnyCancellable>()
    
    private var pendingImageUploads: [(messageId: String, attachmentId: String, fileName: String)] = []
    private var confirmedMediaFileNames: Set<String> = []
    /// 记录已做过 first-agent-sync 的 agentId（按 agent 记忆，避免重复请求；切 agent 后对新 agent 重新生效）
    private var lastSyncedAgentId: String?
    /// 程序化 switchTarget 期间置位，抑制 $currentAgentId sink 的 bootstrap，避免双快照（B2）
    private var isSwitchingTarget = false
    private var nextSnapshotGeneration = 0
    private var lastActiveSnapshotAt: Date?
    
    init(settings: SettingsStore = SettingsStore()) {
        self.settings = settings
        self.ws = WebSocketManager(
            host: settings.host,
            port: settings.port,
            token: settings.token,
            clientId: settings.clientId
        )
        bind()
    }
    
    private func bind() {
        // Model picker 触发由 ConversationStore（RemoteEvent 驱动）统一管理
        conversationStore.$modelPickerRequested
            .receive(on: DispatchQueue.main)
            .filter { $0 }
            .sink { [weak self] _ in
                self?.showModelPicker = true
            }
            .store(in: &cancellables)
        conversationStore.$modelPickerRequested
            .receive(on: DispatchQueue.main)
            .filter { !$0 }
            .sink { [weak self] _ in
                self?.showModelPicker = false
            }
            .store(in: &cancellables)

        // P4：收到 history.rewound 后，把被撤回的原消息文本回填到输入框。
        conversationStore.$pendingRewoundDraft
            .receive(on: DispatchQueue.main)
            .compactMap { $0 }
            .sink { [weak self] _ in
                guard let self = self else { return }
                self.inputText = self.conversationStore.consumePendingRewoundDraft() ?? ""
            }
            .store(in: &cancellables)
        
        ws.onSessionSwitchAck = { [weak self] sessionFile, ok in
            guard let self = self else { return }
            if ok {
                self.conversationStore.beginSessionSwitch(expectedSessionFile: sessionFile)
                self.requestTargetSnapshot(reason: "session-switch")
            }
        }
        
        ws.onDeliveryResult = { [weak self] id, ok in
            self?.conversationStore.updateMessageDelivery(id: id, delivery: ok ? .sent : .failed)
            if !ok {
                self?.applyAgentStateEvent(.remoteStatus(status: "error", tool: nil, description: "PC 离线或消息未送达"))
            }
        }
        
        ws.onModelSelectAck = { _, _ in
            // 结果由 RemoteEvent → ConversationStore 统一处理；这里只保留兼容回调占位。
        }
        
        ws.onConnected = { [weak self] in
            guard let self = self else { return }
            self.ws.setPreferredTargetAgentId(self.conversationStore.currentAgentId)
            self.requestTargetSnapshot(reason: "connect")
        }
        
        // 连接/断开状态同步到 ConversationStore（唯一业务状态源）
        ws.onConnectionStateChanged = { [weak self] snapshot in
            self?.conversationStore.updateConnectionState(snapshot)
        }
        
        ws.onRemoteEvent = { [weak self] event in
            self?.conversationStore.accept(event)
        }
        
        ws.onTargetAgentOffline = { [weak self] in
            // 目标窗口离线：即时 fallback，随后 $currentAgentId 变化触发 bootstrap 快照（N1）
            self?.conversationStore.handleTargetAgentOffline()
        }
        
        ws.onAgentStateEvent = { [weak self] event in
            // 远端 Agent 事件已由 store.accept() 统一处理（同一消息会同时触发
            // onRemoteEvent 和 onAgentStateEvent）。这里丢弃远端事件，避免双重处理。
            // 仅本地触发的事件（requestSent/disconnected 等）才需要显式调用 store。
            guard let self = self else { return }
            switch event {
            case .requestSent, .disconnected:
                DispatchQueue.main.async {
                    self.conversationStore.applyLocalAgentEvent(event)
                }
            default:
                break
            }
        }

        // Media status confirmation reacts to ConversationStore.
        // 只在消息数量变化时检查（新增保存确认消息），避免 streaming delta 高频触发。
        conversationStore.$messages
            .map(\.count)
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.processMediaStatusFromStore()
            }
            .store(in: &cancellables)

        // 监听在线窗口列表变化：首次发现有在线窗口时，补充同步模型与用量。
        // 解决 iOS 连接瞬间 relay.agents 尚未到达导致的时序竞态。
        conversationStore.$agents
            .map { !$0.isEmpty }
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] hasAgents in
                guard let self = self else { return }
                // 按 agent 记忆：每个 agent 首次出现时同步一次，切回/切换到新 agent 仍会触发（B1）
                let currentAgent = self.conversationStore.currentAgentId
                if hasAgents && self.lastSyncedAgentId != currentAgent {
                    self.lastSyncedAgentId = currentAgent
                    self.requestTargetSnapshot(reason: "first-agent-sync")
                }
            }
            .store(in: &cancellables)
        
        conversationStore.$currentAgentId
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] agentId in
                guard let self = self else { return }
                self.ws.setPreferredTargetAgentId(agentId)
                // 程序化 switchTarget 已自带显式快照，此处抑制避免双快照（B2）
                if self.isSwitchingTarget { return }
                if self.conversationStore.isConnected,
                   agentId != nil,
                   self.conversationStore.sessionState == nil,
                   self.conversationStore.usageInfo == nil,
                   self.conversationStore.availableModels.isEmpty,
                   self.conversationStore.messages.isEmpty {
                    self.requestTargetSnapshot(reason: "agent-bootstrap")
                }
            }
            .store(in: &cancellables)
        
        conversationStore.$lastModelSelection
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.isSwitchingModel = false
            }
            .store(in: &cancellables)
        
        conversationStore.$sessionProjectionRevision
            .dropFirst()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                self?.resetSessionScopedUIState()
            }
            .store(in: &cancellables)
    }

    // MARK: - Media Status (driven from Store)

    private func processMediaStatusFromStore() {
        // 仅在有新增的非 streaming 消息时才检查媒体状态，避免高频 delta 时无效遍历。
        let recent = Array(conversationStore.messages.suffix(6))
        for msg in recent.reversed() {
            if msg.kind == .text && msg.sender == .pi {
                if msg.content.hasPrefix("📁 已保存:") {
                    let rawPath = String(msg.content.dropFirst("📁 已保存:".count))
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let fileName = (rawPath.replacingOccurrences(of: "\\", with: "/") as NSString).lastPathComponent
                    confirmedMediaFileNames.insert(fileName)
                    if !pendingImageUploads.isEmpty {
                        let pending = pendingImageUploads.removeFirst()
                        conversationStore.updateAttachmentStatus(messageId: pending.messageId, attachmentId: pending.attachmentId, status: .completed, error: nil)
                    } else {
                        conversationStore.updateLatestAttachment(named: fileName, status: .completed, error: nil)
                    }
                    conversationStore.markMediaStatusMessage(msg.id)
                    return
                } else if msg.content.hasPrefix("❌ 保存失败") || msg.content.hasPrefix("❌ 未收到文件内容") {
                    if !pendingImageUploads.isEmpty {
                        let pending = pendingImageUploads.removeFirst()
                        conversationStore.updateAttachmentStatus(messageId: pending.messageId, attachmentId: pending.attachmentId, status: .failed, error: "PC 保存图片失败")
                    } else {
                        conversationStore.updateLatestPendingAttachment(status: .failed, error: "PC 保存图片失败")
                    }
                    conversationStore.markMediaStatusMessage(msg.id)
                    return
                }
            } else if msg.kind == .fileChanges, !msg.fileChanges.isEmpty {
                let attachmentNames = Set(conversationStore.messages.flatMap(\.attachments).map(\.fileName))
                let changedNames = Set(msg.fileChanges.map { ($0.normalizedPath as NSString).lastPathComponent })
                if changedNames.allSatisfy({ attachmentNames.contains($0) || confirmedMediaFileNames.contains($0) }) {
                    conversationStore.markMediaStatusMessage(msg.id)
                    confirmedMediaFileNames.subtract(changedNames)
                    return
                }
            }
        }
    }
    
    private func resetSessionScopedUIState() {
        inputText = ""
        showModelPicker = false
        isSwitchingModel = false
        pendingImageUploads.removeAll()
        confirmedMediaFileNames.removeAll()
    }
    
    @discardableResult
    private func requestTargetSnapshot(reason: String) -> Int {
        nextSnapshotGeneration += 1
        let generation = nextSnapshotGeneration
        conversationStore.beginSnapshot(generation: generation, reason: reason)
        ws.requestSessionResume(generation: generation)
        ws.requestQuestionnaireSync(generation: generation)
        ws.requestUsage(generation: generation)
        ws.requestModelList(generation: generation)
        return generation
    }
    
    // MARK: - Agent State (本地事件)
    
    private func applyAgentStateEvent(_ event: AgentStateEvent) {
        conversationStore.applyLocalAgentEvent(event)
    }
    
    // MARK: - Public API
    
    func connect() { ws.connect() }
    func disconnect() { applyAgentStateEvent(.disconnected); ws.disconnect() }
    func reconnectWithCurrentSettings() { ws.updateConnection(host: settings.host, port: settings.port, token: settings.token) }
    func requestSessionResume() { _ = requestTargetSnapshot(reason: "manual-session-resume") }
    func requestUsage() { _ = requestTargetSnapshot(reason: "manual-usage-refresh") }
    func refreshSnapshot(reason: String) -> Int { requestTargetSnapshot(reason: reason) }
    
    func selectModel(_ modelId: String) {
        isSwitchingModel = true
        let requestId = UUID().uuidString
        conversationStore.beginModelSelection(requestId: requestId, modelId: modelId)
        ws.selectModel(modelId, selectionRequestId: requestId)
        // Auto-clear the switching flag after a reasonable timeout in case ack is lost
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            self?.isSwitchingModel = false
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.conversationStore.modelPickerRequested = false
        }
    }
    
    func handleAppBecameActive() {
        if conversationStore.isConnected {
            let now = Date()
            if let last = lastActiveSnapshotAt, now.timeIntervalSince(last) < 2 {
                return
            }
            lastActiveSnapshotAt = now
            _ = requestTargetSnapshot(reason: "background-resume")
        } else {
            connect()
        }
    }
    
    func submitQuestionnaire(_ answers: [ProtocolMessage.AnswerPayload]) {
        ws.submitQuestionnaire(answers, questionnaireId: conversationStore.activeQuestionnaireId)
        // iOS 自身提交：立即关闭弹窗（不等服务器回显）
        conversationStore.dismissQuestionnaire()
    }

    // MARK: - Workspace Explorer

    func loadWorkspaceDirectory(path: String = "") {
        ws.requestWorkspaceList(path: path)
    }

    func loadWorkspaceFile(path: String) {
        ws.requestWorkspaceFile(path: path)
    }

    /// 全项目文件名搜索（不限于已加载目录）
    func searchWorkspace(query: String) {
        ws.requestWorkspaceSearch(query: query)
    }

    /// Diff「在Workspace打开」：切到文件 Tab + 请求文件内容 + 标记待打开。
    func openFileInWorkspace(path: String) {
        conversationStore.setPendingWorkspaceFile(path)
        if conversationStore.workspaceFiles[path] == nil {
            loadWorkspaceFile(path: path)
        }
        // tab 索引：0=首页 1=聊天 2=文件 3=设置
        activeTab = 2
    }
    
    func switchTarget(to agentId: String) {
        // 抑制 $currentAgentId sink 的 bootstrap，由本方法显式发一次快照（避免双快照 B2）
        isSwitchingTarget = true
        defer { isSwitchingTarget = false }
        applyAgentStateEvent(.disconnected)
        conversationStore.setCurrentAgentId(agentId)
        ws.switchTarget(to: agentId)
        conversationStore.reset()
        _ = requestTargetSnapshot(reason: "agent-switch")
    }
    
    func toggleToolGroup(messageId: String) { conversationStore.toggleToolGroup(messageId: messageId) }
    func toggleFileChanges(messageId: String) { conversationStore.toggleFileChanges(messageId: messageId) }
    func toggleAgentTrace(messageId: String) { conversationStore.toggleAgentTrace(messageId: messageId) }
    
    func switchToSession(_ item: RemoteSessionListItem) {
        guard let path = item.path, !path.isEmpty else { return }
        ws.sendSessionSwitch(path)
    }
    
    func requestSessionList() {
        isLoadingSessions = true
        ws.sendSessionList()
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.isLoadingSessions = false }
    }
    
    func updateHostPort(host: String, port: Int, token: String = "") {
        settings.host = host; settings.port = port; settings.token = token
        ws.updateConnection(host: host, port: port, token: token)
    }
    
    func send(steer: Bool = false) {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        inputText = ""
        
        let connected = conversationStore.isConnected && conversationStore.isAgentOnline
        guard connected else {
            applyAgentStateEvent(.remoteStatus(status: "error", tool: nil, description: "未连接，无法发送"))
            conversationStore.appendSystemMessage(Message(id: UUID().uuidString, sender: .system, content: "未连接，无法发送。请先连接。", timestamp: Date(), kind: .status))
            return
        }

        // /model 无参数 → 请求列表并打开选择器（不发往 PC）；带参数则交给 extension 切换
        if text == "/model" || text == "/model " {
            conversationStore.requestModelPicker()
            _ = requestTargetSnapshot(reason: "model-picker")
            return
        }

        if !text.hasPrefix("/") { applyAgentStateEvent(.requestSent) }
        
        let needsAck = settings.port != 3001
        let userMsg = Message(id: UUID().uuidString, sender: .user, content: text, timestamp: Date(), kind: .text, delivery: needsAck ? .sending : .sent)
        conversationStore.recordLocalUserMessage(userMsg)
        // 附带待发送的文件上下文（来自 Workspace "询问Agent"），发送后清除
        let ctx = conversationStore.consumePendingFileContext()
        ws.send(text, id: userMsg.id, context: ctx, steer: steer)
        
        guard needsAck else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            self?.conversationStore.updateMessageDelivery(id: userMsg.id, delivery: .failed)
        }
    }

    /// P3：停止当前 Agent turn（发 /stop，扩展端中断 + 清队列）。仅在 Agent 忙时可用。
    func stop() {
        let connected = conversationStore.isConnected && conversationStore.isAgentOnline
        guard connected else { return }
        ws.send("/stop", id: UUID().uuidString)
        conversationStore.appendSystemMessage(Message(
            id: UUID().uuidString, sender: .system,
            content: "⏹ 已请求停止当前任务",
            timestamp: Date(), kind: .status
        ))
    }

    /// P4：git 式撤回到指定用户消息之前（目标及其后消息从上下文消失）。
    /// 参数 messageID 必须对应 messages 中某条用户文本消息。
    func rewindToUserMessage(messageID: String) {
        let connected = conversationStore.isConnected && conversationStore.isAgentOnline
        guard connected else {
            conversationStore.appendSystemMessage(Message(
                id: UUID().uuidString, sender: .system,
                content: "未连接，无法撤回。请先连接。",
                timestamp: Date(), kind: .status
            ))
            return
        }
        guard !conversationStore.agentState.isWorking else {
            conversationStore.appendSystemMessage(Message(
                id: UUID().uuidString, sender: .system,
                content: "⏳ Agent 处理中，无法撤回，请等它空闲后再试。",
                timestamp: Date(), kind: .status
            ))
            return
        }
        // 只统计“已送达的文本用户消息”，与 UI 里真正显示编辑按钮的集合保持一致。
        // 这样 failed/sending 的本地临时消息不会参与 rewind 计数，避免与扩展端 session branch 错位。
        let userMessages = conversationStore.messages.filter {
            $0.sender == .user && $0.kind == .text && $0.delivery == .sent
        }
        guard let index = userMessages.firstIndex(where: { $0.id == messageID }) else {
            conversationStore.appendSystemMessage(Message(
                id: UUID().uuidString, sender: .system,
                content: "❌ 未找到要撤回的用户消息。",
                timestamp: Date(), kind: .status
            ))
            return
        }
        let nFromEnd = userMessages.count - index
        ws.requestRewind(userMessageIndexFromEnd: nFromEnd)
    }
    
    func uploadMedia(images: [PreparedImageUpload], caption: String) {
        guard !images.isEmpty else { return }
        let messageId = UUID().uuidString
        let attachments = images.map { image -> Attachment in
            let localPath = ImageCache.shared.store(image.data, key: image.cacheKey)
            return Attachment(id: image.id, type: .image, fileName: image.fileName, localPath: localPath, cacheKey: image.cacheKey, status: .uploading)
        }
        let imageMessage = Message(id: messageId, sender: .user, content: caption.trimmingCharacters(in: .whitespacesAndNewlines), timestamp: Date(), kind: .image, delivery: .sending, attachments: attachments)
        conversationStore.recordLocalUserMessage(imageMessage)
        
        let connected = conversationStore.isConnected && conversationStore.isAgentOnline
        guard connected else {
            for image in images {
                conversationStore.updateAttachmentStatus(messageId: messageId, attachmentId: image.id, status: .failed, error: "未连接到 Pi")
            }
            conversationStore.updateMessageDelivery(id: messageId, delivery: .failed)
            return
        }
        
        for (offset, image) in images.enumerated() {
            pendingImageUploads.append((messageId, image.id, image.fileName))
            ws.uploadMedia(fileName: image.fileName, base64: image.base64)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.9 + Double(offset) * 0.12) { [weak self] in
                guard let self else { return }
                let ok = conversationStore.isConnected && conversationStore.isAgentOnline
                self.conversationStore.updateAttachmentStatus(messageId: messageId, attachmentId: image.id, status: ok ? .completed : .failed, error: ok ? nil : "连接已断开")
                if !ok { self.pendingImageUploads.removeAll { $0.messageId == messageId && $0.attachmentId == image.id } }
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.pendingImageUploads.removeAll { $0.messageId == messageId && $0.attachmentId == image.id }
            }
        }
        
        if !caption.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            applyAgentStateEvent(.requestSent)
            ws.send(caption, id: messageId)
        }
    }
    
    func uploadMedia(fileName: String, base64: String) {
        guard let data = Data(base64Encoded: base64) else { return }
        uploadMedia(images: [PreparedImageUpload(id: UUID().uuidString, fileName: fileName, data: data, base64: base64, cacheKey: ImageCache.cacheKey(for: data))], caption: "")
    }
}
