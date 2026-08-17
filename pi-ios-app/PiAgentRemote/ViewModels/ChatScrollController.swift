import Foundation
import SwiftUI

@MainActor
final class ChatScrollController: ObservableObject {
    enum FollowMode: Equatable {
        case following
        case readingHistory
        case returningToBottom
    }
    
    enum TransitionReason: String {
        case sessionReset = "session_reset"
        case userDrag = "user_drag"
        case jumpButton = "jump_button"
        case bottomReached = "bottom_reached"
        case initialMessages = "initial_messages"
    }
    
    enum ScrollReason: String, Equatable {
        case initialMessages
        case newMessage
        case streaming
        case streamingCompleted
        case contentHeightChanged
        case jumpButton
    }
    
    struct ScrollRequest: Identifiable, Equatable {
        let token: UUID
        let reason: ScrollReason
        let animated: Bool
        let sessionRevision: UInt64
        
        var id: UUID { token }
    }
    
    @Published private(set) var followMode: FollowMode = .following
    @Published private(set) var pendingScrollRequest: ScrollRequest?

    /// 聊天窗口默认只展示最近的 N 条消息（P2 长对话窗口裁剪）。
    /// 用户点“展开”后 revealedAll=true，本会话内显示全部。
    /// 切会话时由 beginSessionRevision 重置。
    static let defaultWindowSize: Int = 50
    @Published private(set) var windowSize: Int = defaultWindowSize
    @Published private(set) var revealedAll: Bool = false

    /// 裁剪后的可见消息（调用方负责保证输入已过 ChatDisplayFilter）。
    func windowedMessages(_ allMessages: [Message]) -> (visible: [Message], hiddenCount: Int) {
        if revealedAll || allMessages.count <= windowSize {
            return (allMessages, 0)
        }
        return (Array(allMessages.suffix(windowSize)), allMessages.count - windowSize)
    }

    /// 用户点顶部提示条：本会话展开全部历史，不再裁剪。
    func revealAll() {
        guard !revealedAll else { return }
        revealedAll = true
    }

    private(set) var sessionRevision: UInt64 = 0
    private(set) var isAtBottom = true
    private(set) var contentHeight: CGFloat = 0
    private var hasInitialScrollForSession = false
    private let bottomThreshold: CGFloat = 24
    
    var shouldShowJumpButton: Bool {
        followMode == .readingHistory && !isAtBottom
    }
    
    var allowsAutoFollow: Bool {
        followMode == .following || followMode == .returningToBottom
    }
    
    func beginSessionRevision(_ revision: UInt64) {
        let oldRevision = sessionRevision
        let oldToken = pendingScrollRequest?.token.uuidString ?? "nil"
        if pendingScrollRequest != nil {
            RemoteLogger.scroll("[SCROLL] invalidate token=\(oldToken) reason=session_switch oldSession=\(oldRevision) newSession=\(revision)")
        }
        RemoteLogger.scroll("[SCROLL] session reset oldRevision=\(oldRevision) newRevision=\(revision)")
        sessionRevision = revision
        transition(to: .following, reason: .sessionReset)
        isAtBottom = true
        contentHeight = 0
        hasInitialScrollForSession = false
        pendingScrollRequest = nil
        windowSize = Self.defaultWindowSize
        revealedAll = false
    }
    
    func handleViewAppear(hasMessages: Bool) {
        guard hasMessages, !hasInitialScrollForSession else { return }
        hasInitialScrollForSession = true
        requestScroll(reason: .initialMessages, animated: false)
    }
    
    func handleMessageIDsChanged(hasMessages: Bool, animated: Bool) {
        guard hasMessages else { return }
        if !hasInitialScrollForSession {
            hasInitialScrollForSession = true
            transition(to: .following, reason: .initialMessages)
            requestScroll(reason: .initialMessages, animated: false)
            return
        }
        guard allowsAutoFollow else {
            RemoteLogger.scroll("[SCROLL] skip reason=new_message mode=\(followMode.rawValue) session=\(sessionRevision)")
            return
        }
        requestScroll(reason: .newMessage, animated: animated)
    }
    
    func handleStreamingRevisionChange(hasActiveStreamingMessage: Bool, revision: UInt64, messageID: String?) {
        RemoteLogger.scroll("[SCROLL] streaming id=\(messageID ?? "nil") revision=\(revision) mode=\(followMode.rawValue) session=\(sessionRevision)")
        guard hasActiveStreamingMessage, followMode == .following else {
            if !hasActiveStreamingMessage {
                RemoteLogger.scroll("[SCROLL] skip reason=streaming_inactive session=\(sessionRevision)")
            } else {
                RemoteLogger.scroll("[SCROLL] skip reason=streaming_follow_disabled mode=\(followMode.rawValue) session=\(sessionRevision)")
            }
            return
        }
        requestScroll(reason: .streaming, animated: false)
    }
    
