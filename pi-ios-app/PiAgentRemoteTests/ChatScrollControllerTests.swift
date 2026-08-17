import XCTest
@testable import PiAgentRemote

final class ChatScrollControllerTests: XCTestCase {
    @MainActor
    func testInitialMessagesIssueSingleNonAnimatedScroll() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(3)
        controller.handleMessageIDsChanged(hasMessages: true, animated: true)
        
        XCTAssertEqual(controller.followMode, .following)
        XCTAssertEqual(controller.pendingScrollRequest?.reason, .initialMessages)
        XCTAssertEqual(controller.pendingScrollRequest?.animated, false)
        XCTAssertEqual(controller.pendingScrollRequest?.sessionRevision, 3)
    }
    
    @MainActor
    func testStreamingRevisionFollowsOnlyWhenActivelyFollowing() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(1)
        controller.handleStreamingRevisionChange(hasActiveStreamingMessage: true, revision: 1, messageID: "remote-assistant:m1")
        XCTAssertEqual(controller.pendingScrollRequest?.reason, .streaming)
        
        controller.userStartedReadingHistory()
        controller.handleStreamingRevisionChange(hasActiveStreamingMessage: true, revision: 2, messageID: "remote-assistant:m1")
        XCTAssertNil(controller.pendingScrollRequest)
    }
    
    @MainActor
    func testReturnToBottomFlowHidesButtonAndRestoresFollowingAtBottom() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(2)
        controller.userStartedReadingHistory()
        XCTAssertTrue(controller.shouldShowJumpButton)
        
        controller.requestReturnToBottom(animated: true)
        XCTAssertEqual(controller.followMode, .returningToBottom)
        XCTAssertFalse(controller.shouldShowJumpButton)
        XCTAssertEqual(controller.pendingScrollRequest?.reason, .jumpButton)
        
        controller.handleBottomAnchor(bottomY: 10, viewportHeight: 100)
        XCTAssertEqual(controller.followMode, .following)
    }
    
    @MainActor
    func testSessionRevisionInvalidatesOlderRequestToken() throws {
        let controller = ChatScrollController()
        controller.beginSessionRevision(5)
        controller.handleMessageIDsChanged(hasMessages: true, animated: false)
        let old = try XCTUnwrap(controller.pendingScrollRequest)
        
        controller.beginSessionRevision(6)
        XCTAssertFalse(controller.consumeIfValid(old))
        XCTAssertNil(controller.pendingScrollRequest)
    }
    
    @MainActor
    func testContentHeightChangeCompensatesOnlyWhileAutoFollowing() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(8)
        controller.handleContentHeightChange(320)
        XCTAssertEqual(controller.pendingScrollRequest?.reason, .contentHeightChanged)
        
        controller.userStartedReadingHistory()
        controller.handleContentHeightChange(420)
        XCTAssertNil(controller.pendingScrollRequest)
    }
    
    @MainActor
    func testUserMessageSentRestoresFollowingMode() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(9)
        controller.userStartedReadingHistory()
        controller.noteUserMessageSent()
        XCTAssertEqual(controller.followMode, .following)
    }

    // MARK: - P2 长对话窗口裁剪

    @MainActor
    func testWindowedMessagesTrimsToWindowSizeAndReportsHiddenCount() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(1)
        let all = (0..<80).map { Message(id: "m\($0)", sender: .user, content: "hi", timestamp: Date(), kind: .text) }
        let result = controller.windowedMessages(all)
        XCTAssertEqual(result.visible.count, 50)          // 裁到默认 50
        XCTAssertEqual(result.visible.first?.id, "m30")   // 保留最后 50 条（m30..m79）
        XCTAssertEqual(result.visible.last?.id, "m79")
        XCTAssertEqual(result.hiddenCount, 30)
    }

    @MainActor
    func testWindowedMessagesReturnsAllWhenUnderLimit() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(1)
        let all = (0..<10).map { Message(id: "m\($0)", sender: .user, content: "hi", timestamp: Date(), kind: .text) }
        let result = controller.windowedMessages(all)
        XCTAssertEqual(result.visible.count, 10)
        XCTAssertEqual(result.hiddenCount, 0)             // 不足阈值不裁剪、不显示提示条
    }

    @MainActor
    func testRevealAllShowsEverythingWithinSameSession() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(1)
        let all = (0..<60).map { Message(id: "m\($0)", sender: .user, content: "hi", timestamp: Date(), kind: .text) }
        XCTAssertEqual(controller.windowedMessages(all).visible.count, 50)

        controller.revealAll()
        XCTAssertTrue(controller.revealedAll)
        let result = controller.windowedMessages(all)
        XCTAssertEqual(result.visible.count, 60)         // 展开后显示全部
        XCTAssertEqual(result.hiddenCount, 0)
    }

    @MainActor
    func testSessionRevisionResetsWindow() {
        let controller = ChatScrollController()
        controller.beginSessionRevision(1)
        controller.revealAll()
        XCTAssertTrue(controller.revealedAll)

        controller.beginSessionRevision(2)              // 切会话重置
        XCTAssertFalse(controller.revealedAll)
        XCTAssertEqual(controller.windowSize, ChatScrollController.defaultWindowSize)
        let all = (0..<60).map { Message(id: "m\($0)", sender: .user, content: "hi", timestamp: Date(), kind: .text) }
        XCTAssertEqual(controller.windowedMessages(all).visible.count, 50)
    }
}
