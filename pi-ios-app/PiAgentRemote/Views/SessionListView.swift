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
        NavigationView {
            Group {
                if store.sessionList.isEmpty {
                    VStack(spacing: 12) {
                        if viewModel.isLoadingSessions {
                            ProgressView("正在加载会话...")
                        } else {
                            Image(systemName: "clock.arrow.circlepath")
                                .font(.system(size: 40))
                                .foregroundColor(.secondary)
                            Text("没有找到历史会话")
                                .font(.headline)
                                .foregroundColor(.secondary)
                            Text("在 PC 端开始一个对话后，这里会出现记录")
                                .font(.caption)
                                .foregroundColor(Color.secondary)
                        }
                    }
                } else {
                    List {
                        ForEach(store.sessionList, id: \.path) { item in
                            sessionRow(item)
                        }
                    }
                    .listStyle(.insetGrouped)
                    .refreshable { viewModel.requestSessionList() }
                }
            }
            .navigationTitle("历史会话")
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
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .top) {
                    Text(item.displayTitle)
                        .font(.headline)
                        .lineLimit(1)
                        .foregroundColor(.primary)
                    Spacer()
                    if item.id == store.sessionState?.sessionId {
                        Image(systemName: "checkmark.circle.fill")
                            .foregroundColor(.blue)
                            .font(.caption)
                    }
                    Text(timeString(item.modified))
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                if let cwd = item.cwd, !cwd.isEmpty {
                    Text(cwd)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                
                if let fm = item.firstMessage, !fm.isEmpty, item.name == nil || item.name?.isEmpty == true {
                    Text(fm)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(.vertical, 2)
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
