import SwiftUI

// MARK: - Dashboard 派生数据（只读投影，非新状态）

/// 首页 Dashboard 的展示等级：颜色映射由 View 层完成，测试只断言等级。
enum DashboardStatusLevel: Equatable {
    case disconnected       // 未连接（红）
    case offline            // 已连接但 Agent 窗口离线（橙）
    case idle               // 在线就绪（灰/绿）
    case active             // 接收/思考/规划（橙）
    case working            // 执行工具/生成中（绿，脉冲）
    case completed          // 本轮完成（绿）
    case failed             // 出错（红）
}

extension ConversationStore {

    // MARK: - ① 项目与会话

    /// 项目名：当前 Agent 的 displayName（name > cwd basename > id 尾）。
    var projectName: String {
        guard let id = currentAgentId,
              let agent = agents.first(where: { $0.agentId == id }) else { return "未连接" }
        return agent.displayName
    }

    /// 会话名：当前 Session 的 displayName；无会话时占位。
    var sessionDisplayName: String {
        sessionState?.displayName ?? "当前会话"
    }

    // MARK: - ② Agent 状态

    /// 首页状态等级（颜色由 View 映射）。
    var dashboardStatusLevel: DashboardStatusLevel {
        if !isConnected { return .disconnected }
        if !isAgentOnline { return .offline }
        switch agentState {
        case .idle:              return .idle
        case .receiving,
             .thinking,
             .planning:          return .active
        case .usingTool,
             .streaming:         return .working
        case .completed:         return .completed
        case .error:             return .failed
        }
    }

    /// 状态主文案（与 AgentStatusHeader 一致）。
    var dashboardStatusText: String {
        switch agentState {
        case .idle:       return "就绪"
        case .receiving:  return "接收中"
        case .thinking:   return "思考中"
        case .planning:   return "规划中"
        case .usingTool:  return "执行工具"
        case .streaming:  return "生成中"
        case .completed:  return "完成"
        case .error(let message): return message.isEmpty ? "出错" : message
        }
    }

    /// 是否"在干活"（用于脉冲动画/辅助文案）。
    var isDashboardWorking: Bool {
        agentState.isWorking
    }

    // MARK: - ③ 当前任务

    /// 当前正在做什么：优先 Tool 描述 → 阶段 → 最近活动标题。
    var currentActionText: String {
        if case .usingTool(_, let description) = agentState, !description.isEmpty {
            return description
        }
        if case .usingTool(let tool, _) = agentState {
            return tool
        }
        if case .streaming = agentState { return "生成回复中…" }
        if case .thinking = agentState { return "正在思考…" }
        if case .planning = agentState { return "正在规划…" }
        if let last = activityEvents.last(where: { $0.type != .userRequest }) {
            return last.title
        }
        return "空闲"
    }

    /// 最近修改的文件数量（用于副文案 "Modified N files"）。
    var recentFileChangeCount: Int {
        recentChanges.count
    }

    // MARK: - ④ 最近修改

    /// 首页展示的最近修改（最多 5 条）。
    var recentChangesForDashboard: [RecentFileChange] {
        Array(recentChanges.prefix(5))
    }

    // MARK: - ⑦ 模型与用量

    /// 模型显示名：currentModel 优先，兜底 usageInfo.model。
    var modelDisplayName: String {
        if let model = currentModel, !model.isEmpty { return model }
        if let model = usageInfo?.model, !model.isEmpty { return model }
        return "未加载"
    }

    /// 用量显示（如 "12k tokens"）；无数据时 nil（View 隐藏该段）。
    var usageDisplayText: String? {
        guard let usage = usageInfo, let tokens = usage.contextTokens else { return nil }
        let k = max(1, Int((Double(tokens) / 1000).rounded()))
        return "\(k)k tokens"
    }

    // MARK: - ⑥ 最近活动

    /// 首页展示的最近活动（最多 3 条，用户请求逆序最新在前）。
    var recentActivitiesForDashboard: [ActivityEvent] {
        Array(activityEvents.suffix(3)).reversed()
    }

    // MARK: - ⑤ 快速继续

    /// Continue 主按钮是否可用（在线才可继续会话）。
    var canContinue: Bool {
        isConnected && isAgentOnline
    }
}
