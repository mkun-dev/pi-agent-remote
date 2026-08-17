import Foundation

// 精确对应 pi-ios-extension 的协议
struct ProtocolMessage: Codable {
    let id: String?
    let type: String
    let timestamp: Int?
    let payload: Payload
    
    struct Payload: Codable {
        let text: String?
        let status: String?
        let description: String?   // agent.status 的人类可读说明
        let tool: String?
        let command: String?
        let data: String?
        let success: Bool?
        let toolCallId: String?
        let messageId: String?   // assistant.start / assistant.delta / assistant.end
        let path: String?
        let action: String?
        let additions: Int?   // file.change
        let deletions: Int?   // file.change
        let type: String?   // "thinking" | "message"
        
        // Session (Phase 3)
        let sessionId: String?
        let sessionFile: String?
        let name: String?
        let leafId: String?
        let entryCount: Int?
        let reason: String?
        
        // Session history (Phase 3.5) — session.history
        let entries: [HistoryEntry]?
        
        // Multi-agent (Phase 4) — relay.agents / relay.agent_join / 目标路由
        let targetAgentId: String?
        let agents: [AgentPayload]?
        let agent: AgentPayload?
        let agentId: String?   // relay.agent_leave 的 payload
        
        // Session list / switch (Phase 4) — session.list_result / session.switch_ack
        let sessions: [SessionListItemPayload]?
        let ok: Bool?
        
        // Relay (Phase 3 NAT 穿透) — relay.ack / relay.error / relay.status
        let id: String?
        
        // Usage (模型与用量) — usage.info
        let model: String?
        let contextTokens: Int?
        let contextWindow: Int?
        let contextPercent: Int?
        let totalInput: Int?
        let totalOutput: Int?
        let totalCacheRead: Int?
        let totalCacheWrite: Int?
        let totalReasoning: Int?
        let totalTokens: Int?
        let totalCost: Double?
        
        // Model picker — model.list / model.request / model.select / model.select_ack
        let models: [String]?
        let modelId: String?
        let message: String?
        let code: String?   // relay.error
        let generation: Int?
        let selectionRequestId: String?
        
        // Questionnaire
        let questions: [QuestionPayload]?
        let answers: [AnswerPayload]?
        let source: String?   // "pc" | "ios"
        
        // Media — media.image / media.upload
        let fileName: String?
        let base64: String?
        let dir: String?
        
        // Workspace — workspace.tree / workspace.file / workspace.error / workspace.searchResult
        let children: [WorkspaceNodePayload]?
        let size: Int?
        let content: String?
        let fileType: String?
        let mimeType: String?
        let query: String?
        let hits: [WorkspaceHitPayload]?
        
        // Streaming 同步 — assistant.delta 序号
        let seq: Int?

        // P4 git 式撤回
        let userMessageIndexFromEnd: Int?
        let removedMessageCount: Int?
        
        // Workspace 联动 — agent.input 附带的文件上下文（路径，不复制内容）
        let context: MessageContext?
        
        // Steer（P3）：agent.input 携带 steer=true 表示中断当前 turn 并作为新 turn 发送
        let steer: Bool?
        
