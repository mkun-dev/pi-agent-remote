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
}
