import Foundation

/// WebSocket 消息的统一类型化入口。Envelope 只保存公共元数据，具体字段由领域事件承载。
struct RemoteEvent: Identifiable, Equatable {
    struct Scope: Equatable {
        let agentId: String?
        let sessionId: String?
        let sessionFile: String?
        let targetAgentId: String?
        
        static let empty = Scope(agentId: nil, sessionId: nil, sessionFile: nil, targetAgentId: nil)
    }
    
    let id: String
    let timestamp: Date
    let payload: Payload
    let scope: Scope
    let generation: Int?
    let selectionRequestId: String?
    
    init(
        id: String,
        timestamp: Date,
        payload: Payload,
        scope: Scope = .empty,
        generation: Int? = nil,
        selectionRequestId: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.payload = payload
        self.scope = scope
        self.generation = generation
        self.selectionRequestId = selectionRequestId
    }
    
    enum Payload: Equatable {
        case agent(RemoteAgentEvent)
        case assistant(RemoteAssistantEvent)
        case tool(RemoteToolEvent)
        case file(RemoteFileEvent)
        case session(RemoteSessionEvent)
        case history(RemoteHistoryControlEvent)
        case usage(RemoteUsageEvent)
        case model(RemoteModelEvent)
        case questionnaire(RemoteQuestionnaireEvent)
        case media(RemoteMediaEvent)
        case relay(RemoteRelayEvent)
        case workspace(RemoteWorkspaceEvent)
        case unknown(type: String)
    }
}

enum RemoteAgentEvent: Equatable {
    case input(text: String)
    case output(text: String, isThinking: Bool)
    case status(RemoteAgentStatus)
}

struct RemoteAgentStatus: Equatable {
    let value: String
    let tool: String?
    let description: String?
}

enum RemoteAssistantEvent: Equatable {
    case start(messageId: String)
    case delta(messageId: String, text: String, seq: Int?)
    case end(messageId: String, text: String?)
}

enum RemoteToolEvent: Equatable {
    case start(RemoteToolCall)
    case output(data: String)
    case end(toolCallId: String, success: Bool)
}

struct RemoteToolCall: Equatable {
    let id: String
    let name: String
    let input: String?
}

struct RemoteFileEvent: Equatable {
    enum Action: String, Equatable {
        case created
        case modified
        case deleted
    }
    let path: String
    let action: Action
    let additions: Int?
    let deletions: Int?
}

/// 消息上下文：标记当前讨论涉及的 Workspace 文件，让 Agent（PC 端）知道用户在问哪个文件。
/// 附带在 agent.input 上随消息一起发送，不复制文件内容，仅传路径与可选选区。
struct MessageContext: Equatable, Codable {
    let workspaceFiles: [String]
    /// 可选：用户选中的文本片段范围（行号或文本），用于精准提问。
    var selection: String?
}

/// 最近修改文件条目（Workspace 首页「Recent Changes」）。源自 file.change 事件。
struct RecentFileChange: Identifiable, Equatable {
    let path: String
    let changeType: FileChangeType
    let timestamp: Date
    let additions: Int?
    let deletions: Int?
    var id: String { "\(path)#\(Int(timestamp.timeIntervalSince1970))" }
    var fileName: String { (path as NSString).lastPathComponent }
}

struct RemoteSessionInfo: Equatable {
    let sessionId: String?
    let sessionFile: String?
    let name: String?
    let leafId: String?
    let entryCount: Int
    let reason: String?
    
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let sessionId = sessionId, !sessionId.isEmpty { return String(sessionId.prefix(8)) }
        return "未知"
    }
}

struct RemoteHistoryEntry: Equatable {
    let entryId: String?
    let sessionId: String?
    let role: String
    let text: String
    let timestamp: Date
}

struct RemoteSessionListItem: Equatable {
    let path: String?
    let id: String?
    let name: String?
    let cwd: String?
    let messageCount: Int?
    let firstMessage: String?
    let modified: Date?
    
    var displayTitle: String {
        if let name = name, !name.isEmpty { return name }
        if let cwd = cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        if let id = id, !id.isEmpty { return String(id.prefix(8)) }
        return "未知"
    }
}

enum RemoteSessionEvent: Equatable {
    case info(RemoteSessionInfo)
    case update(RemoteSessionInfo)
    case history(sessionId: String?, entries: [RemoteHistoryEntry])
    case list([RemoteSessionListItem])
    case switchAcknowledged(sessionFile: String?, success: Bool)
}

/// P4：git 式撤回控制事件。rewoundContent 回填输入框；removedUserMessageCount 表示撤回了倒数 N 条用户消息。
enum RemoteHistoryControlEvent: Equatable {
    case rewound(rewoundContent: String, removedUserMessageCount: Int)
}

