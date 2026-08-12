import XCTest
@testable import PiAgentRemote

/// ConversationMessageFilter 白名单契约测试（第七阶段：安全过滤层）。
/// 验证：只有 User Conversation 事件允许进入消息列表；
/// System Event / Debug Log 一律禁止生成 Message。
final class ConversationMessageFilterTests: XCTestCase {

    // MARK: - 允许进入消息列表（User Conversation）

    func testUserMessageAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .agent(.input(text: "你好"))
        ))
    }

    func testAgentFunctionalFeedbackAllowed() {
        // agent.output 是用户操作的响应（/model 切换确认、排队提示、问卷确认），
        // 不是调试日志，允许显示。
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .agent(.output(text: "✅ 已切换到模型: claude", isThinking: false))
        ))
    }

    func testThinkingOutputAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .agent(.output(text: "thinking…", isThinking: true))
        ))
    }

    func testAssistantStreamingAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .assistant(.start(messageId: "a1"))
        ))
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .assistant(.delta(messageId: "a1", text: "hello", seq: 1))
        ))
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .assistant(.end(messageId: "a1", text: "hello"))
        ))
    }

    func testToolEventsAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .tool(.start(RemoteToolCall(id: "t1", name: "bash", input: "ls")))
        ))
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .tool(.output(data: "file1"))
        ))
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .tool(.end(toolCallId: "t1", success: true))
        ))
    }

    func testFileChangeAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .file(RemoteFileEvent(path: "src/a.ts", action: .modified, additions: 1, deletions: 0))
        ))
    }

    func testMediaImageAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .media(.image(fileName: "photo.png", base64: "AAAA"))
        ))
    }

    func testSessionHistoryAllowed() {
        XCTAssertTrue(ConversationMessageFilter.allowsMessageEntry(
            .session(.history(sessionId: "s1", entries: []))
        ))
    }

    // MARK: - 禁止进入消息列表（System Event / Debug Log）

    func testWorkspaceEventsRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .workspace(.tree(RemoteWorkspaceTree(path: "", name: "root", children: [])))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .workspace(.file(RemoteWorkspaceFile(path: "a.ts", type: .text, content: "x", size: 1)))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .workspace(.error(RemoteWorkspaceError(path: nil, message: "denied")))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .workspace(.searchResult(RemoteWorkspaceSearchResult(query: "q", hits: [])))
        ))
    }

    func testModelEventsRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .model(.list(["claude", "gpt"]))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .model(.selectionAcknowledged(modelId: "claude", success: true, message: nil))
        ))
    }

    func testUsageEventsRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .usage(RemoteUsageEvent(
                model: "claude", contextTokens: nil, contextWindow: 0, contextPercent: nil,
                totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
                totalReasoning: 0, totalTokens: 0, totalCost: 0
            ))
        ))
    }

    func testAgentStatusRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .agent(.status(RemoteAgentStatus(value: "running", tool: nil, description: nil)))
        ))
    }

    func testRelayEventsRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .relay(.agents([]))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .relay(.status("connected"))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .relay(.agentJoined(RemoteAgentDescriptor(agentId: "win-a", name: nil, cwd: nil, model: nil, online: true)))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .relay(.agentLeft(agentId: "win-a"))
        ))
    }

    func testSessionMetadataRejected() {
        let info = RemoteSessionInfo(sessionId: "s1", sessionFile: nil, name: nil, leafId: nil, entryCount: 0, reason: nil)
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(.session(.info(info))))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(.session(.update(info))))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(.session(.list([]))))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .session(.switchAcknowledged(sessionFile: "b.jsonl", success: true))
        ))
    }

    func testQuestionnaireRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .questionnaire(.show(id: "q1", questions: []))
        ))
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(
            .questionnaire(.answered(source: "pc", answers: []))
        ))
    }

    func testUnknownRejected() {
        XCTAssertFalse(ConversationMessageFilter.allowsMessageEntry(.unknown(type: "future.event")))
    }

    // MARK: - 分类（EntryKind）

    func testEntryKindClassification() {
        XCTAssertEqual(ConversationMessageFilter.kind(of: .assistant(.start(messageId: "a"))), .conversation)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .workspace(.tree(RemoteWorkspaceTree(path: "", name: "r", children: [])))), .debugLog)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .model(.list([]))), .debugLog)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .usage(RemoteUsageEvent(
            model: nil, contextTokens: nil, contextWindow: 0, contextPercent: nil,
            totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 0, totalCost: 0
        ))), .debugLog)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .agent(.status(RemoteAgentStatus(value: "idle", tool: nil, description: nil)))), .systemEvent)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .session(.info(RemoteSessionInfo(
            sessionId: "s", sessionFile: nil, name: nil, leafId: nil, entryCount: 0, reason: nil
        )))), .systemEvent)
        XCTAssertEqual(ConversationMessageFilter.kind(of: .relay(.agents([]))), .debugLog)
    }
}