    func handleStreamingEnded() {
        guard allowsAutoFollow else {
            RemoteLogger.scroll("[SCROLL] skip reason=streaming_completed_follow_disabled mode=\(followMode.rawValue) session=\(sessionRevision)")
            return
        }
        requestScroll(reason: .streamingCompleted, animated: false)
    }
    
    func handleContentHeightChange(_ newValue: CGFloat) {
        guard newValue > 0 else { return }
        let oldValue = contentHeight
        let delta = newValue - oldValue
        let changed = abs(delta) > 0.5
        contentHeight = newValue
        guard changed else { return }
        RemoteLogger.scroll("[SCROLL] contentHeight \(Int(oldValue)) -> \(Int(newValue)) delta=\(Int(delta)) mode=\(followMode.rawValue) session=\(sessionRevision)")
        let shouldRequest = allowsAutoFollow
        RemoteLogger.scroll("[SCROLL] height_follow request=\(shouldRequest) mode=\(followMode.rawValue) session=\(sessionRevision)")
        guard shouldRequest else { return }
        requestScroll(reason: .contentHeightChanged, animated: false)
    }
    
    func handleBottomAnchor(bottomY: CGFloat, viewportHeight: CGFloat) {
        let old = isAtBottom
        let atBottom = bottomY <= viewportHeight + bottomThreshold
        isAtBottom = atBottom
        if old != atBottom {
            RemoteLogger.scroll("[SCROLL] bottom \(old) -> \(atBottom) bottomY=\(Int(bottomY)) viewport=\(Int(viewportHeight)) session=\(sessionRevision)")
        }
        if atBottom {
            transition(to: .following, reason: .bottomReached)
        }
    }
    
    func userStartedReadingHistory() {
        guard followMode != .readingHistory else { return }
        RemoteLogger.scroll("[SCROLL] user left follow mode session=\(sessionRevision)")
        transition(to: .readingHistory, reason: .userDrag)
        isAtBottom = false
        if let request = pendingScrollRequest {
            RemoteLogger.scroll("[SCROLL] invalidate token=\(request.token.uuidString) reason=user_drag session=\(sessionRevision)")
        }
        pendingScrollRequest = nil
    }
    
    func requestReturnToBottom(animated: Bool) {
        RemoteLogger.scroll("[SCROLL] jump_to_bottom requested session=\(sessionRevision)")
        transition(to: .returningToBottom, reason: .jumpButton)
        requestScroll(reason: .jumpButton, animated: animated)
    }
    
    func consumeIfValid(_ request: ScrollRequest) -> Bool {
        guard let pending = pendingScrollRequest else {
            RemoteLogger.scroll("[SCROLL] drop token=\(request.token.uuidString) reason=stale_token session=\(sessionRevision)")
            return false
        }
        guard pending.token == request.token else {
            RemoteLogger.scroll("[SCROLL] drop token=\(request.token.uuidString) reason=stale_token current=\(pending.token.uuidString) session=\(sessionRevision)")
            return false
        }
        guard request.sessionRevision == sessionRevision else {
            RemoteLogger.scroll("[SCROLL] drop token=\(request.token.uuidString) reason=session_revision_mismatch request=\(request.sessionRevision) current=\(sessionRevision)")
            pendingScrollRequest = nil
            return false
        }
        guard allowsAutoFollow else {
            RemoteLogger.scroll("[SCROLL] drop token=\(request.token.uuidString) reason=follow_disabled mode=\(followMode.rawValue)")
            pendingScrollRequest = nil
            return false
        }
        RemoteLogger.scroll("[SCROLL] execute token=\(request.token.uuidString) reason=\(request.reason.rawValue) session=\(request.sessionRevision)")
        pendingScrollRequest = nil
        return true
    }
    
    func noteUserMessageSent() {
        if followMode != .following {
            RemoteLogger.scroll("[SCROLL] user_message_sent mode=\(followMode.rawValue) -> following session=\(sessionRevision)")
            transition(to: .following, reason: .initialMessages)
        } else {
            RemoteLogger.scroll("[SCROLL] user_message_sent mode=following session=\(sessionRevision)")
        }
    }
    
    private func requestScroll(reason: ScrollReason, animated: Bool) {
        let request = ScrollRequest(
            token: UUID(),
            reason: reason,
            animated: animated,
            sessionRevision: sessionRevision
        )
        pendingScrollRequest = request
        RemoteLogger.scroll("[SCROLL] request token=\(request.token.uuidString) reason=\(reason.rawValue) animated=\(animated) session=\(sessionRevision) mode=\(followMode.rawValue)")
    }
    
    private func transition(to newMode: FollowMode, reason: TransitionReason) {
        let oldMode = followMode
        guard oldMode != newMode else { return }
        followMode = newMode
        RemoteLogger.scroll("[SCROLL] mode \(oldMode.rawValue) -> \(newMode.rawValue) reason=\(reason.rawValue) sessionRevision=\(sessionRevision)")
    }
}

private extension ChatScrollController.FollowMode {
    var rawValue: String {
        switch self {
        case .following: return "following"
        case .readingHistory: return "readingHistory"
        case .returningToBottom: return "returningToBottom"
        }
    }
}
