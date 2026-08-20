import SwiftUI

@main
struct PiAgentRemoteApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .preferredColorScheme(.dark)
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