        /// 便捷 init：只传常用字段，其余默认为 nil（避免每次加字段改所有调用处）
        init(
            text: String? = nil, status: String? = nil, description: String? = nil,
            tool: String? = nil, command: String? = nil, data: String? = nil, success: Bool? = nil,
            toolCallId: String? = nil, messageId: String? = nil,
            path: String? = nil, action: String? = nil,
            additions: Int? = nil, deletions: Int? = nil, type: String? = nil,
            sessionId: String? = nil, sessionFile: String? = nil, name: String? = nil,
            leafId: String? = nil, entryCount: Int? = nil, reason: String? = nil,
            entries: [HistoryEntry]? = nil, targetAgentId: String? = nil,
            agents: [AgentPayload]? = nil, agent: AgentPayload? = nil,
            agentId: String? = nil, sessions: [SessionListItemPayload]? = nil,
            ok: Bool? = nil, id: String? = nil,
            model: String? = nil, contextTokens: Int? = nil, contextWindow: Int? = nil,
            contextPercent: Int? = nil, totalInput: Int? = nil, totalOutput: Int? = nil,
            totalCacheRead: Int? = nil, totalCacheWrite: Int? = nil,
            totalReasoning: Int? = nil, totalTokens: Int? = nil, totalCost: Double? = nil,
            models: [String]? = nil, modelId: String? = nil, message: String? = nil,
            code: String? = nil, generation: Int? = nil, selectionRequestId: String? = nil,
            questions: [QuestionPayload]? = nil, answers: [AnswerPayload]? = nil,
            source: String? = nil,
            fileName: String? = nil, base64: String? = nil, dir: String? = nil,
            children: [WorkspaceNodePayload]? = nil, size: Int? = nil, content: String? = nil,
            fileType: String? = nil, mimeType: String? = nil,
            query: String? = nil, hits: [WorkspaceHitPayload]? = nil,
            seq: Int? = nil,
            userMessageIndexFromEnd: Int? = nil, removedMessageCount: Int? = nil,
            context: MessageContext? = nil,
            steer: Bool? = nil
        ) {
            self.text = text; self.status = status; self.description = description
            self.tool = tool; self.command = command; self.data = data; self.success = success
            self.toolCallId = toolCallId; self.messageId = messageId
            self.path = path; self.action = action
            self.additions = additions; self.deletions = deletions; self.type = type
            self.sessionId = sessionId; self.sessionFile = sessionFile; self.name = name
            self.leafId = leafId; self.entryCount = entryCount; self.reason = reason
            self.entries = entries; self.targetAgentId = targetAgentId
            self.agents = agents; self.agent = agent; self.agentId = agentId
            self.sessions = sessions; self.ok = ok; self.id = id
            self.model = model; self.contextTokens = contextTokens; self.contextWindow = contextWindow
            self.contextPercent = contextPercent; self.totalInput = totalInput; self.totalOutput = totalOutput
            self.totalCacheRead = totalCacheRead; self.totalCacheWrite = totalCacheWrite
            self.totalReasoning = totalReasoning; self.totalTokens = totalTokens; self.totalCost = totalCost
            self.models = models; self.modelId = modelId; self.message = message; self.code = code
            self.generation = generation; self.selectionRequestId = selectionRequestId
            self.questions = questions; self.answers = answers; self.source = source
            self.fileName = fileName; self.base64 = base64; self.dir = dir
            self.children = children; self.size = size; self.content = content
            self.fileType = fileType; self.mimeType = mimeType
            self.query = query; self.hits = hits
            self.seq = seq
            self.userMessageIndexFromEnd = userMessageIndexFromEnd; self.removedMessageCount = removedMessageCount
            self.context = context
            self.steer = steer
        }
    }
    
    /// 会话历史条目（对应扩展端 HistoryEntry）
    struct HistoryEntry: Codable {
        /// Pi SessionEntry.id 派生出的稳定 ID；旧 Extension 可能不提供。
        let entryId: String?
        /// 条目所属 Session；同时兼容 payload.sessionId。
        let sessionId: String?
        let role: String?  // "user" | "assistant" | "tool" | "terminal"
        let text: String?
        let ts: Int?       // Unix 毫秒
    }
    
    /// 在线窗口（agent）信息（对应扩展端 AgentMeta + 中继 agent 列表）
    struct AgentPayload: Codable {
        let agentId: String?
        let name: String?
        let cwd: String?
        let model: String?
        let online: Bool?
    }
    
    /// 历史会话列表项（对应扩展端 SessionListItem）
    struct SessionListItemPayload: Codable {
        let path: String?
        let id: String?
        let name: String?
        let cwd: String?
        let messageCount: Int?
        let firstMessage: String?
        let modified: Int?
    }
    
