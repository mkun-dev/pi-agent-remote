import SwiftUI

struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = SettingsStore()
    @StateObject private var viewModel: ChatViewModel
    /// 直接引用唯一业务状态源（conversationStore 为 let，需通过 ObservedObject 生成 Binding）
    @ObservedObject private var store: ConversationStore
    
    init() {
        let s = SettingsStore()
        _settings = StateObject(wrappedValue: s)
        let vm = ChatViewModel(settings: s)
        _viewModel = StateObject(wrappedValue: vm)
        _store = ObservedObject(wrappedValue: vm.conversationStore)
    }
    
    var body: some View {
        TabView(selection: $viewModel.activeTab) {
            // 首页（Dashboard）：Agent 状态 + 最近进展 + 快速继续
            DashboardView(viewModel: viewModel)
            .tabItem { Label("首页", systemImage: "house") }
            .tag(0)
            
            NavigationView {
                ChatView(viewModel: viewModel)
            }
            .tabItem { Label("聊天", systemImage: "message.fill") }
            .tag(1)
            
            NavigationView {
                WorkspaceExplorerView(viewModel: viewModel)
            }
            .tabItem { Label("文件", systemImage: "folder") }
            .tag(2)
            
            NavigationView {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(viewModel)
            }
            .tabItem { Label("设置", systemImage: "gear") }
            .tag(3)
        }
        .environmentObject(settings)
        .environmentObject(viewModel)
        // 问卷弹窗提升到 TabView 层级：任何 Tab 下 Pi 提问都能直接弹出
        .sheet(isPresented: $store.showQuestionnaire) {
            QuestionnaireCard(
                questions: store.questionnaireQuestions,
                onSubmit: { answers in
                    viewModel.submitQuestionnaire(answers)
                },
                onDismiss: { store.showQuestionnaire = false }
            )
        }
        .onAppear {
            viewModel.connect()
        }
        .onChange(of: scenePhase) { newPhase in
            if newPhase == .active {
                viewModel.handleAppBecameActive()
            }
        }
    }
}