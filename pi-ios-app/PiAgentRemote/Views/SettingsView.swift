import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var viewModel: ChatViewModel

    private var store: ConversationStore { viewModel.conversationStore }

    @State private var hostText: String = ""
    @State private var portText: String = ""
    @State private var tokenText: String = ""
    @State private var usageRefreshingGeneration: Int? = nil
    @State private var lastUsageRefresh: Date? = nil

    private var isRefreshingUsage: Bool {
        if let generation = usageRefreshingGeneration {
            return store.pendingUsageGeneration == generation
        }
        return false
    }

    private var statusColor: Color {
        if store.isConnected {
            return store.isAgentOnline ? PiDesignSystem.Color.connected : PiDesignSystem.Color.pcOffline
        }
        switch store.connectionSnapshot.phase {
        case .connecting, .reconnecting:
            return PiDesignSystem.Color.pcOffline
        case .disconnected, .error:
            return PiDesignSystem.Color.disconnected
        case .connected:
            return PiDesignSystem.Color.connected
        }
    }

    private var statusHeadline: String {
        if store.isConnected {
            return store.isAgentOnline ? "已连接" : "已连接 · PC 离线"
        }
        return store.connectionSnapshot.summary
    }

    private var relayStatusText: String {
        switch store.connectionSnapshot.phase {
        case .connected: return "已连接"
        case .connecting: return "连接中"
        case .reconnecting(let seconds): return "\(seconds)s 后重试"
        case .disconnected: return "已断开"
        case .error: return "错误"
        }
    }

    private var agentStatusText: String {
        switch store.connectionSnapshot.agentReachability {
        case .unknown: return store.isAgentOnline ? "在线" : "未知"
        case .noAgents: return "无在线窗口"
        case .agentsAvailable(let count): return "\(count) 个在线窗口"
        case .currentTargetOffline: return "当前窗口离线"
        case .ambiguousTarget: return "需要手动选择"
        }
    }

    private var targetStatusText: String {
        if let currentId = store.currentAgentId,
           let agent = store.agents.first(where: { $0.agentId == currentId }) {
            return agent.displayName
        }
        return "未选择"
    }

    private var currentAgentSubtitle: String {
        if let currentId = store.currentAgentId,
           let agent = store.agents.first(where: { $0.agentId == currentId }) {
            return "当前目标：\(agent.displayName)"
        }
        return "当前未选择目标窗口"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                connectionSection
                statusSection
                modeSection
                usageSection
                voiceSection
                sessionSection
                notificationSection
                toolsSection
            }
            .padding(16)
            .padding(.bottom, 32)
        }
        .background(PiDesignSystem.Color.background)
        .navigationTitle("设置")
        .navigationBarTitleDisplayMode(.large)
        .preferredColorScheme(.dark)
        .onAppear {
            hostText = settings.host
            portText = String(settings.port)
            tokenText = settings.token
        }
        .onChange(of: store.latestAcceptedUsageGeneration) { generation in
            guard let generation, generation == usageRefreshingGeneration else { return }
            usageRefreshingGeneration = nil
            lastUsageRefresh = Date()
        }
        .onChange(of: store.currentSnapshotGeneration) { generation in
            if let refreshing = usageRefreshingGeneration, generation > refreshing,
               store.pendingUsageGeneration != refreshing {
                usageRefreshingGeneration = nil
            }
        }
        .onChange(of: store.isConnected) { connected in
            if !connected {
                usageRefreshingGeneration = nil
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("设备与运行时")
                .font(PiDesignSystem.Font.title)
                .foregroundStyle(PiDesignSystem.Color.primary)
            Text("管理连接、会话、运行状态和日志，保持和远程 Pi 工作区一致。")
                .font(PiDesignSystem.Font.body)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
    }

    private var connectionSection: some View {
        SettingsSectionCardView(title: "连接") {
            settingsField(icon: "network", title: "主机 / IP") {
                TextField("例如 192.168.1.2", text: $hostText)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(PiDesignSystem.Font.body)
                    .foregroundStyle(PiDesignSystem.Color.primary)
            }
            settingsField(icon: "point.3.connected.trianglepath.dotted", title: "端口") {
                TextField("3002", text: $portText)
                    .keyboardType(.numberPad)
                    .font(PiDesignSystem.Font.body)
                    .foregroundStyle(PiDesignSystem.Color.primary)
            }
            settingsField(icon: "key.horizontal", title: "Token") {
                HStack(spacing: 8) {
                    SecureField("中继与局域网均需", text: $tokenText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(PiDesignSystem.Font.body)
                        .foregroundStyle(PiDesignSystem.Color.primary)
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            tokenText = pasted
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundStyle(PiDesignSystem.Color.accent)
                            .frame(width: 36, height: 36)
                    }
                    .piIconButtonSurface(radius: 12)
                    .disabled(UIPasteboard.general.string?.isEmpty ?? true)
                }
            }
            VStack(alignment: .leading, spacing: 8) {
                primaryActionButton(title: "应用并重连", icon: "arrow.clockwise.circle.fill", action: apply)
                infoLabel(icon: "link", text: settings.wsURL)
                infoLabel(icon: "iphone", text: "设备 ID: \(settings.clientId)")
            }
        }
    }

    private var statusSection: some View {
        SettingsSectionCardView(title: "状态") {
            HStack(spacing: 10) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 10, height: 10)
                Text(statusHeadline)
                    .font(PiDesignSystem.Font.headline)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                Spacer()
            }

            HStack(spacing: 8) {
                statusTile(title: "Relay", value: relayStatusText, icon: "dot.radiowaves.left.and.right", color: statusColor)
                statusTile(title: "Agent", value: agentStatusText, icon: "desktopcomputer", color: store.isAgentOnline ? PiDesignSystem.Color.connected : PiDesignSystem.Color.pcOffline)
                statusTile(title: "Target", value: targetStatusText, icon: "macwindow", color: PiDesignSystem.Color.secondary)
            }

            VStack(alignment: .leading, spacing: 8) {
                if let detail = store.connectionSnapshot.detail, !detail.isEmpty {
                    infoLabel(icon: "link", text: detail)
                }
                if let error = store.connectionSnapshot.lastError, !error.isEmpty {
                    infoLabel(icon: "exclamationmark.triangle.fill", text: error, color: PiDesignSystem.Color.failed)
                }
                if let lastConnectedAt = store.connectionSnapshot.lastConnectedAt {
                    infoLabel(icon: "checkmark.circle", text: "上次连接 \(shortTime(lastConnectedAt))")
                }
                if let lastDisconnectedAt = store.connectionSnapshot.lastDisconnectedAt, !store.isConnected {
                    infoLabel(icon: "xmark.circle", text: "上次断开 \(shortTime(lastDisconnectedAt))")
                }
            }

            HStack(spacing: 10) {
                primaryActionButton(title: store.isConnected ? "断开" : "连接", icon: store.isConnected ? "pause.circle.fill" : "play.circle.fill") {
                    if store.isConnected { viewModel.disconnect() } else { viewModel.connect() }
                }
                secondaryActionButton(title: "按当前设置重连", icon: "arrow.triangle.2.circlepath") {
                    viewModel.reconnectWithCurrentSettings()
                }
            }
        }
    }

    private var modeSection: some View {
        SettingsSectionCardView(title: "连接模式") {
            if store.agents.isEmpty {
                modeHeroCard(icon: settings.token.isEmpty ? "network" : "server.rack",
                             title: settings.token.isEmpty ? "局域网直连" : "中继服务器连接",
                             subtitle: settings.token.isEmpty ? "直接连接到本地网络中的 Pi 服务" : "通过中继服务器转发到当前 PC")
                if !settings.token.isEmpty {
                    infoLabel(icon: "link", text: settings.wsURL)
                }
            } else {
                modeHeroCard(icon: "macwindow", title: "在线窗口：\(store.agents.count) 个", subtitle: currentAgentSubtitle)
                VStack(spacing: 8) {
                    ForEach(store.agents) { agent in
                        agentRow(agent)
                    }
                }
            }
        }
    }

    private var usageSection: some View {
        SettingsSectionCardView(title: "模型与用量") {
            if let usage = store.usageInfo {
                valueRow(icon: "cpu", title: "当前模型", value: store.currentModel ?? usage.model ?? "未加载")
                if usage.contextWindow > 0 {
                    valueRow(icon: "square.stack.3d.up", title: "上下文", value: usage.contextPercentText)
                    infoLabel(icon: "number", text: "\(usage.contextTokens ?? 0) / \(usage.contextWindow) tokens")
                } else {
                    valueRow(icon: "square.stack.3d.up", title: "上下文", value: "未提供")
                }
                valueRow(icon: "arrow.down.circle", title: "累计输入", value: "\(usage.totalInput)")
                valueRow(icon: "arrow.up.circle", title: "累计输出", value: "\(usage.totalOutput)")
                valueRow(icon: "tray.full", title: "缓存命中", value: "\(usage.totalCacheRead)")
                valueRow(icon: "square.and.arrow.down", title: "缓存写入", value: "\(usage.totalCacheWrite)")
                valueRow(icon: "brain", title: "思考 tokens", value: "\(usage.totalReasoning)")
                valueRow(icon: "sum", title: "累计 tokens", value: "\(usage.totalTokens)")
                valueRow(icon: "dollarsign.circle", title: "累计费用", value: usage.costText)
            } else if store.isConnected {
                infoLabel(icon: "hourglass", text: "正在同步用量数据…")
            } else {
                infoLabel(icon: "minus.circle", text: "暂无用量数据")
            }

            HStack {
                secondaryActionButton(title: isRefreshingUsage ? "正在刷新..." : "刷新用量", icon: isRefreshingUsage ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.clockwise") {
                    refreshUsage()
                }
                .disabled(!store.isConnected || isRefreshingUsage)
                Spacer()
                if let t = lastUsageRefresh {
                    Text(relativeTime(t))
                        .font(PiDesignSystem.Font.caption2)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
            }
        }
    }

    private var voiceSection: some View {
        SettingsSectionCardView(title: "语音输入") {
            HStack {
                Label("识别语言", systemImage: "waveform.badge.mic")
                    .foregroundStyle(PiDesignSystem.Color.primary)
                Spacer()
                Picker("识别语言", selection: $settings.voiceLanguage) {
                    ForEach(VoiceRecognitionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                .pickerStyle(.menu)
                .tint(PiDesignSystem.Color.accent)
            }
            infoLabel(icon: "info.circle", text: "“跟随系统”会根据 iPhone 首选语言使用中文或英文识别，也可在这里固定语言。")
        }
    }

    private var sessionSection: some View {
        SettingsSectionCardView(title: "会话") {
            if let s = store.sessionState {
                valueRow(icon: "bubble.left.and.bubble.right", title: "名称", value: s.displayName)
                valueRow(icon: "number.square", title: "会话 ID", value: s.sessionId ?? "—")
                valueRow(icon: "point.3.filled.connected.trianglepath.dotted", title: "分支 ID", value: s.leafId ?? "—")
                valueRow(icon: "text.bubble", title: "消息数", value: "\(s.entryCount)")
                if let reason = s.reason {
                    valueRow(icon: "play.square", title: "启动方式", value: reason)
                }
                if let file = s.sessionFile, !file.isEmpty {
                    infoLabel(icon: "doc.text", text: file)
                }
            } else {
                infoLabel(icon: "minus.circle", text: "暂无会话信息")
            }

            secondaryActionButton(title: "请求恢复会话", icon: "arrow.clockwise.circle") {
                viewModel.requestSessionResume()
            }
        }
    }

    private var notificationSection: some View {
        SettingsSectionCardView(title: "通知") {
            secondaryActionButton(title: "请求通知权限", icon: "bell.badge") {
                NotificationManager.shared.requestAuthorization()
            }
            secondaryActionButton(title: "测试通知", icon: "bell.and.waves.left.and.right") {
                NotificationManager.shared.sendTestNotification("Pi 回复完成提醒测试 ✅")
            }
            infoLabel(icon: "bell", text: "App 在后台时，Pi 完成回复会自动推送本地通知。")
        }
    }

    private var toolsSection: some View {
        SettingsSectionCardView(title: "工具") {
            NavigationLink {
                LogsView(viewModel: viewModel)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .foregroundStyle(PiDesignSystem.Color.accent)
                        .frame(width: 20)
                    Text("运行日志")
                        .foregroundStyle(PiDesignSystem.Color.primary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
                .frame(minHeight: 44)
            }
            .buttonStyle(.plain)
        }
    }

    private func settingsField<Content: View>(icon: String, title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
            content()
                .padding(.horizontal, 12)
                .padding(.vertical, 12)
                .piInputSurface()
        }
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
                .lineLimit(2)
        }
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func modeHeroCard(icon: String, title: String, subtitle: String) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(PiDesignSystem.Color.accent)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 4) {
                Text(title)
                    .font(PiDesignSystem.Font.headline)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                Text(subtitle)
                    .font(PiDesignSystem.Font.caption)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
        }
        .padding(14)
        .background(PiDesignSystem.Color.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private func agentRow(_ agent: RemoteAgentDescriptor) -> some View {
        HStack(spacing: 10) {
            Circle()
                .fill(agent.online ? PiDesignSystem.Color.connected : PiDesignSystem.Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(agent.displayName)
                        .font(PiDesignSystem.Font.body.weight(.medium))
                        .foregroundStyle(PiDesignSystem.Color.primary)
                        .lineLimit(1)
                    if agent.agentId == store.currentAgentId {
                        Text("当前")
                            .font(PiDesignSystem.Font.caption2)
                            .foregroundStyle(PiDesignSystem.Color.accent)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .piTintCapsule(PiDesignSystem.Color.accent, opacity: 0.12)
                    }
                }
                if let cwd = agent.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption2.monospaced())
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            if let model = agent.model, !model.isEmpty {
                Text(model)
                    .font(PiDesignSystem.Font.caption2)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .piInputSurface(radius: 12)
    }

    private func valueRow(icon: String, title: String, value: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .foregroundStyle(PiDesignSystem.Color.accent)
                .frame(width: 20)
            Text(title)
                .font(PiDesignSystem.Font.body)
                .foregroundStyle(PiDesignSystem.Color.primary)
            Spacer()
            Text(value)
                .font(PiDesignSystem.Font.body)
                .foregroundStyle(PiDesignSystem.Color.secondary)
                .multilineTextAlignment(.trailing)
        }
        .frame(minHeight: 28)
    }

    private func infoLabel(icon: String, text: String, color: Color = PiDesignSystem.Color.secondary) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: icon)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(color)
                .frame(width: 16, alignment: .center)
            Text(text)
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(color)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
    }

    private func primaryActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PiDesignSystem.Font.body.weight(.semibold))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .piPrimaryButton()
    }

    private func secondaryActionButton(title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .font(PiDesignSystem.Font.body.weight(.medium))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .piSecondaryButton()
    }

    private func shortTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.timeStyle = .short
        formatter.dateStyle = .none
        return formatter.string(from: date)
    }

    private func apply() {
        let port = Int(portText) ?? 3002
        let host = hostText.trimmingCharacters(in: .whitespacesAndNewlines)
        let token = tokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        tokenText = token
        viewModel.updateHostPort(host: host, port: port, token: token)
    }

    private func refreshUsage() {
        usageRefreshingGeneration = viewModel.refreshSnapshot(reason: "manual-refresh")
    }

    private func relativeTime(_ date: Date) -> String {
        let sec = max(0, Int(Date().timeIntervalSince(date)))
        if sec < 5 { return "刚刚" }
        if sec < 60 { return "\(sec)秒前" }
        let m = sec / 60
        if m < 60 { return "\(m)分钟前" }
        let h = m / 60
        return "\(h)小时前"
    }
}
