import SwiftUI

// MARK: - Agent Status Header 2.0

/// 信息密度增强版 Agent 状态 Header：
/// - 就绪态紧凑单行，工作中自动展开显示 Tool / Model / Session
/// - Thinking 动态省略号动画，Tool 执行计时器
/// - 点击任意位置展开/折叠详情面板
struct AgentStatusHeader: View {
    @ObservedObject var store: ConversationStore
    var onShowTimeline: (() -> Void)?
    var onShowSessions: (() -> Void)?
    var onToggleConnection: (() -> Void)?
    var onSwitchTarget: ((String) -> Void)?
    var wsURL: String = ""
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    @State private var isDetailExpanded = false
    @State private var toolStartTime: Date?
    @State private var elapsedSeconds: Int = 0
    
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()
    
    var body: some View {
        VStack(spacing: 0) {
            // 主行：连接 + 阶段 + 展开按钮
            Button {
                if reduceMotion {
                    isDetailExpanded.toggle()
                } else {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        isDetailExpanded.toggle()
                    }
                }
            } label: {
                mainRow
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(isDetailExpanded ? "收起详情" : "展开详情")
            
            // 工作摘要行：Tool / Model / Session（工作中自动展示，或手动展开）
            if store.agentState.isWorking || isDetailExpanded {
                detailRow
                    .transition(
                        reduceMotion
                            ? .identity
                            : .opacity.combined(with: .move(edge: .top))
                    )
            }
            
            // 手动展开时显示最近事件摘要
            if isDetailExpanded, let lastActivity = store.activityEvents.last {
                Divider()
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                
                HStack(spacing: 6) {
                    Image(systemName: "clock")
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary)
                    Text("最近: \(lastActivity.title)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(lastActivity.timestamp, style: .time)
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 6)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, store.agentState.isWorking ? 10 : 6)
        .background(backgroundStyle)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.25), value: store.agentState)
        .onChange(of: store.agentState) { newState in
            handleStateChange(newState)
        }
        .onReceive(timer) { _ in
            if let start = toolStartTime {
                elapsedSeconds = Int(Date().timeIntervalSince(start))
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
    }
    
    // MARK: - Main Row
    
    private var mainRow: some View {
        HStack(spacing: 8) {
            connectionIndicator
            
            statusLabel
            
            // 模型徽章常驻显示（不再只在工作中/展开时才出现）
            let displayModel = store.currentModel ?? store.usageInfo?.model
            if let model = displayModel, !model.isEmpty {
                modelBadge(model)
            }
            
            Spacer(minLength: 4)
            
            if store.agentState.isWorking {
                workingAnimation
            }
            
            if let onShowTimeline, store.currentTrace?.shouldDisplay == true {
                Button {
                    onShowTimeline()
                } label: {
                    Image(systemName: "list.bullet.indent")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看任务时间线")
            }
            
            // 窗口 / 会话选择器
            Menu {
                if store.agents.isEmpty {
                    Text("无在线窗口").font(.caption).foregroundColor(.secondary)
                } else {
                    ForEach(store.agents) { agent in
                        Button {
                            onSwitchTarget?(agent.agentId)
                        } label: {
                            if agent.agentId == store.currentAgentId {
                                Label(agent.displayName, systemImage: "checkmark")
                            } else {
                                Text(agent.displayName)
                            }
                        }
                    }
                }
                if !store.agents.isEmpty { Divider() }
                Button { onShowSessions?() } label: {
                    Label("历史会话", systemImage: "clock.arrow.circlepath")
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "macwindow").font(.caption2)
                    Text(store.currentAgentId.flatMap { id in store.agents.first { $0.agentId == id }?.displayName } ?? "局域网")
                        .font(.caption.weight(.medium)).lineLimit(1)
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
                .background(Color.gray.opacity(0.12), in: Capsule())
            }
            
            // 连接/断开
            if let onToggleConnection {
                Button(action: onToggleConnection) {
                    Image(systemName: store.isConnected ? "pause.circle" : "arrow.clockwise.circle")
                        .font(.system(size: 15))
                        .foregroundColor(store.isConnected ? .orange : .blue)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isConnected ? "断开连接" : "重新连接")
            }
            
            Image(systemName: isDetailExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .rotationEffect(.degrees(isDetailExpanded ? 0 : 0))
                .opacity(0.5)
        }
    }
    
    // MARK: - Connection
    
    private var connectionIndicator: some View {
        HStack(spacing: 4) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
                .scaleEffect(store.isConnected && store.agentState.isWorking ? pulseScale : 1)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
            Text(connectionLabel)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }
    
    private var pulseScale: CGFloat {
        store.agentState.isWorking ? 1.3 : 1.0
    }
    
    private var connectionColor: Color {
        if !store.isConnected { return .red }
        if !store.isAgentOnline { return .orange }
        return .green
    }
    
    private var connectionLabel: String {
        if !store.isConnected { return "离线" }
        if !store.isAgentOnline { return "PC 离线" }
        return "在线"
    }
    
    // MARK: - Status Label
    
    private var statusLabel: some View {
        HStack(spacing: 4) {
            Text(statusText)
                .font(.caption.weight(.semibold))
                .foregroundStyle(statusColor)
            
            if case .thinking = store.agentState {
                thinkingDots
            }
        }
    }
    
    private var statusText: String {
        switch store.agentState {
        case .idle:       return "就绪"
        case .receiving:  return "接收中"
        case .thinking:   return "思考中"
        case .planning:   return "规划中"
        case .usingTool:  return "执行工具"
        case .streaming:  return "生成中"
        case .completed:  return "完成"
        case .error(let msg): return msg.isEmpty ? "出错" : msg
        }
    }
    
    private var statusColor: Color {
        switch store.agentState {
        case .idle:       return .secondary
        case .receiving, .thinking, .planning: return .orange
        case .usingTool:  return .purple
        case .streaming:  return .blue
        case .completed:  return .green
        case .error:      return .red
        }
    }
    
    // MARK: - Thinking Dots Animation
    
    @ViewBuilder
    private var thinkingDots: some View {
        if reduceMotion {
            Text("…")
                .font(.caption.weight(.bold))
                .foregroundStyle(.orange)
        } else {
            AnimatedThinkingDots()
        }
    }
    
    @ViewBuilder
    private var workingAnimation: some View {
        if reduceMotion {
            Image(systemName: "circle.dotted")
                .font(.caption2)
                .foregroundStyle(.orange)
        } else {
            ProgressView()
                .scaleEffect(0.6)
                .tint(.orange)
        }
    }
    
    // MARK: - Detail Row
    
    @ViewBuilder
    private var detailRow: some View {
        HStack(spacing: 10) {
            if case let .usingTool(tool, description) = store.agentState {
                toolBadge(name: tool, detail: description)
            } else if let trace = store.currentTrace, trace.shouldDisplay {
                HStack(spacing: 3) {
                    Image(systemName: "list.clipboard")
                        .font(.system(size: 9))
                    Text("\(trace.operationCount) 个步骤")
                        .fontWeight(.medium)
                }
                .foregroundStyle(.purple)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(Color.purple.opacity(0.1), in: Capsule())
            }
            
            let displayModel = store.currentModel ?? store.usageInfo?.model
            if let model = displayModel {
                modelBadge(model)
            }
            
            if let session = store.sessionState {
                sessionBadge(session.displayName)
            }

            // Transient model switch result (non-chat feedback)
            if let sel = store.lastModelSelection {
                modelSwitchPill(sel: sel)
                    .onAppear {
                        // Auto-dismiss after 4s
                        let modelId = sel.modelId
                        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                            if store.lastModelSelection?.modelId == modelId {
                                store.clearModelSelectionFeedback()
                            }
                        }
                    }
            }

            Spacer(minLength: 0)
        }
        .font(.caption2)
        .padding(.top, 4)
    }
    
    private func toolBadge(name: String, detail: String) -> some View {
        HStack(spacing: 4) {
            Image(systemName: "hammer")
                .font(.system(size: 9))
            Text(name)
                .fontWeight(.medium)
            if !detail.isEmpty {
                Text("·")
                Text(detail)
                    .lineLimit(1)
            }
            if elapsedSeconds > 0 {
                Text(timeString)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(.purple)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.purple.opacity(0.1), in: Capsule())
        .accessibilityLabel("正在执行 \(name) \(timeString)")
    }
    
    private var timeString: String {
        if elapsedSeconds < 60 {
            return "\(elapsedSeconds)s"
        }
        let mins = elapsedSeconds / 60
        let secs = elapsedSeconds % 60
        return "\(mins)m\(secs)s"
    }
    
    private func modelBadge(_ model: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu")
                .font(.system(size: 9))
            Text(model)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .accessibilityLabel("模型: \(model)")
    }
    
    private func sessionBadge(_ name: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "folder")
                .font(.system(size: 9))
            Text(name)
                .lineLimit(1)
        }
        .foregroundStyle(.secondary)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Color.secondary.opacity(0.1), in: Capsule())
        .accessibilityLabel("会话: \(name)")
    }

