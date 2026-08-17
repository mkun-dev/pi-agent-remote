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
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                    Text("最近: \(lastActivity.title)")
                        .font(PiDesignSystem.Font.caption2)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .lineLimit(1)
                    Spacer()
                    Text(lastActivity.timestamp, style: .time)
                        .font(PiDesignSystem.Font.monoDigit)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
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
                        .foregroundStyle(PiDesignSystem.Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看任务时间线")
            }
            
            // 窗口 / 会话选择器
            Menu {
                if store.agents.isEmpty {
                    Text("无在线窗口").font(PiDesignSystem.Font.caption).foregroundStyle(PiDesignSystem.Color.secondary)
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
                .piCapsuleSurface()
            }
            
            // 连接/断开
            if let onToggleConnection {
                Button(action: onToggleConnection) {
                    Image(systemName: store.isConnected ? "pause.circle" : "arrow.clockwise.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(store.isConnected ? PiDesignSystem.Color.thinking : PiDesignSystem.Color.accent)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(store.isConnected ? "断开连接" : "重新连接")
            }
            
            Image(systemName: isDetailExpanded ? "chevron.up" : "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PiDesignSystem.Color.secondary)
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
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
    }
    
    private var pulseScale: CGFloat {
        store.agentState.isWorking ? 1.3 : 1.0
    }
    
    private var connectionColor: Color {
        switch store.connectionSnapshot.phase {
        case .connected:
            return store.isAgentOnline ? PiDesignSystem.Color.connected : PiDesignSystem.Color.pcOffline
        case .connecting, .reconnecting:
            return PiDesignSystem.Color.pcOffline
        case .error, .disconnected:
            return PiDesignSystem.Color.failed
        }
    }
    
    private var connectionLabel: String {
        switch store.connectionSnapshot.phase {
        case .connecting:
            return "连接中"
        case .reconnecting:
            return "重连中"
        case .connected:
            if !store.isAgentOnline { return "PC 离线" }
            return "在线"
        case .error:
            return store.connectionSnapshot.summary
        case .disconnected:
            return "离线"
        }
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
        if !store.isConnected { return store.connectionSnapshot.summary }
        if store.connectionSnapshot.summary == "当前窗口离线" || store.connectionSnapshot.summary == "目标窗口不明确" {
            return store.connectionSnapshot.summary
        }
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
        if !store.isConnected {
            switch store.connectionSnapshot.phase {
            case .connecting, .reconnecting:
                return PiDesignSystem.Color.thinking
            case .error, .disconnected:
                return PiDesignSystem.Color.failed
            case .connected:
                return PiDesignSystem.Color.secondary
            }
        }
        if store.connectionSnapshot.summary == "当前窗口离线" || store.connectionSnapshot.summary == "目标窗口不明确" {
            return PiDesignSystem.Color.thinking
        }
        switch store.agentState {
        case .idle:       return PiDesignSystem.Color.secondary
        case .receiving, .thinking, .planning: return PiDesignSystem.Color.thinking
        case .usingTool:  return PiDesignSystem.Color.tool
        case .streaming:  return PiDesignSystem.Color.streaming
        case .completed:  return PiDesignSystem.Color.completed
        case .error:      return PiDesignSystem.Color.failed
        }
    }
    
    // MARK: - Thinking Dots Animation
    
    @ViewBuilder
    private var thinkingDots: some View {
        if reduceMotion {
            Text("…")
                .font(PiDesignSystem.Font.captionBold)
                .foregroundStyle(PiDesignSystem.Color.thinking)
        } else {
            AnimatedThinkingDots()
        }
    }
    
    @ViewBuilder
    private var workingAnimation: some View {
        if reduceMotion {
            Image(systemName: "circle.dotted")
                .font(PiDesignSystem.Font.caption2)
                .foregroundStyle(PiDesignSystem.Color.thinking)
        } else {
            ProgressView()
                .scaleEffect(0.6)
                .tint(PiDesignSystem.Color.thinking)
        }
    }
    
    // MARK: - Detail Row
    
    @ViewBuilder
    private var detailRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                statusTile(title: "Relay", value: relayValue, icon: "dot.radiowaves.left.and.right", color: connectionColor)
                statusTile(title: "Agent", value: agentValue, icon: "desktopcomputer", color: store.isAgentOnline ? PiDesignSystem.Color.connected : PiDesignSystem.Color.pcOffline)
                statusTile(title: "Target", value: targetValue, icon: "macwindow", color: PiDesignSystem.Color.secondary)
            }

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    if case let .usingTool(tool, description) = store.agentState {
                        toolBadge(name: tool, detail: description)
                    } else if let trace = store.currentTrace, trace.shouldDisplay {
                        compactBadge(icon: "list.clipboard", text: "\(trace.operationCount) 个步骤", color: PiDesignSystem.Color.tool)
                    }
                    
                    let displayModel = store.currentModel ?? store.usageInfo?.model
                    if let model = displayModel {
                        modelBadge(model)
                    }
                    
                    if let session = store.sessionState {
                        sessionBadge(session.displayName)
                    }

                    if let sel = store.lastModelSelection {
                        modelSwitchPill(sel: sel)
                            .onAppear {
                                let modelId = sel.modelId
                                DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
                                    if store.lastModelSelection?.modelId == modelId {
                                        store.clearModelSelectionFeedback()
                                    }
                                }
                            }
                    }
                }
            }
            
            if isDetailExpanded {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = store.connectionSnapshot.lastError, !error.isEmpty {
                        infoRow(icon: "exclamationmark.triangle.fill", text: error, color: PiDesignSystem.Color.failed)
                    } else if let detail = store.connectionSnapshot.detail, !detail.isEmpty {
                        infoRow(icon: "link", text: detail, color: PiDesignSystem.Color.secondary)
                    }
                    if let lastConnectedAt = store.connectionSnapshot.lastConnectedAt {
                        infoRow(icon: "checkmark.circle", text: "上次连接 \(timeFormatter.string(from: lastConnectedAt))", color: PiDesignSystem.Color.secondary)
                    }
                    if let lastDisconnectedAt = store.connectionSnapshot.lastDisconnectedAt,
                       !store.isConnected {
                        infoRow(icon: "xmark.circle", text: "上次断开 \(timeFormatter.string(from: lastDisconnectedAt))", color: PiDesignSystem.Color.secondary)
                    }
                }
                .padding(.top, 2)
            }
        }
        .font(.caption2)
        .padding(.top, 6)
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
                    .foregroundStyle(PiDesignSystem.Color.secondary)
            }
        }
        .foregroundStyle(PiDesignSystem.Color.tool)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .piTintCapsule(PiDesignSystem.Color.tool, opacity: 0.1)
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
        compactBadge(icon: "cpu", text: model, color: PiDesignSystem.Color.secondary)
            .accessibilityLabel("模型: \(model)")
    }
    
    private func sessionBadge(_ name: String) -> some View {
        compactBadge(icon: "folder", text: name, color: PiDesignSystem.Color.secondary)
            .accessibilityLabel("会话: \(name)")
    }

    // Transient model switch feedback pill (non-chat)
    private func modelSwitchPill(sel: ConversationStore.ModelSelectionResult) -> some View {
        let icon = sel.success ? "arrow.triangle.2.circlepath" : "exclamationmark.triangle"
        let color: Color = sel.success ? PiDesignSystem.Color.accent : PiDesignSystem.Color.failed
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
        .piTintCapsule(color, opacity: 0.12)
    }

    private var relayValue: String {
        switch store.connectionSnapshot.phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting(let seconds): return "\(seconds)s"
        case .error: return "错误"
        case .disconnected: return "离线"
        }
    }
    
    private var agentValue: String {
        if case .unknown = store.connectionSnapshot.agentReachability {
            return store.isAgentOnline ? "在线" : "未知"
        }
        return store.connectionSnapshot.agentReachability.summaryText
    }
    
    private var targetValue: String {
        if let id = store.currentAgentId,
           let agent = store.agents.first(where: { $0.agentId == id }) {
            return agent.displayName
        }
        return "未选择"
    }
    
    private func statusTile(title: String, value: String, icon: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 10, weight: .medium))
                Text(title)
                    .font(PiDesignSystem.Font.caption2)
            }
            .foregroundStyle(color)
            Text(value)
                .font(PiDesignSystem.Font.captionBold)
                .foregroundStyle(PiDesignSystem.Color.primary)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    private func compactBadge(icon: String, text: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Image(systemName: icon)
                .font(.system(size: 9))
            Text(text)
                .lineLimit(1)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .piTintCapsule(color, opacity: 0.1)
    }
    
    private func infoRow(icon: String, text: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 14, alignment: .center)
            Text(text)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
    
    private var timeFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter
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
            .fill(PiDesignSystem.Color.surface)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(PiDesignSystem.Color.border, lineWidth: 1)
            }
    }
    
    // MARK: - Accessibility
    
    private var accessibilitySummary: String {
        var parts: [String] = [connectionLabel, statusText, "Relay: \(relayValue)", "Agent: \(agentValue)", "Target: \(targetValue)"]
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
            .font(PiDesignSystem.Font.captionBold)
            .foregroundStyle(PiDesignSystem.Color.thinking)
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
