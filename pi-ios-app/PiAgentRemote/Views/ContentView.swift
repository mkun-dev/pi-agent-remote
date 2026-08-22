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
            NavigationStack {
                ChatView(viewModel: viewModel)
            }
            .tabItem { Label("聊天", systemImage: "message.fill") }
            .tag(0)
            
            NavigationStack {
                WorkspaceExplorerView(viewModel: viewModel)
            }
            .tabItem { Label("文件", systemImage: "folder") }
            .tag(1)
            
            NavigationStack {
                ActivityView(viewModel: viewModel)
            }
            .tabItem { Label("活动", systemImage: "clock.arrow.circlepath") }
            .tag(2)
            
            NavigationStack {
                SettingsView()
                    .environmentObject(settings)
                    .environmentObject(viewModel)
            }
            .tabItem { Label("设置", systemImage: "gear") }
            .tag(3)
        }
        .environmentObject(settings)
        .environmentObject(viewModel)
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