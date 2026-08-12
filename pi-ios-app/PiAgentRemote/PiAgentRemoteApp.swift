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
        NotificationManager.shared.requestAuthorization()
        // 后台保活：App 启动时就开始静音音频（连接后保持 WebSocket 不被挂起）
        BackgroundAudioService.shared.startKeepAlive()
        return true
    }
}
