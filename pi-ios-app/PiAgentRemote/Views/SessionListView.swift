import SwiftUI

/// Phase 4: 历史会话列表（来自 PC 端 SessionManager.list）
/// 选择后会话 → 让当前目标窗口 switchSession 过去，再自动拉取该会话历史
struct SessionListView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                PiDesignSystem.Color.background.ignoresSafeArea()
                Group {
                    if store.sessionList.isEmpty {
                        VStack(spacing: 12) {
                            if viewModel.isLoadingSessions {
                                ProgressView("正在加载会话...")
                                    .tint(PiDesignSystem.Color.accent)
                            } else {
                                Image(systemName: "clock.arrow.circlepath")
                                    .font(.system(size: 40))
                                    .foregroundStyle(PiDesignSystem.Color.secondary)
                                Text("没有找到历史会话")
                                    .font(PiDesignSystem.Font.headline)
                                    .foregroundStyle(PiDesignSystem.Color.primary)
                                Text("在 PC 端开始一个对话后，这里会出现记录")
                                    .font(PiDesignSystem.Font.caption)
                                    .foregroundStyle(PiDesignSystem.Color.secondary)
                            }
                        }
                    } else {
                        ScrollView {
                            LazyVStack(spacing: 12) {
                                ForEach(store.sessionList, id: \.path) { item in
                                    sessionRow(item)
                                }
                            }
                            .padding(16)
                        }
                        .refreshable { viewModel.requestSessionList() }
                    }
                }
            }
            .navigationTitle("历史会话")
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
            .onAppear { viewModel.requestSessionList() }
            .alert("切换会话", isPresented: $showSwitchHint) {
                Button("好", role: .cancel) { dismiss() }
            } message: {
                Text("已请求 PC 端切换到该会话，正在加载对话历史...")
            }
        }
    }
    
    @State private var showSwitchHint = false
    
    private func sessionRow(_ item: RemoteSessionListItem) -> some View {
        Button {
            viewModel.switchToSession(item)
            showSwitchHint = true
        } label: {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top, spacing: 10) {
                    Circle()
                        .fill(item.id == store.sessionState?.sessionId ? PiDesignSystem.Color.completed : PiDesignSystem.Color.secondary.opacity(0.5))
                        .frame(width: 8, height: 8)
                        .padding(.top, 5)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item.displayTitle)
                            .font(PiDesignSystem.Font.headline)
                            .lineLimit(1)
                            .foregroundStyle(PiDesignSystem.Color.primary)
                        if let cwd = item.cwd, !cwd.isEmpty {
                            Text(cwd)
                                .font(PiDesignSystem.Font.caption)
                                .foregroundStyle(PiDesignSystem.Color.secondary)
                                .lineLimit(1)
                        }
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 6) {
                        if item.id == store.sessionState?.sessionId {
                            Text("当前")
                                .font(PiDesignSystem.Font.caption2)
                                .foregroundStyle(PiDesignSystem.Color.accent)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .piTintCapsule(PiDesignSystem.Color.accent, opacity: 0.14)
                        }
                        Text(timeString(item.modified))
                            .font(PiDesignSystem.Font.caption2)
                            .foregroundStyle(PiDesignSystem.Color.secondary)
                    }
                }
                
                if let fm = item.firstMessage, !fm.isEmpty, item.name == nil || item.name?.isEmpty == true {
                    Text(fm)
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .piCard(color: PiDesignSystem.Color.surface, radius: 18)
        }
        .buttonStyle(.plain)
    }
    
    private func timeString(_ date: Date?) -> String {
        guard let date = date else { return "" }
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: date)
    }
}
