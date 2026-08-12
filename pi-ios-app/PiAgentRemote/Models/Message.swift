import Foundation

/// 工具执行状态（飞书式进度卡片）
enum ToolStatus: Equatable {
    case running, done, error
}

/// 聚合工具组状态，由 ToolEntry 实时计算，不额外修改 WebSocket 协议。
enum ToolGroupStatus: Equatable {
    case running
    case completed
    case failed
}

/// 工具卡片中的单条工具条目（飞书式：一张卡片聚合多个工具）
struct ToolEntry: Equatable {
    let toolCallId: String
    let toolName: String
    let detail: String
    var status: ToolStatus = .running
}

/// 工具组在聊天界面的展示状态（仅客户端渲染，不改变通信协议）
enum ToolGroupState: Equatable {
    case working    // Agent 工作中，默认展开
    case collapsed  // Agent 完成后自动折叠
    case expanded   // 用户主动查看历史详情
}

struct Message: Identifiable, Equatable {
    let id: String
    let sender: Sender
    /// 内容可变（thinking 增量合并时需要追加）
    var content: String
    let timestamp: Date
    let kind: Kind
    /// 送达状态（仅用户消息有效；默认 sent 表示无需跟踪）
    var delivery: DeliveryState = .sent
    /// 是否为会话历史回放（历史消息不做打字动画）
    var isHistory: Bool = false
    /// Assistant 正文是否仍在流式生成（控制原地更新与光标）
    var isStreaming: Bool = false
    /// 与该 Assistant 回复绑定的 Agent 执行过程（仅 iOS 展示层）。
    var trace: AgentTrace? = nil
    /// 多段 Assistant 中已被最新最终回复取代的说明，底层保留但聊天页隐藏。
    var isIntermediateAssistant: Bool = false
    /// Tool/File 原消息已收入 Trace；底层与时间线保留，聊天页避免重复展示。
    var isIncludedInTrace: Bool = false
    /// 图片上传产生的保存确认/FileChange，底层保留但聊天页由图片气泡状态替代。
    var isMediaStatusMessage: Bool = false
    /// 工具调用 ID（tool.start/end 匹配，用于原地更新进度卡片）
    var toolCallId: String? = nil
    /// 工具卡片条目列表（飞书式：一张卡片聚合多个工具，支持原地更新）
    var toolEntries: [ToolEntry] = []
    /// 工具组展示状态：工作中展开，Agent 完成后折叠，可手动重新展开
    var toolGroupState: ToolGroupState = .working
    /// 同一 Agent 回合内聚合的文件变化
    var fileChanges: [FileChange] = []
    var isFileChangesExpanded: Bool = false
    /// 图片附件；旧 media.image 仍可通过 imageData 兼容渲染。
    var attachments: [Attachment] = []
    /// 旧版单图数据（kind == .image 时有效）
    var imageData: Data? = nil
    
    enum Sender: Equatable {
        case user
        case pi
        case system
    }
    
    enum Kind: Equatable {
        case text          // 普通文本或最终回复
        case thinking      // 流式思考
        case tool          // 工具调用
        case terminal      // 终端输出
        case status        // 状态提示
        case fileChanges   // 文件变化摘要组
        case image         // 图片消息
    }
    
    /// 消息送达状态（NAT 穿透 ACK，Phase 3）
    enum DeliveryState: Equatable {
        case sending      // ⏳ 已发出，等待中继 ACK
        case sent         // ✅ 中继已确认转发
        case failed       // ❌ 未送达（agent 离线或超时）
    }
    
    var isUser: Bool { sender == .user }
    var isPi: Bool { sender == .pi }
    var isSystem: Bool { sender == .system }
    
    var toolGroupStatus: ToolGroupStatus {
        if toolEntries.contains(where: { $0.status == .running }) { return .running }
        if toolEntries.contains(where: { $0.status == .error }) { return .failed }
        return .completed
    }
}
