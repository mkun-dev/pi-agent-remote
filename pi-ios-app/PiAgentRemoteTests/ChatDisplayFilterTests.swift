import XCTest
@testable import PiAgentRemote

/// 聊天流展示过滤规则测试（纯展示层，不修改 Store / Trace / Tool 数据）。
final class ChatDisplayFilterTests: XCTestCase {

    // MARK: - 基础规则

    func testUserMessageDisplayed() {
        let msg = Message(id: "u1", sender: .user, content: "hello", timestamp: Date(), kind: .text)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testAssistantFinalReplyDisplayed() {
        let msg = Message(id: "a1", sender: .pi, content: "修改完成。", timestamp: Date(), kind: .text)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testStreamingAssistantDisplayed() {
        let msg = Message(id: "a2", sender: .pi, content: "正在生成", timestamp: Date(), kind: .text, isStreaming: true)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    // MARK: - Tool 隐藏（核心规则）

    func testToolMessageHidden() {
        let msg = Message(
            id: "t1", sender: .pi, content: "▶ bash: npm test",
            timestamp: Date(), kind: .tool,
            toolEntries: [ToolEntry(toolCallId: "call1", toolName: "bash", detail: "npm test", status: .running)]
        )
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testToolMessageHiddenEvenWhenRunning() {
        // 即使工作中（实时进度阶段）也不再显示——由状态栏/Timeline 承担反馈
        let msg = Message(
            id: "t2", sender: .pi, content: "▶ bash: npm test",
            timestamp: Date(), kind: .tool,
            toolEntries: [ToolEntry(toolCallId: "call1", toolName: "bash", detail: "npm test", status: .running)],
            toolGroupState: .working
        )
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testHistoryToolMessageHidden() {
        // 旧会话回放的 tool 消息同样不显示
        let msg = Message(
            id: "ht1", sender: .pi, content: "ls -la", timestamp: Date(),
            kind: .tool, isHistory: true,
            toolEntries: [ToolEntry(toolCallId: "h1", toolName: "bash", detail: "ls -la", status: .done)],
            toolGroupState: .collapsed
        )
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    // MARK: - 保留类型

    func testFileChangesDisplayed() {
        let change = FileChange(path: "README.md", type: .modified, additions: 1, deletions: 1)
        let msg = Message(
            id: "f1", sender: .system, content: "修改了 1 个文件",
            timestamp: Date(), kind: .fileChanges, fileChanges: [change]
        )
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testImageMessageDisplayed() {
        let msg = Message(id: "img1", sender: .pi, content: "photo.png", timestamp: Date(), kind: .image)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testStatusMessageDisplayed() {
        let msg = Message(id: "s1", sender: .system, content: "连接中", timestamp: Date(), kind: .status)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(msg))
    }

    // MARK: - 既有隐藏规则保持

    func testTerminalAndThinkingHidden() {
        let terminal = Message(id: "term1", sender: .pi, content: "src/", timestamp: Date(), kind: .terminal)
        let thinking = Message(id: "th1", sender: .pi, content: "思考...", timestamp: Date(), kind: .thinking)
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(terminal))
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(thinking))
    }

    func testIntermediateAssistantHidden() {
        let msg = Message(
            id: "ia1", sender: .pi, content: "我要调用工具...", timestamp: Date(),
            kind: .text, isIntermediateAssistant: true
        )
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testMediaStatusMessageHidden() {
        let msg = Message(
            id: "ms1", sender: .system, content: "图片已保存", timestamp: Date(),
            kind: .status, isMediaStatusMessage: true
        )
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    func testEmptyPiPlaceholderHidden() {
        let msg = Message(id: "e1", sender: .pi, content: "", timestamp: Date(), kind: .text)
        XCTAssertFalse(ChatDisplayFilter.shouldDisplay(msg))
    }

    // MARK: - 组合场景（模拟真实消息流）

    func testFullConversationFiltering() {
        let user = Message(id: "u1", sender: .user, content: "帮我修改代码", timestamp: Date(), kind: .text)
        let intermediate = Message(id: "a0", sender: .pi, content: "我要调用工具...", timestamp: Date(), kind: .text, isIntermediateAssistant: true)
        let tool = Message(
            id: "t1", sender: .pi, content: "▶ bash: npm test", timestamp: Date(), kind: .tool,
            toolEntries: [ToolEntry(toolCallId: "c1", toolName: "bash", detail: "npm test", status: .done)]
        )
        let fileChanges = Message(
            id: "f1", sender: .system, content: "修改了 1 个文件", timestamp: Date(), kind: .fileChanges,
            fileChanges: [FileChange(path: "a.ts", type: .modified, additions: 2, deletions: 1)]
        )
        let finalReply = Message(id: "a1", sender: .pi, content: "修改完成。", timestamp: Date(), kind: .text)

        let visible = ChatDisplayFilter.filter([user, intermediate, tool, fileChanges, finalReply])

        XCTAssertEqual(visible.map(\.id), ["u1", "f1", "a1"])
        XCTAssertFalse(visible.contains { $0.kind == .tool })
    }

    func testStreamingMessageAlwaysVisible() {
        // Streaming 阶段：空内容 + isStreaming → 必须显示（光标/自动滚动依赖）
        let streaming = Message(id: "s1", sender: .pi, content: "", timestamp: Date(), kind: .text, isStreaming: true)
        XCTAssertTrue(ChatDisplayFilter.shouldDisplay(streaming))
    }
}
