import Foundation

/// Agent 当前阶段。状态只描述实时 UI，不写入会话历史。
enum AgentStatus: Equatable {
    case idle
    case receiving
    case thinking
    case planning
    case usingTool(tool: String, description: String)
    case streaming
    case completed
    case error(message: String)
    
    /// 是否仍处于一个活动 Agent 回合，用于终端指示和工具卡片完成折叠。
    var isWorking: Bool {
        switch self {
        case .receiving, .thinking, .planning, .usingTool, .streaming:
            return true
        case .idle, .completed, .error:
            return false
        }
    }
    
    /// Streaming 已由正文和光标反馈，不重复显示独立状态区域。
    var showsIndicator: Bool {
        switch self {
        case .idle, .streaming:
            return false
        default:
            return true
        }
    }
}

/// 可驱动状态机的客户端事件。既接收远端 agent.status，也接受现有 Tool/Streaming 事件作为兼容兜底。
enum AgentStateEvent: Equatable {
    case requestSent
    case remoteStatus(status: String, tool: String?, description: String?)
    case assistantStarted
    case assistantDelta
    case assistantEnded
    case toolStarted(tool: String, description: String)
    case toolEnded
    case disconnected
    case completionExpired
}

/// 单一状态归并器：所有 Pi/WebSocket/UI 事件都通过这里转换成 AgentStatus。
struct AgentStateReducer {
    private(set) var state: AgentStatus = .idle
    
    @discardableResult
    mutating func reduce(_ event: AgentStateEvent) -> AgentStatus {
        switch event {
        case .requestSent:
            // 忙时发送的消息会进入扩展队列，不覆盖当前正在展示的工作阶段。
            if !state.isWorking {
                state = .receiving
            }
            
        case let .remoteStatus(status, tool, description):
            switch status {
            case "receiving":
                state = .receiving
            case "running", "thinking":
                state = .thinking
            case "planning":
                state = .planning
            case "using_tool":
                state = .usingTool(
                    tool: tool ?? "tool",
                    description: description ?? ""
                )
            case "streaming":
                state = .streaming
            case "completed":
                state = .completed
            case "error":
                state = .error(message: description ?? "处理失败")
            case "idle":
                state = .idle
            default:
                break
            }
            
        case .assistantStarted:
            if state == .idle || state == .receiving {
                state = .thinking
            }
            
        case .assistantDelta:
            state = .streaming
            
        case .assistantEnded:
            // assistant.end 可能只是工具调用前的一段说明；整轮完成以 agent_end 为准。
            break
            
        case let .toolStarted(tool, description):
            state = .usingTool(tool: tool, description: description)
            
        case .toolEnded:
            state = .thinking
            
        case .disconnected:
            state = .idle
            
        case .completionExpired:
            switch state {
            case .completed, .error:
                state = .idle
            default:
                break
            }
        }
        return state
    }
}