struct RemoteUsageEvent: Equatable {
    let model: String?
    let contextTokens: Int?
    let contextWindow: Int
    let contextPercent: Int?
    let totalInput: Int
    let totalOutput: Int
    let totalCacheRead: Int
    let totalCacheWrite: Int
    let totalReasoning: Int
    let totalTokens: Int
    let totalCost: Double
    
    var contextPercentText: String {
        if let p = contextPercent { return "\(p)%" }
        return "—"
    }
    
    var costText: String {
        if totalCost <= 0 { return "$0.00" }
        return String(format: "$%.4f", totalCost)
    }
}

enum RemoteModelEvent: Equatable {
    case list([String])
    case selectionAcknowledged(modelId: String, success: Bool, message: String?)
}

struct RemoteQuestion: Equatable {
    struct Option: Equatable {
        let label: String?
        let description: String?
        let hasPreview: Bool?
    }
    let question: String?
    let header: String?
    let multiSelect: Bool
    let options: [Option]
}

struct RemoteQuestionAnswer: Equatable {
    let question: String?
    let answer: String?
    let selected: [String]?
    let notes: String?
}

enum RemoteQuestionnaireEvent: Equatable {
    case show(id: String?, questions: [RemoteQuestion])
    case answered(source: String?, answers: [RemoteQuestionAnswer])
}

enum RemoteMediaEvent: Equatable {
    case image(fileName: String, base64: String)
}

struct RemoteAgentDescriptor: Identifiable, Equatable {
    let agentId: String
    let name: String?
    let cwd: String?
    let model: String?
    let online: Bool
    
    var id: String { agentId }
    
    var displayName: String {
        if let name = name, !name.isEmpty { return name }
        if let cwd = cwd, !cwd.isEmpty { return (cwd as NSString).lastPathComponent }
        return String(agentId.suffix(8))
    }
}

enum RemoteRelayEvent: Equatable {
    case status(String)
    case acknowledged(messageId: String)
    case failed(messageId: String?, code: String?)
    case agents([RemoteAgentDescriptor])
    case agentJoined(RemoteAgentDescriptor)
    case agentLeft(agentId: String)
}

// MARK: - Workspace Explorer（只读浏览）

/// 文件树节点（懒加载：directory 可能没有 children，由 iOS 端按需请求展开）
struct RemoteWorkspaceNode: Identifiable, Equatable {
    let name: String
    let path: String
    let type: RemoteWorkspaceNodeType
    
    var id: String { path }
}

enum RemoteWorkspaceNodeType: String, Equatable {
    case file
    case directory
}

/// 目录树响应（workspace.tree）
struct RemoteWorkspaceTree: Equatable {
    let path: String
    let name: String
    let children: [RemoteWorkspaceNode]
}

enum WorkspaceFileType: String, Equatable, Codable {
    case image
    case text
    case binary
}

enum WorkspacePreviewKind: Equatable {
    case markdown
    case svg
    case image
    case text
    case binary
}

/// 文件内容响应（workspace.file）
struct RemoteWorkspaceFile: Equatable {
    let path: String
    let type: WorkspaceFileType
    let content: String?
    let base64: String?
    let size: Int
    let mimeType: String?
    
    init(
        path: String,
        type: WorkspaceFileType = .text,
        content: String? = nil,
        base64: String? = nil,
        size: Int,
        mimeType: String? = nil
    ) {
        self.path = path
        self.type = type
        self.content = content
        self.base64 = base64
        self.size = size
        self.mimeType = mimeType
    }
    
    var fileName: String { (path as NSString).lastPathComponent }
    var fileExtension: String { (path as NSString).pathExtension.lowercased() }
    var isText: Bool { type == .text }
    var isImage: Bool { type == .image }
    var previewKind: WorkspacePreviewKind {
        switch type {
        case .image:
            return fileExtension == "svg" ? .svg : .image
        case .binary:
            return .binary
        case .text:
            switch fileExtension {
            case "md", "markdown": return .markdown
            case "svg": return .svg
            default: return .text
            }
        }
    }
}

/// 错误响应（workspace.error）
struct RemoteWorkspaceError: Equatable {
    let path: String?
    let message: String
}

/// 搜索结果项（workspace.searchResult）
struct RemoteWorkspaceSearchHit: Identifiable, Equatable {
    let path: String
    let filename: String
    let type: RemoteWorkspaceNodeType
    var id: String { path }
}

/// 搜索响应（workspace.searchResult）
struct RemoteWorkspaceSearchResult: Equatable {
    let query: String
    let hits: [RemoteWorkspaceSearchHit]
}

enum RemoteWorkspaceEvent: Equatable {
    case tree(RemoteWorkspaceTree)
    case file(RemoteWorkspaceFile)
    case error(RemoteWorkspaceError)
    case searchResult(RemoteWorkspaceSearchResult)
}

