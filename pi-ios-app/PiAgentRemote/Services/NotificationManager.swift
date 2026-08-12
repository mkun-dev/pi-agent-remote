import Foundation
import UserNotifications
import UIKit

/// Phase 3: Push 通知（本地通知方案）
/// 当 Pi Agent 回复完成且 App 不在前台时，发送本地通知提醒用户
class NotificationManager: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationManager()
    
    private override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }
    
    /// 请求通知权限（在 App 启动时调用）
    func requestAuthorization() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, error in
            if let error = error {
                print("🔔 通知权限请求失败:", error.localizedDescription)
            } else {
                print("🔔 通知权限: \(granted ? "已授权" : "未授权")")
            }
        }
    }
    
    /// Agent 回复完成时通知（仅当 App 不在前台时发送）
    func notifyAgentReply(_ text: String) {
        // 只有 App 在后台/非活跃时才发通知，避免前台打扰
        guard UIApplication.shared.applicationState != .active else { return }
        
        let content = UNMutableNotificationContent()
        content.title = "🤖 Pi 有回复了"
        content.body = truncated(text, maxLength: 120)
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil  // 立即触发
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("🔔 通知发送失败:", error.localizedDescription)
            }
        }
    }
    
    /// 收到 Agent 提问时通知（前台也提示横幅，避免错过提问）
    func notifyQuestionnaire(_ firstQuestion: String) {
        let content = UNMutableNotificationContent()
        content.title = "❓ Pi 正在提问"
        content.body = truncated(firstQuestion, maxLength: 120)
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("🔔 问卷通知失败:", error.localizedDescription)
            }
        }
    }
    
    /// 测试用：强制发送通知（不管 App 是否在前台）
    func sendTestNotification(_ text: String = "这是一条测试通知") {
        let content = UNMutableNotificationContent()
        content.title = "🔔 测试通知"
        content.body = text
        content.sound = .default
        
        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )
        UNUserNotificationCenter.current().add(request) { error in
            if let error = error {
                print("🔔 测试通知发送失败:", error.localizedDescription)
            } else {
                print("🔔 测试通知已发送")
            }
        }
    }
    
    /// 在通知中心保留最近 N 条通知（避免堆积）
    func setBadgeCount(_ count: Int) {
        UNUserNotificationCenter.current().setBadgeCount(count) { _ in }
    }
    
    private func truncated(_ s: String, maxLength: Int) -> String {
        guard s.count > maxLength else { return s }
        return String(s.prefix(maxLength)) + "…"
    }
    
    // MARK: - UNUserNotificationCenterDelegate
    
    /// 前台也显示通知横幅（可选：如果想在前台也提醒，可开启）
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .sound])
    }
    
    /// 点击通知时打开 App
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        completionHandler()
    }
}