    // Transient model switch feedback pill (non-chat)
    private func modelSwitchPill(sel: ConversationStore.ModelSelectionResult) -> some View {
        let icon = sel.success ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle"
        let color: Color = sel.success ? .blue : .red
        let text = sel.success ? "已切换: \(sel.modelId)" : "切换失败: \(sel.modelId)"
        return HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(color.opacity(0.12), in: Capsule())
    }

    // MARK: - State Change
    
    private func handleStateChange(_ newState: AgentStatus) {
        switch newState {
        case .usingTool:
            toolStartTime = Date()
            elapsedSeconds = 0
        case .idle, .completed, .error:
            toolStartTime = nil
            elapsedSeconds = 0
            isDetailExpanded = false
        default:
            break
        }
    }
    
    // MARK: - Background
    
    private var backgroundStyle: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(.ultraThinMaterial)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
    }
    
    // MARK: - Accessibility
    
    private var accessibilitySummary: String {
        var parts: [String] = [connectionLabel, statusText]
        if case let .usingTool(tool, _) = store.agentState {
            parts.append("工具: \(tool)")
        }
        if let model = store.currentModel ?? store.usageInfo?.model {
            parts.append("模型: \(model)")
        }
        return parts.joined(separator: "，")
    }
}

// MARK: - Animated Thinking Dots

private struct AnimatedThinkingDots: View {
    @State private var dotCount = 0
    
    var body: some View {
        Text(String(repeating: ".", count: dotCount % 3 + 1))
            .font(.caption.weight(.bold))
            .foregroundStyle(.orange)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.4).repeatForever(autoreverses: false)) {
                    // trigger state changes
                }
            }
            .onReceive(Timer.publish(every: 0.4, on: .main, in: .common).autoconnect()) { _ in
                dotCount += 1
            }
    }
}
