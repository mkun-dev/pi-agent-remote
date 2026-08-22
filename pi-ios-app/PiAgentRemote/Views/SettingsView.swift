import SwiftUI
import UIKit

struct SettingsView: View {
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var viewModel: ChatViewModel
    
    private var store: ConversationStore { viewModel.conversationStore }
    
    @State private var hostText: String = ""
    @State private var portText: String = ""
    @State private var tokenText: String = ""

    // Usage refresh UX
    @State private var usageRefreshingGeneration: Int? = nil
    @State private var lastUsageRefresh: Date? = nil
    
    private var isRefreshingUsage: Bool {
        if let generation = usageRefreshingGeneration {
            return store.pendingUsageGeneration == generation
        }
        return false
    }
    
    var body: some View {
        Form {
            Section(header: Text("连接")) {
                TextField("主机 / IP", text: $hostText)
                    .autocapitalization(.none)
                    .disableAutocorrection(true)
                    .textInputAutocapitalization(.never)
                
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                
                // Phase 3 NAT 穿透: 中继鉴权 token
                HStack {
                    SecureField("Token（中继与局域网均需）", text: $tokenText)
                        .autocapitalization(.none)
                        .disableAutocorrection(true)
                        .textInputAutocapitalization(.never)
                    // 一键粘贴剪贴板内容（长按粘贴在部分输入场景不可靠）
                    Button {
                        if let pasted = UIPasteboard.general.string {
                            tokenText = pasted
                        }
                    } label: {
                        Image(systemName: "doc.on.clipboard")
                            .foregroundColor(.blue)
                            .frame(minWidth: 36, minHeight: 36)  // 扩大触达
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("粘贴 Token")
                    .disabled(UIPasteboard.general.string?.isEmpty ?? true)
                }
                
                Button("应用并重连") {
                    apply()
                }
                .buttonStyle(.borderedProminent)
                
                Text("当前: \(settings.wsURL)")
                    .font(.caption.monospaced())
                    .foregroundColor(.secondary)
                Text("设备 ID: \(settings.clientId)")
                    .font(.caption2.monospaced())
                    .foregroundColor(.secondary)
                    .textSelection(.enabled)
                    .contextMenu {
                        Button("复制设备 ID") {
                            UIPasteboard.general.string = settings.clientId
                        }
                    }
            }
            
            Section(header: Text("状态")) {
                HStack {
                    Circle()
                        .fill(store.isConnected ? Color.green : Color.red)
                        .frame(width: 10, height: 10)
                    Text(store.isConnected ? (store.isAgentOnline ? "已连接" : "已连接 · PC 离线") : store.connectionStatus)
                        .font(.headline)
                }
                
                Button(store.isConnected ? "断开" : "连接") {
                    if store.isConnected {
                        viewModel.disconnect()
                    } else {
                        viewModel.connect()
                    }
                }
                
                Button("按当前设置重连") {
                    viewModel.reconnectWithCurrentSettings()
                }
            }
            
            Section(header: Text("连接模式")) {
                if store.agents.isEmpty {
                    // 中继模式（配了 token）或局域网模式
                    HStack {
                        Image(systemName: settings.token.isEmpty ? "network" : "server.rack")
                            .foregroundColor(settings.token.isEmpty ? .secondary : .blue)
                        Text(settings.token.isEmpty ? "局域网直连" : "中继服务器连接")
                            .font(.headline)
                            .foregroundColor(settings.token.isEmpty ? .secondary : .primary)
                    }
                    if !settings.token.isEmpty {
                        Text("通过中继服务器 \(settings.wsURL) 连接 PC")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                } else {
                    HStack {
                        Image(systemName: "macwindow")
                            .foregroundColor(.blue)
                        Text("在线窗口: \(store.agents.count) 个")
                            .font(.headline)
                    }
                    if let currentId = store.currentAgentId,
                       let agent = store.agents.first(where: { $0.agentId == currentId }) {
                        LabeledContent("当前目标", value: agent.displayName)
                        if let cwd = agent.cwd, !cwd.isEmpty {
                            Text(cwd)
                                .font(.caption.monospaced())
                                .foregroundColor(.secondary)
                                .textSelection(.enabled)
                        }
                    }
                    // 在线窗口列表
                    ForEach(store.agents) { agent in
                        HStack {
                            Circle()
                                .fill(agent.online ? Color.green : Color.gray)
                                .frame(width: 8, height: 8)
                            Text(agent.displayName)
                                .font(.callout)
                                .lineLimit(1)
                            if agent.agentId == store.currentAgentId {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.blue)
                                    .font(.caption)
                            }
                            Spacer()
                            if let cwd = agent.cwd, !cwd.isEmpty {
                                Text((cwd as NSString).lastPathComponent)
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                }
            }
            
            Section(header: Text("模型与用量")) {
                let currentUsage = store.usageInfo
                let currentModelDisplay = store.currentModel ?? currentUsage?.model

                if let usage = currentUsage {
                    if let model = currentModelDisplay {
                        LabeledContent("当前模型", value: model)
                    } else {
                        LabeledContent("当前模型", value: "未加载")
                    }
                    if usage.contextWindow > 0 {
                        LabeledContent("上下文", value: usage.contextPercentText)
                        Text("\(usage.contextTokens ?? 0) / \(usage.contextWindow) tokens")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    } else {
                        LabeledContent("上下文", value: "未提供")
                    }
                    LabeledContent("累计输入", value: "\(usage.totalInput)")
                    LabeledContent("累计输出", value: "\(usage.totalOutput)")
                    LabeledContent("缓存命中", value: "\(usage.totalCacheRead)")
                    LabeledContent("缓存写入", value: "\(usage.totalCacheWrite)")
                    LabeledContent("思考 tokens", value: "\(usage.totalReasoning)")
                    LabeledContent("累计 tokens", value: "\(usage.totalTokens)")
                    LabeledContent("累计费用", value: usage.costText)
                } else if store.isConnected {
                    if store.currentModel == nil && currentUsage?.model == nil {
                        Text("尚未连接到 Agent 或未开始对话")
                            .foregroundColor(.secondary)
                    } else {
                        Text("正在同步用量数据…")
                            .foregroundColor(.secondary)
                    }
                } else {
                    Text("暂无用量数据")
                        .foregroundColor(.secondary)
                }

                HStack {
                    Button {
                        refreshUsage()
                    } label: {
                        if isRefreshingUsage {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text("正在刷新...")
                            }
                        } else {
                            Text("刷新用量")
                        }
                    }
                    .disabled(!store.isConnected || isRefreshingUsage)

                    if let t = lastUsageRefresh {
                        Spacer()
                        Text(relativeTime(t))
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            // MARK: - 诊断面板（定位用量/模型不显示；问题解决后可删除）
            Section(header: Text("诊断（用量/模型）")) {
                LabeledContent("连接", value: "\(store.isConnected) | \(store.connectionStatus)")
                LabeledContent("当前 Agent", value: store.currentAgentId ?? "nil")
                LabeledContent("快照代次", value: "\(store.currentSnapshotGeneration)")
                LabeledContent("已接受事件", value: "\(store.diagAcceptCount)")
                if let raw = store.diagLastRawUsage {
                    Text("收到的 usage：\(raw)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                } else {
                    Text("未收到任何 usage 事件")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if let raw = store.diagLastRawModel {
                    Text("收到的 model：\(raw)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.secondary)
                } else {
                    Text("未收到任何 model 事件")
                        .font(.caption2)
                        .foregroundColor(.orange)
                }
                if let drop = store.diagLastDrop {
                    Text("scope 丢弃：\(drop)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.red)
                }
                if let drop = store.diagLastGenDrop {
                    Text("generation 丢弃：\(drop)")
                        .font(.caption2.monospaced())
                        .foregroundColor(.red)
                }
            }
            
            Section(header: Text("语音输入")) {
                Picker("识别语言", selection: $settings.voiceLanguage) {
                    ForEach(VoiceRecognitionLanguage.allCases) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("“跟随系统”会根据 iPhone 首选语言使用中文或英文识别，也可在这里固定语言。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("会话")) {
                if let s = store.sessionState {
                    LabeledContent("名称", value: s.displayName)
                    LabeledContent("会话 ID", value: s.sessionId ?? "—")
                    LabeledContent("分支 ID", value: s.leafId ?? "—")
                    LabeledContent("消息数", value: "\(s.entryCount)")
                    if let reason = s.reason {
                        LabeledContent("启动方式", value: reason)
                    }
                    if let file = s.sessionFile, !file.isEmpty {
                        Text(file)
                            .font(.caption.monospaced())
                            .foregroundColor(.secondary)
                            .textSelection(.enabled)
                    }
                } else {
                    Text("暂无会话信息")
                        .foregroundColor(.secondary)
                }
                
                Button("请求恢复会话") {
                    viewModel.requestSessionResume()
                }
            }
            
            Section(header: Text("通知")) {
                Button("请求通知权限") {
                    NotificationManager.shared.requestAuthorization()
                }
                
                Button("测试通知") {
                    // 测试按钮：强制发送（即使 App 在前台）
                    NotificationManager.shared.sendTestNotification("Pi 回复完成提醒测试 ✅")
                }
                
                Text("App 在后台时，Pi 完成回复会自动推送本地通知。")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Section(header: Text("工具")) {
                NavigationLink {
                    LogsView(viewModel: viewModel)
                } label: {
                    Label("运行日志", systemImage: "doc.text.magnifyingglass")
                }
            }
        }
        .navigationTitle("设置")
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
    
    private func apply() {
        let port = Int(portText) ?? 3001
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