import SwiftUI

// MARK: - Agent Dashboard（首页）

/// 首页：打开 App 第一屏，3 秒内回答三个问题：
/// 1. Agent 是否在线、在干什么
/// 2. 项目最近发生了什么
/// 3. 如何继续
///
/// 数据流：RemoteEvent → ConversationStore（唯一状态源）→ 本视图只读投影。
/// 全部展示数据来自 ConversationStore+Dashboard.swift 的派生 computed，无新增业务状态。
struct DashboardView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    projectHeader
                        .padding(.horizontal, 16)
                        .padding(.top, 12)

                    statusBlock
                        .padding(.horizontal, 16)
                        .padding(.top, 16)

                    Divider()
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)

                    recentChangesBlock
                        .padding(.horizontal, 16)

                    continueButton
                        .padding(.horizontal, 16)
                        .padding(.top, 20)

                    recentActivitiesBlock
                        .padding(.horizontal, 16)
                        .padding(.top, 26)
                        .padding(.bottom, 24)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    // MARK: - ① 项目与会话

    private var projectHeader: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(store.projectName)
                    .font(.title2.weight(.bold))
                    .lineLimit(1)
                Text(store.sessionDisplayName)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            windowMenu
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("项目 \(store.projectName)，\(store.sessionDisplayName)")
    }

    /// 窗口选择（与 AgentStatusHeader 同逻辑）。
    private var windowMenu: some View {
        Menu {
            if store.agents.isEmpty {
                Text("无在线窗口").font(.caption).foregroundColor(.secondary)
            } else {
                ForEach(store.agents) { agent in
                    Button {
                        viewModel.switchTarget(to: agent.agentId)
                    } label: {
                        if agent.agentId == store.currentAgentId {
                            Label(agent.displayName, systemImage: "checkmark")
                        } else {
                            Text(agent.displayName)
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "macwindow")
                .font(.system(size: 15))
                .foregroundStyle(.secondary)
                .frame(width: 30, height: 30)
                .background(Color.gray.opacity(0.12), in: Circle())
        }
        .accessibilityLabel("切换窗口")
    }

    // MARK: - ②③ Agent 状态与当前任务

    private var statusBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 8, height: 8)
                    .scaleEffect(store.isDashboardWorking ? pulseScale : 1)
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.8).repeatForever(autoreverses: true), value: pulseScale)
                Text("Agent \(store.dashboardStatusText)")
                    .font(.headline)
                    .foregroundStyle(statusColor)
                Spacer(minLength: 4)
                if store.isDashboardWorking {
                    if reduceMotion {
                        Image(systemName: "circle.dotted").font(.subheadline).foregroundStyle(Color.orange)
                    } else {
                        ProgressView().scaleEffect(0.7).tint(.orange)
                    }
                }
            }

            if store.canContinue || store.isDashboardWorking {
                Text(store.currentActionText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            // 模型 · 用量 —— 小状态，点击进入设置详情
            Button {
                viewModel.activeTab = 3
            } label: {
                HStack(spacing: 4) {
                    Text(store.modelDisplayName)
                        .font(.caption.weight(.medium))
                    if let usage = store.usageDisplayText {
                        Text("·").foregroundStyle(.tertiary)
                        Text(usage)
                            .font(.caption.monospacedDigit())
                    }
                }
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("模型 \(store.modelDisplayName)，点击查看详情")
        }
        .accessibilityElement(children: .combine)
    }

    private var pulseScale: CGFloat {
        store.isDashboardWorking ? 1.35 : 1.0
    }

    private var statusColor: Color {
        switch store.dashboardStatusLevel {
        case .disconnected: return .red
        case .offline:      return .orange
        case .idle:         return .green
        case .active:       return .orange
        case .working:      return .green
        case .completed:    return .green
        case .failed:       return .red
        }
    }

    // MARK: - ④ 最近修改

    private var recentChangesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近修改")
                    .font(.headline)
                Spacer()
                if !store.recentChanges.isEmpty {
                    Button("全部文件") {
                        viewModel.activeTab = 2
                    }
                    .font(.caption.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
            }

            if store.recentChanges.isEmpty {
                if store.canContinue {
                    emptyHint("暂无文件变更，连接后自动同步")
                } else {
                    emptyHint("连接后显示最近修改")
                }
            } else {
                ForEach(store.recentChangesForDashboard) { change in
                    Button {
                        viewModel.openFileInWorkspace(path: change.path)
                    } label: {
                        recentChangeRow(change)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func recentChangeRow(_ change: RecentFileChange) -> some View {
        HStack(spacing: 10) {
            Image(systemName: changeTypeIcon(change.changeType))
                .font(.caption)
                .foregroundStyle(changeTypeColor(change.changeType))
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 1) {
                Text(change.fileName)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
                Text(change.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            Text(changeTypeLabel(change.changeType))
                .font(.caption2.weight(.semibold))
                .foregroundStyle(changeTypeColor(change.changeType))
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .accessibilityLabel("\(changeTypeLabel(change.changeType)) \(change.path)")
    }

    private func changeTypeIcon(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "plus.circle.fill"
        case .modified: return "pencil.circle.fill"
        case .deleted: return "minus.circle.fill"
        }
    }

    private func changeTypeColor(_ type: FileChangeType) -> Color {
        switch type {
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
        }
    }

    private func changeTypeLabel(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }

    private func emptyHint(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.vertical, 8)
    }

    // MARK: - ⑤ 快速继续

    private var continueButton: some View {
        Button {
            if store.canContinue {
                viewModel.activeTab = 1
            } else {
                viewModel.connect()
                viewModel.activeTab = 1
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: store.canContinue ? "arrow.forward.circle.fill" : "bolt.circle.fill")
                Text(store.canContinue ? "继续聊天" : "连接并继续")
                    .font(.headline)
            }
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(
                store.canContinue ? Color.accentColor : Color.accentColor.opacity(0.7),
                in: Capsule()
            )
        }
        .buttonStyle(.plain)
        .accessibilityHint(store.canContinue ? "进入当前会话" : "连接电脑后进入会话")
    }

    // MARK: - ⑥ 最近活动

    private var recentActivitiesBlock: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("最近活动")
                    .font(.headline)
                Spacer()
                if !store.activityEvents.isEmpty {
                    NavigationLink {
                        ActivityView(viewModel: viewModel)
                    } label: {
                        Text("查看全部")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Color.accentColor)
                    }
                }
            }

            if store.activityEvents.isEmpty {
                emptyHint(store.canContinue ? "暂无活动" : "连接后显示最近活动")
            } else {
                ForEach(store.recentActivitiesForDashboard) { event in
                    activityRow(event)
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func activityRow(_ event: ActivityEvent) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: activityIcon(event.type))
                .font(.caption)
                .foregroundStyle(activityColor(event.type))
                .frame(width: 24, height: 24)
                .background(activityColor(event.type).opacity(0.12), in: Circle())
            VStack(alignment: .leading, spacing: 1) {
                Text(event.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(event.type == .error ? Color.red : Color.primary)
                    .lineLimit(1)
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)
            Text(event.timestamp, style: .time)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .padding(.vertical, 5)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(event.title)\(event.detail.map { "，\($0)" } ?? "")")
    }

    private func activityIcon(_ type: ActivityEventType) -> String {
        switch type {
        case .userRequest:   return "person.crop.circle"
        case .thinking:      return "brain.head.profile"
        case .toolExecution: return "wrench.and.screwdriver"
        case .fileChange:    return "doc.badge.arrow.up"
        case .completed:     return "checkmark.circle"
        case .error:         return "exclamationmark.triangle"
        }
    }

    private func activityColor(_ type: ActivityEventType) -> Color {
        switch type {
        case .userRequest:   return .blue
        case .thinking:      return .orange
        case .toolExecution: return .purple
        case .fileChange:    return .green
        case .completed:     return .green
        case .error:         return .red
        }
    }
}