    /// 工作区文件树节点（workspace.tree）
    struct WorkspaceNodePayload: Codable {
        let name: String?
        let path: String?
        let type: String?
    }

    /// 工作区搜索结果项（workspace.searchResult）
    struct WorkspaceHitPayload: Codable {
        let path: String?
        let filename: String?
        let type: String?
    }
    
    /// 问卷问题（questionnaire.show）
    struct QuestionPayload: Codable, Identifiable {
        var id: String { header ?? question ?? UUID().uuidString }
        let question: String?
        let header: String?
        let multiSelect: Bool?
        let options: [OptionPayload]?
    }
    
    /// 问卷选项
    struct OptionPayload: Codable, Identifiable {
        var id: String { label ?? UUID().uuidString }
        let label: String?
        let description: String?
        let hasPreview: Bool?
    }
    
    /// 问卷回答（questionnaire.answer）
    struct AnswerPayload: Codable {
        let question: String?
        let answer: String?
        let selected: [String]?
        let notes: String?
    }
}

/// Phase 4: 在线窗口（agent）模型，供会话列表 UI 展示
struct AgentInfo: Identifiable, Equatable {
    let agentId: String
    var name: String?
    var cwd: String?
    var model: String?
    var online: Bool = true
    
    var id: String { agentId }
    
    /// 显示名：会话名 > 目录名 > agentId 短码
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let cwd = cwd, !cwd.isEmpty {
            return (cwd as NSString).lastPathComponent
        }
        return String(agentId.suffix(8))
    }
    
    var subtitle: String {
        cwd ?? agentId
    }
}

enum PiEvent: String {
    case input    = "agent.input"
    case output   = "agent.output"
    case assistantStart = "assistant.start"
    case assistantDelta = "assistant.delta"
    case assistantEnd = "assistant.end"
    case toolStart = "tool.start"
    case toolOutput = "tool.output"
    case toolEnd  = "tool.end"
    case status   = "agent.status"
    case fileChange = "file.change"
    case sessionInfo = "session.info"
    case sessionUpdate = "session.update"
    case sessionHistory = "session.history"
    case sessionResume = "session.resume"
    
    // Phase 4: 多窗口管理
    case relayAgents = "relay.agents"
    case relayAgentJoin = "relay.agent_join"
    case relayAgentLeave = "relay.agent_leave"
    case sessionList = "session.list"
    case sessionListResult = "session.list_result"
    case sessionSwitch = "session.switch"
    case sessionSwitchAck = "session.switch_ack"
}

// Phase 3: 会话信息模型
struct SessionInfo: Equatable {
    var sessionId: String?
    var sessionFile: String?
    var name: String?
    var leafId: String?
    var entryCount: Int
    var reason: String?
    
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let sessionId = sessionId, !sessionId.isEmpty {
            return String(sessionId.prefix(8))
        }
        return "未知"
    }
    
    static let empty = SessionInfo(sessionId: nil, sessionFile: nil, name: nil, leafId: nil, entryCount: 0, reason: nil)
}

// 模型与用量信息（usage.info）
struct UsageInfo: Equatable {
    var model: String?
    var contextTokens: Int?
    var contextWindow: Int
    var contextPercent: Int?
    var totalInput: Int
    var totalOutput: Int
    var totalCacheRead: Int
    var totalCacheWrite: Int
    var totalReasoning: Int
    var totalTokens: Int
    var totalCost: Double
    
    static let empty = UsageInfo(
        model: nil, contextTokens: nil, contextWindow: 0, contextPercent: nil,
        totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
        totalReasoning: 0, totalTokens: 0, totalCost: 0
    )
    
    /// 上下文占比显示（如 "35%"），未知显示 "—"
    var contextPercentText: String {
        if let p = contextPercent { return "\(p)%" }
        return "—"
    }
    
    /// 格式化累计费用（美元）
    var costText: String {
        if totalCost <= 0 { return "$0.00" }
        return String(format: "$%.4f", totalCost)
    }
}
