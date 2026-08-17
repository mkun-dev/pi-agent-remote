import Foundation

/// Conversation 安全过滤层（防御性白名单）。
///
/// 核心原则：**日志 ≠ Conversation**。
///
/// - **User Conversation**：只有这类事件允许进入消息列表（`messages`）：
///   用户消息（agent.input）、Agent 流式回复（assistant.*）、工具卡片（tool.*）、
///   文件变化（file.change）、图片（media.image）、历史回放（session.history）、
///   Agent 功能反馈（agent.output，如 /model 切换确认、排队提示等——是用户操作的响应，不是调试日志）。
/// - **System Event**：只更新状态投影（availableModels / usageInfo / workspace 缓存 / 会话元数据…），
///   永远不得生成 Message。包括：agent.status、session.info/update/list、questionnaire.*。
/// - **Debug Log**：只允许 Console / Debug Panel / File Log。
///   包括：workspace.*、model.*、usage.*、relay.*。
///
/// 即使未来协议新增事件类型，也必须显式加入本白名单才能进入聊天——默认拒绝，
/// 防止内部日志（workspace 调试、model/usage 状态、relay 通信、transport 调试）混入用户聊天。
enum ConversationMessageFilter {
    /// 事件分类
    enum EntryKind {
        case conversation   // 允许进入消息列表（用户对话）
        case systemEvent    // 只更新状态投影，禁止进入消息列表
        case debugLog       // 只允许 Console / Debug Panel / File Log
    }

    /// 白名单判定：该事件是否允许进入消息列表。
    static func allowsMessageEntry(_ payload: RemoteEvent.Payload) -> Bool {
        switch payload {
        case .agent(let event):
            switch event {
            case .input:
                return true   // 用户消息（PC 回显 / 本地记录）
            case .output:
                return true   // Agent 功能反馈（/model 切换、排队提示、问卷确认等；旧协议正文兜底）
            case .status:
                return false  // agent.status 只驱动状态机，不生成消息
            }
        case .assistant:
            return true       // assistant.start / delta / end → 流式回复正文
        case .tool:
            return true       // tool.start / output / end → 工具卡片
        case .file:
            return true       // file.change → 文件变化卡片
        case .session(let event):
            switch event {
            case .history:
                return true   // 会话历史回放（applyHistory 生成历史消息）
            case .info, .update, .list, .switchAcknowledged:
                return false  // 会话元数据，只更新状态投影
            }
        case .media:
            return true       // media.image → 图片消息
        case .history:
            return false      // 历史控制事件（如 git 式撤回），只更新状态投影
        case .workspace, .model, .usage, .questionnaire, .relay, .unknown:
            return false      // 系统 / 调试事件，禁止进入聊天
        }
    }

    /// 事件分类（供日志分级与未来 Debug Panel 使用）。
    static func kind(of payload: RemoteEvent.Payload) -> EntryKind {
        if allowsMessageEntry(payload) { return .conversation }
        switch payload {
        case .workspace, .model, .usage, .relay:
            return .debugLog
        default:
            return .systemEvent
        }
    }

    /// 人类可读的事件类型名（Debug 日志用）。
    static func name(of payload: RemoteEvent.Payload) -> String {
        switch payload {
        case .agent(let event):
            switch event {
            case .input: return "agent.input"
            case .output: return "agent.output"
            case .status: return "agent.status"
            }
        case .assistant(let event):
            switch event {
            case .start: return "assistant.start"
            case .delta: return "assistant.delta"
            case .end: return "assistant.end"
            }
        case .tool(let event):
            switch event {
            case .start: return "tool.start"
            case .output: return "tool.output"
            case .end: return "tool.end"
            }
        case .file: return "file.change"
        case .session(let event):
            switch event {
            case .info: return "session.info"
            case .update: return "session.update"
            case .history: return "session.history"
            case .list: return "session.list_result"
            case .switchAcknowledged: return "session.switch_ack"
            }
        case .history:
            return "history.rewound"
        case .usage: return "usage.info"
        case .model(let event):
            switch event {
            case .list: return "model.list"
            case .selectionAcknowledged: return "model.select_ack"
            }
        case .questionnaire(let event):
            switch event {
            case .show: return "questionnaire.show"
            case .answered: return "questionnaire.answered"
            }
        case .media: return "media.image"
        case .relay(let event):
            switch event {
            case .status: return "relay.status"
            case .acknowledged: return "relay.ack"
            case .failed: return "relay.error"
            case .agents: return "relay.agents"
            case .agentJoined: return "relay.agent_join"
            case .agentLeft: return "relay.agent_leave"
            }
        case .workspace(let event):
            switch event {
            case .tree: return "workspace.tree"
            case .file: return "workspace.file"
            case .error: return "workspace.error"
            case .searchResult: return "workspace.searchResult"
            }
        case .unknown(let type): return type
        }
    }
}
