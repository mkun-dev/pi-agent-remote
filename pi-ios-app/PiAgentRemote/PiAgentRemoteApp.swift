import SwiftUI

@main
struct PiAgentRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var crashMessage: String? = nil
    
    var body: some Scene {
        WindowGroup {
            if let crash = crashMessage {
                // 诊断模式：把崩溃信息直接画在屏幕上，下次打开就能看到
                CrashDiagnosticView(message: crash)
            } else {
                ContentView()
                    .preferredColorScheme(.dark)
                    .onAppear {
                        // 启动时先读上一次崩溃记录
                        crashMessage = CrashReporter.shared.lastCrash
                    }
            }
        }
    }
}

/// 全屏崩溃诊断视图：把上次崩溃的标题/详情/堆栈直接显示出来。
/// 这样即使一打开就闪退，下一次启动也能看到“为什么崩”。
struct CrashDiagnosticView: View {
    let message: String
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("🚨 上次崩溃记录")
                        .font(.title2.bold())
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("清除并重试") {
                        CrashReporter.shared.clear()
                        // 触发重新渲染，进入正常 App
                        NotificationCenter.default.post(name: NSNotification.Name("CrashCleared"), object: nil)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.blue)
                }
                .padding()
            }
            .background(Color.black)
            .preferredColorScheme(.dark)
            .navigationTitle("崩溃诊断")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

// Phase 3: 启动时请求通知权限（比 onAppear 更早触发）
class AppDelegate: NSObject, UIApplicationDelegate {
    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        // 尽早安装崩溃采集，捕获启动期崩溃原因（无 Xcode 时也能在下一次打开看到）
        CrashReporter.shared.install()
        NotificationManager.shared.requestAuthorization()
        // 后台保活：App 启动时就开始静音音频（连接后保持 WebSocket 不被挂起）
        BackgroundAudioService.shared.startKeepAlive()
        return true
    }
}
