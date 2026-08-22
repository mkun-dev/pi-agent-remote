import Combine
import Foundation

/// RemoteEvent 的增量状态容器。
/// 当前先承接统一事件、Agent 状态、Streaming 影子消息、Trace、Activity 与 Logs；
/// Chat 仍使用旧 Message 链，待后续逐步迁移，避免一次性重写。
final class ConversationStore: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var connectionStatus: String = "已断开"
    @Published private(set) var isAgentOnline = true
    @Published private(set) var messages: [Message] = []
    @Published private(set) var currentTrace: AgentTrace?
    @Published private(set) var activityEvents: [ActivityEvent] = []
    @Published private(set) var logs: [LogEntry] = []
    @Published private(set) var agentState: AgentStatus = .idle
    @Published private(set) var sessionState: RemoteSessionInfo?
    @Published private(set) var sessionList: [RemoteSessionListItem] = []
    @Published private(set) var sessionProjectionRevision: UInt64 = 0
    @Published private(set) var activeStreamingMessageID: String?
    @Published private(set) var streamingRevision: UInt64 = 0
    @Published private(set) var currentSnapshotGeneration: Int = 0
    @Published private(set) var pendingUsageGeneration: Int?
    @Published private(set) var pendingModelGeneration: Int?
    @Published private(set) var latestAcceptedUsageGeneration: Int?
    @Published private(set) var latestAcceptedModelGeneration: Int?
    // Model & Usage — single source of truth (RemoteEvent driven)
    @Published private(set) var availableModels: [String] = []
    @Published private(set) var currentModel: String?
    @Published private(set) var usageInfo: RemoteUsageEvent?
    /// UI 请求打开模型选择器（由 /model 命令或用户操作触发，非聊天消息）
    @Published var modelPickerRequested = false
    @Published private(set) var agents: [RemoteAgentDescriptor] = []
    @Published private(set) var currentAgentId: String?
    
    // MARK: - 诊断（定位用量/模型不显示问题；确认后可删除）
    @Published private(set) var diagLastRawUsage: String?      // 收到的最后一条 usage 事件原始内容
    @Published private(set) var diagLastRawModel: String?      // 收到的最后一条 model.list 事件原始内容
    @Published private(set) var diagLastDrop: String?          // shouldIgnore 最后一次丢弃原因
    @Published private(set) var diagLastGenDrop: String?       // stale generation 最后一次丢弃原因
    @Published private(set) var diagAcceptCount: Int = 0       // 成功 accept 的事件计数
    @Published private(set) var questionnaireQuestions: [ProtocolMessage.QuestionPayload] = []
    @Published var showQuestionnaire = false
    private(set) var activeQuestionnaireId: String?

    // Workspace Explorer（只读）
    /// 当前目录（"" = 项目根）的 children，key = 目录相对路径
    @Published private(set) var workspaceChildren: [String: [RemoteWorkspaceNode]] = [:]
    /// 当前查看的文件缓存（workspace.file），key = 文件相对路径
    @Published private(set) var workspaceFiles: [String: RemoteWorkspaceFile] = [:]
    /// 兼容旧文本查看链路：仅缓存文本内容，key = 文件相对路径
    @Published private(set) var workspaceFileContent: [String: String] = [:]
    /// workspace 错误（key = 请求 path，避免多个请求互相覆盖）
    @Published private(set) var workspaceErrors: [String: String] = [:]
    @Published private(set) var workspaceRootName: String = ""
    /// 全局搜索结果（workspace.searchResult）。query 为空串表示无活跃搜索。
    @Published private(set) var workspaceSearchResult: RemoteWorkspaceSearchResult?
    /// 是否正在等待搜索响应（UI 显示 loading）
    @Published private(set) var workspaceSearching = false
    /// 待发送的文件上下文（来自 Workspace「询问Agent」）。send() 时消费并清除。
    @Published private(set) var pendingFileContext: MessageContext?
    /// 待在 Workspace 打开的文件路径（来自 Diff「在Workspace打开」）。WorkspaceExplorerView 出现时消费。
    @Published private(set) var pendingWorkspaceFile: String?
    /// 最近修改的文件（来自 file.change，Workspace 首页展示）。按时间倒序，上限 50。
    @Published private(set) var recentChanges: [RecentFileChange] = []
    private let recentChangesMaxCount = 50
    /// 文件内容 LRU 访问顺序（最近访问在尾部）。超出上限时淘汰头部。
    private var workspaceFileLRU: [String] = []
    private let workspaceFileMaxCount = 50
    /// session.switch_ack 收到后等待新会话权威快照到达；期间丢弃旧会话迟到事件。
    private var pendingSessionFile: String?
    private var pendingModelSelectionRequestId: String?
    private var modelSelectionLock: ModelSelectionLock?
    
    private struct ModelSelectionLock {
        let requestId: String
        let modelId: String
        let generation: Int
    }
    
    private var stateReducer = AgentStateReducer()
    /// Agent 完成/出错后自动回 idle 的兜底计时器（防止状态卡死）。
    private var agentStateResetWorkItem: DispatchWorkItem?
    private var assistantIndexByID: [String: Int] = [:]
    /// 每个 assistant 流最后接受的 delta 序号，防止重发/乱序污染正文。
    private var assistantLastSequenceByID: [String: Int] = [:]
    /// 已收口的 assistant 流，阻止迟到 delta 重新把 UI 置回“输入中”。
    private var completedAssistantIDs = Set<String>()
    private var toolMessageIndex: Int?
    private var toolMessageIndexByCallID: [String: Int] = [:]
    private var toolEntryIndexByCallID: [String: Int] = [:]
    private var toolLogIndexByCallID: [String: Int] = [:]
    private var activityIndexByID: [String: Int] = [:]
    private var fileMessageIndex: Int?
    private var fileIndexByPath: [String: Int] = [:]
    private var turnID = UUID().uuidString
    private var eventSequence: UInt64 = 0
    private var logCharacters = 0
    
    private let maxLogs = 5_000
    private let maxLogCharacters = 5_000_000
    /// Activity 事件上限，防止无限增长。
    private let maxActivities = 2_000
    
    /// Transport 层通过此方法更新 WebSocket 连接状态。
    func updateConnectionState(connected: Bool, status: String) {
        isConnected = connected
        connectionStatus = status
        if !connected {
            cancelAgentStateReset()
            agentState = .idle
            stateReducer = AgentStateReducer()
            availableModels = []
            currentModel = nil
            usageInfo = nil
            lastModelSelection = nil
            modelPickerRequested = false
            pendingUsageGeneration = nil
            pendingModelGeneration = nil
            pendingModelSelectionRequestId = nil
            modelSelectionLock = nil
        }
    }

    /// 处理本地（非 RemoteEvent）Agent 状态事件。
    /// 远端状态已由 accept() → handleAgent 处理；这里仅处理本地 UI 触发的状态。
    func applyLocalAgentEvent(_ event: AgentStateEvent) {
        cancelAgentStateReset()
        agentState = stateReducer.reduce(event)
        scheduleAgentStateResetIfNeeded()
    }

    /// completed/error 后延迟自动回 idle，防止状态指示器永久停在“完成/出错”。
    private func scheduleAgentStateResetIfNeeded() {
        let delay: TimeInterval
        switch agentState {
        case .completed: delay = 3
        case .error:     delay = 4
        default:         return
        }
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            switch self.agentState {
            case .completed, .error:
                self.agentState = .idle
                self.stateReducer = AgentStateReducer()
            default:
                break
            }
        }
        agentStateResetWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: workItem)
    }

    private func cancelAgentStateReset() {
        agentStateResetWorkItem?.cancel()
        agentStateResetWorkItem = nil
    }

    #if DEBUG
    /// 预览/测试用：直接加载示例消息
    func loadPreviewMessages(_ msgs: [Message]) {
        messages = msgs
    }
    #endif

    /// 用户请求打开模型选择器（/model 无参数命令）。
    func requestModelPicker() {
        modelPickerRequested = true
    }
    
    func beginSnapshot(generation: Int, reason: String) {
        currentSnapshotGeneration = max(currentSnapshotGeneration, generation)
        pendingUsageGeneration = generation
        pendingModelGeneration = generation
        RemoteLogger.session("[SNAPSHOT] start generation=\(generation) reason=\(reason) agent=\(currentAgentId ?? "nil") session=\(sessionLabel(sessionState))")
    }
    
    func beginModelSelection(requestId: String, modelId: String) {
        pendingModelSelectionRequestId = requestId
        RemoteLogger.model("[MODEL] begin selection requestId=\(requestId) model=\(modelId) generation=\(currentSnapshotGeneration)")
    }
    
    /// 中继层通过此方法更新 PC (agent) 在线状态。
    func updateAgentOnline(_ online: Bool) {
        isAgentOnline = online
    }
    
    /// 问卷层通过此方法设置当前待答问卷。
    func setQuestionnaire(id: String?, questions: [ProtocolMessage.QuestionPayload]) {
        activeQuestionnaireId = id
        questionnaireQuestions = questions
        showQuestionnaire = !questions.isEmpty
    }
    
    /// PC 端已作答，关闭本地问卷。
    func dismissQuestionnaire() {
        showQuestionnaire = false
        activeQuestionnaireId = nil
        questionnaireQuestions = []
    }

    /// UI 发起搜索时标记 loading（结果到达后由 handleWorkspace 自动清除）。
    func beginWorkspaceSearch() {
        workspaceSearching = true
    }

    /// UI 清空搜索框时清除搜索结果与 loading 状态。
    func clearWorkspaceSearch() {
        workspaceSearchResult = nil
        workspaceSearching = false
    }

    /// Workspace「询问Agent」调用：设置待发送的文件上下文，send() 时消费。
    func setPendingFileContext(files: [String], selection: String? = nil) {
        pendingFileContext = MessageContext(workspaceFiles: files, selection: selection)
    }

    /// send() 消费并清除上下文；返回 nil 表示无上下文。
    func consumePendingFileContext() -> MessageContext? {
        let ctx = pendingFileContext
        pendingFileContext = nil
        return ctx
    }

    /// UI 取消询问（未发送即关闭）时清除。
    func clearPendingFileContext() {
        pendingFileContext = nil
    }
    
    /// 文件列表/搜索结果使用：返回该路径最近一次变更类型（若有）。
    func latestChangeType(for path: String) -> FileChangeType? {
        recentChanges.first { $0.path == path }?.changeType
    }
    
    /// FileViewer「查看Diff」使用：优先从聊天里的 fileChanges 里找带统计的变更；
    /// 若未找到则退回 recentChanges 构造一个轻量 FileChange。
    func latestFileChange(for path: String) -> FileChange? {
        let normalized = path.replacingOccurrences(of: "\\", with: "/")
        for message in messages.reversed() where message.kind == .fileChanges {
            if let hit = message.fileChanges.first(where: { $0.normalizedPath == normalized }) {
                return hit
            }
        }
        if let recent = recentChanges.first(where: { $0.path == normalized }) {
            return FileChange(
                path: recent.path,
                type: recent.changeType,
                additions: recent.additions,
                deletions: recent.deletions
            )
        }
        return nil
    }

    /// Diff「在Workspace打开」调用：标记待打开文件，切到文件 Tab 后由 WorkspaceExplorerView 消费。
    func setPendingWorkspaceFile(_ path: String) {
        pendingWorkspaceFile = path
    }

    /// WorkspaceExplorerView 消费并清除；返回 nil 表示无待打开文件。
    func consumePendingWorkspaceFile() -> String? {
        let p = pendingWorkspaceFile
        pendingWorkspaceFile = nil
        return p
    }
    
    func accept(_ event: RemoteEvent) {
        // 【诊断】捕获 usage/model 原始事件（定位不显示问题）
        if case .usage(let u) = event.payload {
            diagLastRawUsage = "model=\(u.model ?? "nil") tokens=\(u.totalTokens) gen=\(event.generation ?? -1) scope.agent=\(event.scope.agentId ?? "nil") scope.session=\(event.scope.sessionId ?? "nil")"
        }
        if case .model(let m) = event.payload {
            if case .list(let ids) = m {
                diagLastRawModel = "\(ids.count) models gen=\(event.generation ?? -1) scope.agent=\(event.scope.agentId ?? "nil")"
            }
        }
        if shouldIgnore(event) {
            // 【诊断】记录 usage/model 被丢弃的原因
            captureDropReason(event, stage: "shouldIgnore")
            return
        }
        if shouldIgnoreStaleGeneration(event) {
            captureDropReason(event, stage: "staleGeneration")
            return
        }
        diagAcceptCount += 1
        eventSequence &+= 1

        // Conversation 安全过滤（防御性白名单，第七阶段）：
        // 只有 ConversationMessageFilter.allowsMessageEntry == true 的事件才允许进入消息列表。
        // 非白名单事件（workspace.* / model.* / usage.* / relay.* / agent.status /
        // session 元数据 / questionnaire.*）只更新状态投影，绝不生成 Message。
        // 未来新增事件默认拒绝——必须显式加入白名单才能进入聊天。
        let messageEntryAllowed = ConversationMessageFilter.allowsMessageEntry(event.payload)
        #if DEBUG
        if !messageEntryAllowed {
            RemoteLogger.event("[FILTER] system event → 状态投影 only: \(ConversationMessageFilter.name(of: event.payload)) id=\(event.id)")
        }
        #endif

        switch event.payload {
        case .agent(let value):
            handleAgent(value, event: event)
        case .assistant(let value):
            handleAssistant(value, event: event)
        case .tool(let value):
            handleTool(value, event: event)
        case .file(let value):
            handleFile(value, event: event)
        case .session(let value):
            handleSession(value, event: event)
        case .model(let value):
            handleModel(value, event: event)
        case .questionnaire(let value):
            handleQuestionnaire(value, event: event)
        case .usage(let value):
            handleUsage(value, event: event)
        case .media(let value):
            handleMedia(value, event: event)
        case .relay(let value):
            handleRelay(value)
        case .workspace(let value):
            handleWorkspace(value, event: event)
        case .unknown:
            break
        }
    }
    
    /// 【诊断】只记录 usage/model 事件的丢弃原因（其他事件丢弃不影响定位）
    private func captureDropReason(_ event: RemoteEvent, stage: String) {
        let isUsageModel: Bool
        if case .usage = event.payload { isUsageModel = true }
        else if case .model = event.payload { isUsageModel = true }
        else { isUsageModel = false }
        guard isUsageModel else { return }
        let reason = "[\(stage)] gen=\(event.generation ?? -1) curGen=\(currentSnapshotGeneration) agent=\(event.scope.agentId ?? "nil") curAgent=\(currentAgentId ?? "nil") session=\(event.scope.sessionId ?? "nil") curSession=\(sessionState?.sessionId ?? "nil") pendingFile=\(pendingSessionFile ?? "nil")"
        if stage == "shouldIgnore" { diagLastDrop = reason }
        else { diagLastGenDrop = reason }
    }
    
    private func shouldIgnore(_ event: RemoteEvent) -> Bool {
        if case .relay = event.payload { return false }
        
        let requiresScope = eventRequiresScope(event.payload)
        let hasAgentScope = !(event.scope.agentId ?? "").isEmpty
        let hasSessionScope = !(event.scope.sessionId ?? "").isEmpty || !(normalizeSessionFile(event.scope.sessionFile) ?? "").isEmpty
        
        if requiresScope, currentAgentId != nil, !hasAgentScope {
            RemoteLogger.event("[EVENT] ignore missing agent scope id=\(event.id)")
            return true
        }
        if let currentAgentId, let eventAgentId = event.scope.agentId,
           !eventAgentId.isEmpty, eventAgentId != currentAgentId {
            RemoteLogger.event("[EVENT] ignore agent mismatch current=\(currentAgentId) event=\(eventAgentId) type=\(event.id)")
            return true
        }
        
        if case .session = event.payload {
            if pendingSessionFile != nil || sessionIdentity(sessionState) != nil {
                return !hasSessionScope && requiresScope
            }
            return false
        }
        
        if requiresScope,
           (pendingSessionFile != nil || sessionIdentity(sessionState) != nil),
           !hasSessionScope {
            RemoteLogger.event("[EVENT] ignore missing session scope id=\(event.id)")
            return true
        }
        
        if let expectedFile = pendingSessionFile {
            if let eventFile = normalizeSessionFile(event.scope.sessionFile), !eventFile.isEmpty {
                if eventFile != expectedFile {
                    RemoteLogger.event("[EVENT] ignore pending-session mismatch expected=\(expectedFile) event=\(eventFile) id=\(event.id)")
                    return true
                }
            } else if event.scope.sessionId == nil {
                RemoteLogger.event("[EVENT] ignore unscoped event during session switch id=\(event.id)")
                return true
            }
        }
        
        if pendingSessionFile == nil,
           let currentSessionId = sessionState?.sessionId,
           let eventSessionId = event.scope.sessionId,
           !currentSessionId.isEmpty, !eventSessionId.isEmpty,
           currentSessionId != eventSessionId {
            RemoteLogger.event("[EVENT] ignore sessionId mismatch current=\(currentSessionId) event=\(eventSessionId) id=\(event.id)")
            return true
        }
        
        if pendingSessionFile == nil,
           let currentSessionFile = normalizeSessionFile(sessionState?.sessionFile),
           let eventSessionFile = normalizeSessionFile(event.scope.sessionFile),
           !currentSessionFile.isEmpty, !eventSessionFile.isEmpty,
           currentSessionFile != eventSessionFile {
            RemoteLogger.event("[EVENT] ignore sessionFile mismatch current=\(currentSessionFile) event=\(eventSessionFile) id=\(event.id)")
            return true
        }
        
        return false
    }
    
    private func eventRequiresScope(_ payload: RemoteEvent.Payload) -> Bool {
        switch payload {
        case .relay, .unknown:
            return false
        default:
            return true
        }
    }
    
    private func shouldIgnoreStaleGeneration(_ event: RemoteEvent) -> Bool {
        switch event.payload {
        case .usage:
            if let generation = event.generation, generation < currentSnapshotGeneration {
                RemoteLogger.usage("[STORE] ignore stale usage generation=\(generation) current=\(currentSnapshotGeneration)")
                return true
            }
        case .model(let value):
            if case .list = value {
                guard let generation = event.generation else {
                    if pendingModelGeneration != nil {
                        RemoteLogger.model("[STORE] ignore model.list without generation current=\(currentSnapshotGeneration)")
                        return true
                    }
                    return false
                }
                if generation < currentSnapshotGeneration {
                    RemoteLogger.model("[STORE] ignore stale model.list generation=\(generation) current=\(currentSnapshotGeneration)")
                    return true
                }
            }
        default:
            break
        }
        return false
    }

    /// 出站用户消息不经过入站 Decoder；由 ChatViewModel 在现有发送点补充到统一投影。
    /// 追加系统/状态消息（供 ChatViewModel 调用，因为 messages 是 private(set)）。
    func appendSystemMessage(_ message: Message) {
        messages.append(message)
    }

    func recordLocalUserMessage(_ message: Message) {
        guard message.isUser else { return }
        messages.append(message)
        upsertActivity(ActivityEvent(
            id: "activity-user-\(message.id)",
            timestamp: message.timestamp,
            type: .userRequest,
            title: "用户请求",
            detail: compact(message.content, limit: 180)
        ))
    }
    
    /// 切换会话（同一 agent 窗口）时的轻量重置：
    /// 清空所有 session-scoped 投影，等待新会话的权威快照重新同步。
    func resetSessionProjection() {
        clearSessionScopedProjection(clearSessionState: false)
    }
    
    /// UI / Transport 切换到另一个会话文件时调用：
    /// 立即清空旧会话投影，并在新会话快照到达前屏蔽迟到事件。
    func beginSessionSwitch(expectedSessionFile: String?) {
        let normalized = normalizeSessionFile(expectedSessionFile)
        RemoteLogger.session("[SESSION] switch \(sessionLabel(sessionState)) -> \(normalized ?? "unknown")")
        clearSessionScopedProjection(clearSessionState: false)
        pendingSessionFile = normalized
    }
    
    /// 当前目标窗口切换（多 agent）时立即同步到 Store，避免旧窗口事件继续污染 UI。
    func setCurrentAgentId(_ agentId: String?) {
        guard currentAgentId != agentId else { return }
        RemoteLogger.session("[SESSION] agent \(currentAgentId ?? "nil") -> \(agentId ?? "nil")")
        currentAgentId = agentId
    }

    func reset() {
        clearSessionScopedProjection(clearSessionState: true)
        sessionList.removeAll()
    }
    
    private func handleAgent(_ value: RemoteAgentEvent, event: RemoteEvent) {
        switch value {
        case .input(let text):
            let message = Message(
                id: event.id,
                sender: .user,
                content: text,
                timestamp: event.timestamp,
                kind: .text
            )
            recordLocalUserMessage(message)
        case .output(let text, let isThinking):
            guard !text.isEmpty else { return }
            messages.append(Message(
                id: "remote-event:\(event.id):\(eventSequence)",
                sender: .pi,
                content: text,
                timestamp: event.timestamp,
                kind: isThinking ? .thinking : .text
            ))
        case .status(let status):
            if status.value == "receiving" {
                beginTurn(eventID: event.id)
            }
            // agent_end 是整轮完成的权威信号。assistant.end 可能因网络丢包、
            // Pi 的非文本回复或事件顺序异常没有抵达；此处必须兜底结束所有流式消息，
            // 否则 iOS 会一直显示“Pi 正在输入”，而 PC 已经完成。
            if status.value == "completed" || status.value == "error" || status.value == "idle" {
                finishStreamingMessages()
            }
            agentState = stateReducer.reduce(.remoteStatus(
                status: status.value,
                tool: status.tool,
                description: status.description
            ))
            scheduleAgentStateResetIfNeeded()
            updateTrace(status)
            updateActivity(status, event: event)
        }
    }
    
    private func handleAssistant(_ value: RemoteAssistantEvent, event: RemoteEvent) {
        switch value {
        case .start(let messageId):
            completedAssistantIDs.remove(messageId)
            assistantLastSequenceByID.removeValue(forKey: messageId)
            let index = ensureAssistant(messageId, timestamp: event.timestamp)
            activeStreamingMessageID = messages[index].id
            agentState = stateReducer.reduce(.assistantStarted)
        case .delta(let messageId, let text, let seq):
            guard !text.isEmpty, !completedAssistantIDs.contains(messageId) else { return }
            if let seq {
                let lastSeq = assistantLastSequenceByID[messageId] ?? 0
                guard seq > lastSeq else { return }
                assistantLastSequenceByID[messageId] = seq
            }
            let index = ensureAssistant(messageId, timestamp: event.timestamp)
            messages[index].content += text
            messages[index].isStreaming = true
            activeStreamingMessageID = messages[index].id
            streamingRevision &+= 1
            agentState = stateReducer.reduce(.assistantDelta)
        case .end(let messageId, let text):
            let index = ensureAssistant(messageId, timestamp: event.timestamp)
            // assistant.end 携带权威完整文本；Extension 与 streaming delta 使用同一份原始 Markdown，
            // 因此最终校正不会再造成标题层级跳变，同时可以修复丢失或截断的 delta。
            if let text, !text.isEmpty {
                messages[index].content = text
            }
            messages[index].isStreaming = false
            if activeStreamingMessageID == messages[index].id {
                activeStreamingMessageID = nil
            }
            streamingRevision &+= 1
            completedAssistantIDs.insert(messageId)
            agentState = stateReducer.reduce(.assistantEnded)
        }
    }
    
    private func handleTool(_ value: RemoteToolEvent, event: RemoteEvent) {
        switch value {
        case .start(let call):
            let input = call.input ?? ""
            let entry = ToolEntry(
                toolCallId: call.id,
                toolName: call.name,
                detail: input,
                status: .running
            )
            let messageIndex: Int
            let toolEntryIndex: Int
            if let index = toolMessageIndex, index < messages.count {
                toolEntryIndex = messages[index].toolEntries.count
                messages[index].toolEntries.append(entry)
                if !input.isEmpty { messages[index].content += "\n▶ \(call.name): \(input)" }
                messageIndex = index
            } else {
                messages.append(Message(
                    id: "remote-tools:\(turnID)",
                    sender: .pi,
                    content: "▶ \(call.name): \(input)",
                    timestamp: event.timestamp,
                    kind: .tool,
                    toolEntries: [entry]
                ))
                messageIndex = messages.count - 1
                toolEntryIndex = 0
                toolMessageIndex = messageIndex
            }
            toolMessageIndexByCallID[call.id] = messageIndex
            toolEntryIndexByCallID[call.id] = toolEntryIndex
            
            var trace = currentTrace ?? AgentTrace()
            trace.recordToolStarted(
                toolCallId: call.id,
                toolName: call.name,
                detail: input
            )
            currentTrace = trace
            agentState = stateReducer.reduce(.toolStarted(tool: call.name, description: input))
            
            let presentation = ToolPresentation.resolve(name: call.name, input: input)
            let log = LogEntry(
                id: "log-tool-\(call.id)",
                timestamp: event.timestamp,
                level: .info,
                type: presentation.isShell ? .shell : .tool,
                title: presentation.canonicalName.isEmpty ? "tool" : presentation.canonicalName,
                content: boundedLog(input),
                isRunning: true
            )
            upsertLog(log, toolCallId: call.id)
            upsertActivity(ActivityEvent(
                id: "activity-tool-\(call.id)",
                timestamp: event.timestamp,
                type: .toolExecution,
                title: presentation.displayName,
                detail: compact(input, limit: 220),
                isRunning: true
            ))
        case .output(let data):
            guard !data.isEmpty else { return }
            appendLog(outputLog(data, event: event))
        case .end(let toolCallId, let success):
            if let messageIndex = toolMessageIndexByCallID[toolCallId], messageIndex < messages.count,
               let entryIndex = toolEntryIndexByCallID[toolCallId],
               entryIndex < messages[messageIndex].toolEntries.count {
                messages[messageIndex].toolEntries[entryIndex].status = success ? .done : .error
            }
            if let logIndex = toolLogIndexByCallID[toolCallId], logIndex < logs.count {
                let current = logs[logIndex]
                replaceLog(at: logIndex, with: LogEntry(
                    id: current.id,
                    timestamp: current.timestamp,
                    level: success ? .success : .error,
                    type: current.type,
                    title: current.title,
                    content: current.content,
                    isRunning: false
                ))
            }
            if let activityIndex = activityIndexByID["activity-tool-\(toolCallId)"], activityIndex < activityEvents.count {
                activityEvents[activityIndex].isRunning = false
                if !success {
                    let current = activityEvents[activityIndex]
                    activityEvents[activityIndex] = ActivityEvent(
                        id: current.id,
                        timestamp: current.timestamp,
                        type: .error,
                        title: current.title,
                        detail: current.detail,
                        isRunning: false
                    )
                }
            }
            var trace = currentTrace ?? AgentTrace()
            trace.recordToolEnded(toolCallId: toolCallId, success: success)
            currentTrace = trace
            agentState = stateReducer.reduce(.toolEnded)
        }
    }
    
    private func handleFile(_ value: RemoteFileEvent, event: RemoteEvent) {
        guard !value.path.isEmpty else { return }
        let change = FileChange(
            path: value.path,
            type: fileChangeType(value.action),
            additions: value.additions,
            deletions: value.deletions
        )
        if let messageIndex = fileMessageIndex, messageIndex < messages.count {
            if let index = fileIndexByPath[change.normalizedPath] {
                messages[messageIndex].fileChanges[index] = messages[messageIndex].fileChanges[index].merging(change)
            } else {
                fileIndexByPath[change.normalizedPath] = messages[messageIndex].fileChanges.count
                messages[messageIndex].fileChanges.append(change)
            }
            messages[messageIndex].content = "修改了 \(messages[messageIndex].fileChanges.count) 个文件"
        } else {
            messages.append(Message(
                id: "remote-files:\(turnID)",
                sender: .system,
                content: "修改了 1 个文件",
                timestamp: event.timestamp,
                kind: .fileChanges,
                fileChanges: [change]
            ))
            fileMessageIndex = messages.count - 1
            fileIndexByPath[change.normalizedPath] = 0
        }
        var trace = currentTrace ?? AgentTrace()
        trace.recordFileChange(change)
        currentTrace = trace
        upsertActivity(ActivityEvent(
            id: "activity-file-\(turnID)-\(change.normalizedPath.lowercased())",
            timestamp: event.timestamp,
            type: .fileChange,
            title: fileTitle(change.type),
            detail: fileDetail(change)
        ))
        // Workspace 缓存联动：Agent 改了文件 → 失效对应缓存，避免下次浏览看到陈旧内容。
        // 不破坏上面的 Chat FileChange 流程，仅在末尾追加失效副作用。
        invalidateWorkspaceCache(for: value)
        recordRecentChange(for: value, timestamp: event.timestamp)
    }

    /// 记录最近修改文件到 recentChanges（去重同路径，保留最新），上限 50。
    private func recordRecentChange(for event: RemoteFileEvent, timestamp: Date) {
        let normalized = event.path
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "./", with: "")
        let entry = RecentFileChange(
            path: normalized,
            changeType: fileChangeType(event.action),
            timestamp: timestamp,
            additions: event.additions,
            deletions: event.deletions
        )
        recentChanges.removeAll { $0.path == normalized }
        recentChanges.insert(entry, at: 0)
        if recentChanges.count > recentChangesMaxCount {
            recentChanges.removeLast(recentChanges.count - recentChangesMaxCount)
        }
    }

    /// 根据文件变化类型失效 Workspace 缓存：
    /// - modified：清掉文件内容缓存（下次查看会重新请求最新版本）
    /// - deleted：清文件内容 + 父目录的 children（列表不再显示）
    /// - created：清父目录的 children（列表会显示新文件）
    /// 路径归一化为正斜杠、相对项目根，与 Extension 返回的 key 一致。
    private func invalidateWorkspaceCache(for event: RemoteFileEvent) {
        let normalized = event.path
            .replacingOccurrences(of: "\\", with: "/")
            .replacingOccurrences(of: "./", with: "")
        switch event.action {
        case .modified:
            if workspaceFiles[normalized] != nil || workspaceFileContent[normalized] != nil {
                workspaceFiles.removeValue(forKey: normalized)
                workspaceFileContent.removeValue(forKey: normalized)
                workspaceFileLRU.removeAll { $0 == normalized }
                RemoteLogger.store("[workspace] 失效文件缓存: \(normalized)")
            }
        case .deleted:
            if workspaceFiles[normalized] != nil || workspaceFileContent[normalized] != nil {
                workspaceFiles.removeValue(forKey: normalized)
                workspaceFileContent.removeValue(forKey: normalized)
                workspaceFileLRU.removeAll { $0 == normalized }
            }
            let parent = workspaceParentDir(normalized)
            workspaceChildren.removeValue(forKey: parent)
            RemoteLogger.store("[workspace] 失效目录(删除): \(parent)")
        case .created:
            let parent = workspaceParentDir(normalized)
            workspaceChildren.removeValue(forKey: parent)
            RemoteLogger.store("[workspace] 失效目录(新增): \(parent)")
        }
    }

    /// 返回文件的父目录相对路径（根目录返回 ""）。输入需已归一化为正斜杠。
    private func workspaceParentDir(_ normalizedPath: String) -> String {
        guard let lastSlash = normalizedPath.lastIndex(of: "/") else { return "" }
        return String(normalizedPath[..<lastSlash])
    }
    
    private func handleSession(_ value: RemoteSessionEvent, event: RemoteEvent) {
        switch value {
        case .info(let info), .update(let info):
            let normalizedInfo = RemoteSessionInfo(
                sessionId: info.sessionId,
                sessionFile: normalizeSessionFile(info.sessionFile),
                name: info.name,
                leafId: info.leafId,
                entryCount: info.entryCount,
                reason: info.reason
            )
            let nextIdentity = sessionIdentity(sessionId: normalizedInfo.sessionId, sessionFile: normalizedInfo.sessionFile)
            let previousIdentity = sessionIdentity(sessionState)
            let pendingMatched = pendingSessionFile != nil && normalizeSessionFile(normalizedInfo.sessionFile) == pendingSessionFile
            
            if !pendingMatched,
               let previousIdentity, let nextIdentity,
               previousIdentity != nextIdentity {
                RemoteLogger.session("[SESSION] remote change \(previousIdentity) -> \(nextIdentity)")
                clearSessionScopedProjection(clearSessionState: false)
            }
            if pendingMatched {
                RemoteLogger.session("[SESSION] switch applied -> \(nextIdentity ?? "unknown")")
                pendingSessionFile = nil
            }
            sessionState = normalizedInfo
        case .history(let sessionId, let entries):
            applyHistory(sessionId: sessionId, entries: entries)
        case .list(let items):
            sessionList = items
        case .switchAcknowledged:
            break // 切换确认由 UI 层消费，Store 只记录状态
        }
    }
    
    private func handleModel(_ value: RemoteModelEvent, event: RemoteEvent) {
        let agent = event.scope.agentId ?? currentAgentId ?? "nil"
        let session = event.scope.sessionId ?? normalizeSessionFile(event.scope.sessionFile) ?? sessionLabel(sessionState)
        switch value {
        case .list(let models):
            availableModels = models
            if let generation = event.generation {
                latestAcceptedModelGeneration = generation
                if pendingModelGeneration == generation {
                    pendingModelGeneration = nil
                }
            }
            RemoteLogger.model("[MODEL] received list agent=\(agent) session=\(session) generation=\(event.generation ?? -1) count=\(models.count)")
        case .selectionAcknowledged(let modelId, let success, let message):
            let requestId = event.selectionRequestId
            if let pending = pendingModelSelectionRequestId, requestId == nil {
                RemoteLogger.model("[STORE] ignore select_ack without requestId pending=\(pending)")
                return
            }
            if let requestId {
                if let pending = pendingModelSelectionRequestId, pending != requestId {
                    RemoteLogger.model("[STORE] ignore stale select_ack requestId=\(requestId) pending=\(pending)")
                    return
                }
                if pendingModelSelectionRequestId == nil,
                   modelSelectionLock?.requestId != requestId {
                    RemoteLogger.model("[STORE] ignore orphan select_ack requestId=\(requestId)")
                    return
                }
            }
            if success, !modelId.isEmpty {
                currentModel = modelId
                modelSelectionLock = ModelSelectionLock(
                    requestId: requestId ?? UUID().uuidString,
                    modelId: modelId,
                    generation: currentSnapshotGeneration
                )
                if let u = usageInfo {
                    usageInfo = RemoteUsageEvent(
                        model: modelId,
                        contextTokens: u.contextTokens,
                        contextWindow: u.contextWindow,
                        contextPercent: u.contextPercent,
                        totalInput: u.totalInput,
                        totalOutput: u.totalOutput,
                        totalCacheRead: u.totalCacheRead,
                        totalCacheWrite: u.totalCacheWrite,
                        totalReasoning: u.totalReasoning,
                        totalTokens: u.totalTokens,
                        totalCost: u.totalCost
                    )
                }
            }
            pendingModelSelectionRequestId = nil
            appendLog(LogEntry(
                id: "log-system-\(event.id):\(eventSequence)",
                timestamp: event.timestamp,
                level: success ? .success : .error,
                type: .system,
                title: "SYSTEM",
                content: boundedLog(message ?? (success ? "已切换到模型: \(modelId)" : "切换模型失败: \(modelId)")),
                isRunning: false
            ))
            lastModelSelection = ModelSelectionResult(requestId: requestId, modelId: modelId, success: success, message: message)
            RemoteLogger.model("[MODEL] select_ack agent=\(agent) session=\(session) requestId=\(requestId ?? "nil") modelId=\(modelId) ok=\(success)")
        }
    }
    
    private func handleUsage(_ value: RemoteUsageEvent, event: RemoteEvent) {
        usageInfo = value
        let agent = event.scope.agentId ?? currentAgentId ?? "nil"
        let session = event.scope.sessionId ?? normalizeSessionFile(event.scope.sessionFile) ?? sessionLabel(sessionState)
        if let generation = event.generation {
            latestAcceptedUsageGeneration = generation
            if pendingUsageGeneration == generation {
                pendingUsageGeneration = nil
            }
        }
        RemoteLogger.usage("[USAGE] received agent=\(agent) session=\(session) generation=\(event.generation ?? -1) model=\(value.model ?? "?") total=\(value.totalTokens)")
        if let m = value.model, !m.isEmpty {
            if let lock = modelSelectionLock,
               m != lock.modelId,
               event.generation == nil || (event.generation ?? 0) <= lock.generation {
                RemoteLogger.model("[STORE] ignore usage model rollback incoming=\(m) locked=\(lock.modelId) generation=\(event.generation ?? -1) lockGeneration=\(lock.generation)")
                usageInfo = RemoteUsageEvent(
                    model: lock.modelId,
                    contextTokens: value.contextTokens,
                    contextWindow: value.contextWindow,
                    contextPercent: value.contextPercent,
                    totalInput: value.totalInput,
                    totalOutput: value.totalOutput,
                    totalCacheRead: value.totalCacheRead,
                    totalCacheWrite: value.totalCacheWrite,
                    totalReasoning: value.totalReasoning,
                    totalTokens: value.totalTokens,
                    totalCost: value.totalCost
                )
            } else {
                currentModel = m
                if let lock = modelSelectionLock,
                   m == lock.modelId,
                   (event.generation ?? Int.max) >= lock.generation {
                    // 保持锁，直到更高 generation 的快照明确覆盖它。
                } else if let lock = modelSelectionLock,
                          let generation = event.generation,
                          generation > lock.generation {
                    modelSelectionLock = nil
                }
            }
        }
    }

    // MARK: - Model Selection Feedback (non-chat)
    struct ModelSelectionResult: Equatable {
        let requestId: String?
        let modelId: String
        let success: Bool
        let message: String?
    }
    @Published private(set) var lastModelSelection: ModelSelectionResult?
    
    /// 清除模型切换提示（供 UI 定时调用）
    func clearModelSelectionFeedback() {
        lastModelSelection = nil
    }
    
    private func handleMedia(_ value: RemoteMediaEvent, event: RemoteEvent) {
        guard case let .image(fileName, base64) = value,
              let data = Data(base64Encoded: base64) else { return }
        messages.append(Message(
            id: event.id,
            sender: .pi,
            content: fileName,
            timestamp: event.timestamp,
            kind: .image,
            imageData: data
        ))
    }
    
    /// ChatViewModel 通过此方法更新已发送消息的交付状态。
    func updateMessageDelivery(id: String, delivery: Message.DeliveryState) {
        guard let index = messages.firstIndex(where: { $0.id == id }) else { return }
        messages[index].delivery = delivery
    }
    
    /// 多段 Assistant Trace 转移时，标记旧宿主消息为中间态（不在聊天页展示）。
    func markIntermediateAssistant(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].isIntermediateAssistant = true
    }
    
    /// PC 保存确认映射：标记系统消息为媒体状态消息并更新附件。
    func markMediaStatusMessage(_ messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        messages[index].isMediaStatusMessage = true
    }
    
    /// 切换工具组的展开/折叠状态
    func toggleToolGroup(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId && $0.kind == .tool }) else { return }
        switch messages[index].toolGroupState {
        case .collapsed: messages[index].toolGroupState = .expanded
        case .working, .expanded: messages[index].toolGroupState = .collapsed
        }
    }
    
    /// 切换文件变更组的展开/折叠状态
    func toggleFileChanges(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId && $0.kind == .fileChanges }) else { return }
        messages[index].isFileChangesExpanded.toggle()
    }
    
    /// 切换 Agent Trace 的展开/折叠状态
    func toggleAgentTrace(messageId: String) {
        guard let index = messages.firstIndex(where: { $0.id == messageId && $0.kind == .text && $0.sender == .pi }),
              messages[index].trace?.shouldDisplay == true else { return }
        messages[index].trace?.isExpanded.toggle()
    }
    
    /// 更新指定消息的附件状态。
    func updateAttachmentStatus(messageId: String, attachmentId: String, status: AttachmentStatus, error: String?) {
        guard let index = messages.firstIndex(where: { $0.id == messageId }) else { return }
        guard let attIndex = messages[index].attachments.firstIndex(where: { $0.id == attachmentId }) else { return }
        messages[index].attachments[attIndex].status = status
        messages[index].attachments[attIndex].errorMessage = error
    }
    
    /// 从最新图片消息中查找并更新指定文件名的附件状态。
    func updateLatestAttachment(named fileName: String, status: AttachmentStatus, error: String?) {
        for index in messages.indices.reversed() where messages[index].kind == .image {
            if let attIndex = messages[index].attachments.firstIndex(where: { $0.fileName == fileName }) {
                messages[index].attachments[attIndex].status = status
                messages[index].attachments[attIndex].errorMessage = error
                return
            }
        }
    }
    
    /// 从最新图片消息中查找并更新首个 pending 附件状态。
    func updateLatestPendingAttachment(status: AttachmentStatus, error: String?) {
        for index in messages.indices.reversed() where messages[index].kind == .image {
            if let attIndex = messages[index].attachments.firstIndex(where: {
                $0.status == .uploading || $0.status == .processing
            }) {
                messages[index].attachments[attIndex].status = status
                messages[index].attachments[attIndex].errorMessage = error
                return
            }
        }
    }
    
    private func handleRelay(_ value: RemoteRelayEvent) {
        switch value {
        case .agents(let list):
            agents = list
            let prev = currentAgentId
            let next = (prev != nil && list.contains(where: { $0.agentId == prev })) ? prev : list.first?.agentId
            if prev != next {
                currentAgentId = next
                if prev != nil && next != nil {
                    RemoteLogger.session("[SESSION] relay target fallback \(prev ?? "nil") -> \(next ?? "nil")")
                    reset()
                }
            }
            RemoteLogger.store("[AGENT] relay.agents count=\(list.count) current=\(currentAgentId ?? "nil") prev=\(prev ?? "nil")")
            // PC 在线状态：有任一 agent 窗口在线即为在线
            isAgentOnline = !agents.isEmpty
        case .agentJoined(let agent):
            if !agents.contains(where: { $0.agentId == agent.agentId }) {
                agents.append(agent)
            }
            if currentAgentId == nil {
                currentAgentId = agent.agentId
            }
            isAgentOnline = true
        case .agentLeft(let agentId):
            agents.removeAll { $0.agentId == agentId }
            if currentAgentId == agentId {
                let next = agents.first?.agentId
                RemoteLogger.session("[SESSION] relay target left \(agentId) -> \(next ?? "nil")")
                currentAgentId = next
                reset()
            }
            isAgentOnline = !agents.isEmpty
        case .status, .acknowledged, .failed:
            break
        }
    }
    
    private func handleQuestionnaire(_ value: RemoteQuestionnaireEvent, event: RemoteEvent) {
        switch value {
        case .show(let id, let questions):
            // 投影到 UI 状态：弹出问卷（单一数据流：RemoteEvent → Store → Sheet）
            activeQuestionnaireId = id
            questionnaireQuestions = questions.map { q in
                ProtocolMessage.QuestionPayload(
                    question: q.question,
                    header: q.header,
                    multiSelect: q.multiSelect,
                    options: q.options.map { opt in
                        ProtocolMessage.OptionPayload(
                            label: opt.label,
                            description: opt.description,
                            hasPreview: opt.hasPreview
                        )
                    }
                )
            }
            showQuestionnaire = !questions.isEmpty
        case .answered(let source, let answers):
            // iOS 自身提交的答案不回显日志，但需要关闭弹窗
            if source == "ios" {
                showQuestionnaire = false
                return
            }
            let summary = answers.map { answer in
                let value = answer.selected?.joined(separator: ", ") ?? answer.answer ?? "(未回答)"
                return "\(answer.question ?? "?"): \(value)"
            }.joined(separator: "\n")
            appendLog(LogEntry(
                id: "log-system-\(event.id):\(eventSequence)",
                timestamp: event.timestamp,
                level: .info,
                type: .system,
                title: "SYSTEM",
                content: boundedLog(summary),
                isRunning: false
            ))
            showQuestionnaire = false
        }
    }
    
    private func handleWorkspace(_ value: RemoteWorkspaceEvent, event: RemoteEvent) {
        switch value {
        case .tree(let tree):
            let key = tree.path
            workspaceChildren[key] = tree.children
            if key.isEmpty {
                workspaceRootName = tree.name
            }
            workspaceErrors.removeValue(forKey: key)
        case .file(let file):
            workspaceFiles[file.path] = file
            if let content = file.content, file.isText {
                workspaceFileContent[file.path] = content
            } else {
                workspaceFileContent.removeValue(forKey: file.path)
            }
            touchWorkspaceFileLRU(file.path)
            workspaceErrors.removeValue(forKey: file.path)
        case .error(let error):
            let key = error.path ?? ""
            workspaceErrors[key] = error.message
        case .searchResult(let result):
            workspaceSearchResult = result.hits.isEmpty && result.query.isEmpty ? nil : result
            workspaceSearching = false
            RemoteLogger.store("[workspace] 搜索结果 query=\"\(result.query)\" hits=\(result.hits.count)")
        }
    }

    /// 文件内容 LRU：访问时移到尾部，超出上限淘汰头部（最旧）。
    private func touchWorkspaceFileLRU(_ path: String) {
        workspaceFileLRU.removeAll { $0 == path }
        workspaceFileLRU.append(path)
        while workspaceFileLRU.count > workspaceFileMaxCount {
            let evicted = workspaceFileLRU.removeFirst()
            workspaceFiles.removeValue(forKey: evicted)
            workspaceFileContent.removeValue(forKey: evicted)
        }
    }
    
    private func beginTurn(eventID: String) {
        turnID = eventID
        currentTrace = AgentTrace()
        toolMessageIndex = nil
        toolMessageIndexByCallID.removeAll()
        toolEntryIndexByCallID.removeAll()
        fileMessageIndex = nil
        fileIndexByPath.removeAll()
    }
    
    private func ensureAssistant(_ messageId: String, timestamp: Date) -> Int {
        if let index = assistantIndexByID[messageId], index < messages.count { return index }
        messages.append(Message(
            id: "remote-assistant:\(messageId)",
            sender: .pi,
            content: "",
            timestamp: timestamp,
            kind: .text,
            isStreaming: true
        ))
        let index = messages.count - 1
        assistantIndexByID[messageId] = index
        return index
    }

    /// agent_end/agent.status=completed 的兜底收口。
    /// 不能只依赖 assistant.end：某些 Pi 回复路径可能没有文本结束事件，
    /// 或结束事件可能先于/晚于状态事件到达。
    private func finishStreamingMessages() {
        var finishedAny = false
        for (messageID, index) in assistantIndexByID {
            guard messages.indices.contains(index), messages[index].isStreaming else { continue }
            messages[index].isStreaming = false
            completedAssistantIDs.insert(messageID)
            finishedAny = true
        }
        activeStreamingMessageID = nil
        if finishedAny {
            streamingRevision &+= 1
        }
    }
    
    private func updateTrace(_ status: RemoteAgentStatus) {
        var trace = currentTrace ?? AgentTrace()
        switch status.value {
        case "receiving", "running", "thinking", "planning":
            trace.recordThinking(status: status.value, detail: status.description)
        case "completed":
            trace.complete(success: true)
        case "error":
            trace.complete(success: false, detail: status.description)
        default:
            return
        }
        currentTrace = trace
    }
    
    private func updateActivity(_ status: RemoteAgentStatus, event: RemoteEvent) {
        switch status.value {
        case "receiving", "running", "thinking", "planning":
            upsertActivity(ActivityEvent(
                id: "activity-thinking-\(turnID)",
                timestamp: event.timestamp,
                type: .thinking,
                title: status.value == "planning" ? "规划任务" : "分析任务",
                detail: status.description,
                isRunning: true
            ))
        case "completed", "error":
            if let index = activityIndexByID["activity-thinking-\(turnID)"], index < activityEvents.count {
                activityEvents[index].isRunning = false
            }
            upsertActivity(ActivityEvent(
                id: "activity-completed-\(turnID)",
                timestamp: event.timestamp,
                type: status.value == "error" ? .error : .completed,
                title: status.value == "error" ? "执行失败" : "完成回答",
                detail: status.value == "error" ? status.description : nil
            ))
        default:
            break
        }
    }
    
    private func applyHistory(sessionId: String?, entries: [RemoteHistoryEntry]) {
        clearConversationProjection()
        
        for (index, entry) in entries.enumerated() {
            let id = "history:\(entry.sessionId ?? sessionId ?? "unknown"):\(entry.entryId ?? "legacy-\(index)")"
            switch entry.role {
            case "user":
                let message = Message(id: id, sender: .user, content: entry.text, timestamp: entry.timestamp, kind: .text, isHistory: true)
                messages.append(message)
                recordHistoryActivity(message)
            case "assistant":
                messages.append(Message(id: id, sender: .pi, content: entry.text, timestamp: entry.timestamp, kind: .text, isHistory: true))
            case "tool":
                let parts = entry.text.split(separator: " ", maxSplits: 1)
                let name = parts.first.map(String.init) ?? "tool"
                let input = parts.count > 1 ? String(parts[1]) : ""
                let toolEntry = ToolEntry(toolCallId: id, toolName: name, detail: input, status: .done)
                messages.append(Message(
                    id: "history-group:\(id)",
                    sender: .pi,
                    content: entry.text,
                    timestamp: entry.timestamp,
                    kind: .tool,
                    isHistory: true,
                    toolEntries: [toolEntry],
                    toolGroupState: .collapsed
                ))
                let presentation = ToolPresentation.resolve(name: name, input: input)
                appendLog(LogEntry(
                    id: "log-tool-\(id)",
                    timestamp: entry.timestamp,
                    level: .success,
                    type: presentation.isShell ? .shell : .tool,
                    title: presentation.canonicalName.isEmpty ? "tool" : presentation.canonicalName,
                    content: boundedLog(input),
                    isRunning: false
                ))
            case "terminal":
                messages.append(Message(id: id, sender: .pi, content: entry.text, timestamp: entry.timestamp, kind: .terminal, isHistory: true))
                appendLog(outputLog(entry.text, id: id, timestamp: entry.timestamp))
            default:
                break
            }
        }
    }
    
    private func recordHistoryActivity(_ message: Message) {
        upsertActivity(ActivityEvent(
            id: "activity-user-\(message.id)",
            timestamp: message.timestamp,
            type: .userRequest,
            title: "用户请求",
            detail: compact(message.content, limit: 180)
        ))
    }
    
    private func upsertActivity(_ event: ActivityEvent) {
        if let index = activityIndexByID[event.id], index < activityEvents.count {
            activityEvents[index] = event
        } else {
            activityIndexByID[event.id] = activityEvents.count
            activityEvents.append(event)
        }
        trimActivitiesIfNeeded()
    }

    private func trimActivitiesIfNeeded() {
        guard activityEvents.count > maxActivities else { return }
        let removed = activityEvents.count - maxActivities
        activityEvents.removeFirst(removed)
        // 重建索引映射
        activityIndexByID = Dictionary(uniqueKeysWithValues: activityIndexByID.compactMap { element -> (String, Int)? in
            let (key, value) = element
            let next = value - removed
            return next >= 0 ? (key, next) : nil
        })
    }
    
    private func appendLog(_ entry: LogEntry) {
        logs.append(entry)
        logCharacters += entry.content.count
        trimLogsIfNeeded()
    }
    
    private func upsertLog(_ entry: LogEntry, toolCallId: String) {
        if let index = toolLogIndexByCallID[toolCallId], index < logs.count {
            replaceLog(at: index, with: entry)
        } else {
            toolLogIndexByCallID[toolCallId] = logs.count
            appendLog(entry)
        }
    }
    
    private func replaceLog(at index: Int, with entry: LogEntry) {
        logCharacters -= logs[index].content.count
        logs[index] = entry
        logCharacters += entry.content.count
    }
    
    private func trimLogsIfNeeded() {
        var removed = 0
        while logs.count - removed > maxLogs || logCharacters > maxLogCharacters {
            guard removed < logs.count else { break }
            logCharacters -= logs[removed].content.count
            removed += 1
        }
        guard removed > 0 else { return }
        logs.removeFirst(removed)
        toolLogIndexByCallID = Dictionary(uniqueKeysWithValues: toolLogIndexByCallID.compactMap { element -> (String, Int)? in
            let (key, value) = element
            let next = value - removed
            return next >= 0 ? (key, next) : nil
        })
    }
    
    private func outputLog(_ data: String, event: RemoteEvent) -> LogEntry {
        outputLog(data, id: "\(event.id):\(eventSequence)", timestamp: event.timestamp)
    }
    
    private func outputLog(_ data: String, id: String, timestamp: Date) -> LogEntry {
        let content = boundedLog(data)
        let lower = content.lowercased()
        let isError = ["stderr", "error:", "failed", "failure", "exception", "fatal", "traceback"].contains { lower.contains($0) }
        let isWarning = !isError && ["warning", "warn:", "deprecated"].contains { lower.contains($0) }
        let isSuccess = !isError && !isWarning && ["pass", "success", "succeeded", "completed", "✓"].contains { lower.contains($0) }
        return LogEntry(
            id: "log-output-\(id)",
            timestamp: timestamp,
            level: isError ? .error : (isWarning ? .warning : (isSuccess ? .success : .info)),
            type: isError ? .stderr : .stdout,
            title: isError ? "ERROR" : (isWarning ? "WARNING" : (isSuccess ? "SUCCESS" : "OUTPUT")),
            content: content,
            isRunning: false
        )
    }
    
    private func boundedLog(_ value: String, limit: Int = 50_000) -> String {
        let redacted = SensitiveDataRedactor.redact(value)
        guard redacted.count > limit else { return redacted }
        let half = max(1, (limit - 80) / 2)
        return String(redacted.prefix(half)) + "\n\n… 输出过长，中间内容已省略 …\n\n" + String(redacted.suffix(half))
    }
    
    private func clearSessionScopedProjection(clearSessionState: Bool) {
        cancelAgentStateReset()
        sessionProjectionRevision &+= 1
        clearConversationProjection()
        sessionState = clearSessionState ? nil : sessionState
        pendingSessionFile = nil
        pendingUsageGeneration = nil
        pendingModelGeneration = nil
        latestAcceptedUsageGeneration = nil
        latestAcceptedModelGeneration = nil
        pendingModelSelectionRequestId = nil
        modelSelectionLock = nil
        availableModels = []
        currentModel = nil
        usageInfo = nil
        modelPickerRequested = false
        lastModelSelection = nil
        questionnaireQuestions = []
        showQuestionnaire = false
        activeQuestionnaireId = nil
        workspaceChildren.removeAll()
        workspaceFiles.removeAll()
        workspaceFileContent.removeAll()
        workspaceFileLRU.removeAll()
        workspaceErrors.removeAll()
        workspaceRootName = ""
        workspaceSearchResult = nil
        workspaceSearching = false
        pendingFileContext = nil
        pendingWorkspaceFile = nil
        recentChanges.removeAll()
    }
    
    private func normalizeSessionFile(_ value: String?) -> String? {
        guard let value else { return nil }
        let normalized = value.replacingOccurrences(of: "\\", with: "/")
        return normalized.isEmpty ? nil : normalized
    }
    
    private func sessionIdentity(_ info: RemoteSessionInfo?) -> String? {
        sessionIdentity(sessionId: info?.sessionId, sessionFile: info?.sessionFile)
    }
    
    private func sessionIdentity(sessionId: String?, sessionFile: String?) -> String? {
        if let sessionId, !sessionId.isEmpty { return "id:\(sessionId)" }
        if let sessionFile = normalizeSessionFile(sessionFile), !sessionFile.isEmpty { return "file:\(sessionFile)" }
        return nil
    }
    
    private func sessionLabel(_ info: RemoteSessionInfo?) -> String {
        sessionIdentity(info) ?? "unknown"
    }
    
    private func clearConversationProjection() {
        cancelAgentStateReset()
        messages.removeAll(keepingCapacity: true)
        logs.removeAll(keepingCapacity: true)
        activityEvents.removeAll(keepingCapacity: true)
        currentTrace = nil
        activeStreamingMessageID = nil
        streamingRevision = 0
        stateReducer = AgentStateReducer()
        agentState = .idle
        logCharacters = 0
        resetIndexes()
    }
    
    private func resetIndexes() {
        assistantIndexByID.removeAll()
        assistantLastSequenceByID.removeAll()
        completedAssistantIDs.removeAll()
        toolMessageIndex = nil
        toolMessageIndexByCallID.removeAll()
        toolEntryIndexByCallID.removeAll()
        toolLogIndexByCallID.removeAll()
        activityIndexByID.removeAll()
        fileMessageIndex = nil
        fileIndexByPath.removeAll()
    }
    
    private func fileChangeType(_ action: RemoteFileEvent.Action) -> FileChangeType {
        switch action {
        case .created: return .added
        case .modified: return .modified
        case .deleted: return .deleted
        }
    }
    
    private func fileTitle(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "新增文件"
        case .modified: return "修改文件"
        case .deleted: return "删除文件"
        }
    }
    
    private func fileDetail(_ change: FileChange) -> String {
        var values = [change.normalizedPath]
        if let additions = change.additions { values.append("+\(additions)") }
        if let deletions = change.deletions { values.append("−\(deletions)") }
        return values.joined(separator: "  ")
    }
    
    private func compact(_ value: String, limit: Int) -> String? {
        let result = value
            .replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard !result.isEmpty else { return nil }
        return result.count > limit ? String(result.prefix(max(0, limit - 1))) + "…" : result
    }
}
