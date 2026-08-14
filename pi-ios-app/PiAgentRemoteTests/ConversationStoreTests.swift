import XCTest
@testable import PiAgentRemote

final class ConversationStoreTests: XCTestCase {
    func testStreamingProducesOneCompletedAssistantMessage() {
        let store = ConversationStore()
        store.accept(event("1", .assistant(.start(messageId: "m1"))))
        store.accept(event("2", .assistant(.delta(messageId: "m1", text: "你好", seq: nil))))
        store.accept(event("3", .assistant(.delta(messageId: "m1", text: "世界", seq: nil))))
        store.accept(event("4", .assistant(.end(messageId: "m1", text: "你好世界"))))
        
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.content, "你好世界")
        XCTAssertEqual(store.messages.first?.isStreaming, false)
    }
    
    func testCompletedStatusClosesStreamingWhenAssistantEndIsMissing() {
        let store = ConversationStore()
        store.accept(event("start", .assistant(.start(messageId: "m1"))))
        store.accept(event("delta", .assistant(.delta(messageId: "m1", text: "最新回复", seq: nil))))
        store.accept(event("completed", .agent(.status(RemoteAgentStatus(value: "completed", tool: nil, description: nil)))))

        XCTAssertEqual(store.messages.first?.content, "最新回复")
        XCTAssertFalse(store.messages.first?.isStreaming ?? true)
        XCTAssertEqual(store.agentState, .completed)
    }

    func testAssistantEndReconcilesWithAuthoritativeFinalText() {
        let store = ConversationStore()
        store.accept(event("start", .assistant(.start(messageId: "m1"))))
        store.accept(event("delta", .assistant(.delta(messageId: "m1", text: "部分", seq: 1))))
        store.accept(event("end", .assistant(.end(messageId: "m1", text: "完整回复"))))

        XCTAssertEqual(store.messages.first?.content, "完整回复")
        XCTAssertFalse(store.messages.first?.isStreaming ?? true)
    }

    func testAssistantDeltaIgnoresDuplicateAndLateSequence() {
        let store = ConversationStore()
        store.accept(event("start", .assistant(.start(messageId: "m1"))))
        store.accept(event("delta-1", .assistant(.delta(messageId: "m1", text: "一", seq: 1))))
        store.accept(event("delta-duplicate", .assistant(.delta(messageId: "m1", text: "重复", seq: 1))))
        store.accept(event("delta-2", .assistant(.delta(messageId: "m1", text: "二", seq: 2))))
        store.accept(event("end", .assistant(.end(messageId: "m1", text: "一二"))))
        store.accept(event("delta-late", .assistant(.delta(messageId: "m1", text: "迟到", seq: 3))))

        XCTAssertEqual(store.messages.first?.content, "一二")
        XCTAssertFalse(store.messages.first?.isStreaming ?? true)
    }
    
    func testStreamingSignalsTrackActiveAssistantAndClearOnEnd() {
        let store = ConversationStore()
        store.accept(event("start", .assistant(.start(messageId: "m1"))))
        let startMessageID = store.activeStreamingMessageID
        store.accept(event("delta-1", .assistant(.delta(messageId: "m1", text: "hello", seq: 1))))
        store.accept(event("delta-2", .assistant(.delta(messageId: "m1", text: " world", seq: 2))))
        
        XCTAssertEqual(store.activeStreamingMessageID, startMessageID)
        XCTAssertEqual(store.streamingRevision, 2)
        
        store.accept(event("end", .assistant(.end(messageId: "m1", text: "hello world"))))
        XCTAssertNil(store.activeStreamingMessageID)
        XCTAssertEqual(store.streamingRevision, 3)
    }
    
    func testStreamingSignalsRemainActiveWhenFileChangeArrivesAfterDelta() {
        let store = ConversationStore()
        store.accept(event("start", .assistant(.start(messageId: "m1"))))
        store.accept(event("delta", .assistant(.delta(messageId: "m1", text: "hello", seq: 1))))
        let activeID = store.activeStreamingMessageID
        store.accept(event("turn", .agent(.status(RemoteAgentStatus(value: "receiving", tool: nil, description: nil)))))
        store.accept(event("file", .file(RemoteFileEvent(path: "src/App.swift", action: .modified, additions: 1, deletions: 0))))
        
        XCTAssertEqual(store.activeStreamingMessageID, activeID)
        XCTAssertEqual(store.streamingRevision, 1)
    }
    
    func testToolTraceAndLogsUseSameLifecycle() {
        let store = ConversationStore()
        store.accept(event("turn", .agent(.status(RemoteAgentStatus(value: "receiving", tool: nil, description: nil)))))
        store.accept(event("start", .tool(.start(RemoteToolCall(id: "call1", name: "bash", input: "npm test")))))
        store.accept(event("output", .tool(.output(data: "PASS"))))
        store.accept(event("end", .tool(.end(toolCallId: "call1", success: true))))
        
        XCTAssertEqual(store.currentTrace?.operationCount, 1)
        XCTAssertEqual(store.currentTrace?.events.first(where: { $0.id == "tool:call1" })?.state, .succeeded)
        XCTAssertEqual(store.logs.count, 2)
        XCTAssertEqual(store.logs.first?.level, .success)
        XCTAssertEqual(store.logs.first?.isRunning, false)
        XCTAssertEqual(store.logs.last?.content, "PASS")
    }
    
    func testFileEventUpdatesMessageTraceAndActivity() {
        let store = ConversationStore()
        store.accept(event("turn", .agent(.status(RemoteAgentStatus(value: "receiving", tool: nil, description: nil)))))
        store.accept(event("file", .file(RemoteFileEvent(
            path: "src/App.swift",
            action: .modified,
            additions: 3,
            deletions: 1
        ))))
        
        XCTAssertEqual(store.messages.last?.fileChanges.first?.normalizedPath, "src/App.swift")
        XCTAssertEqual(store.currentTrace?.events.first(where: { $0.type == .fileChange })?.resource, "src/App.swift")
        XCTAssertTrue(store.activityEvents.contains(where: { $0.type == .fileChange }))
    }
    
    /// 多窗口隔离（B3）：切窗口后 Timeline (activityEvents) 与 Trace 不得残留上一窗口历史。
    /// switchTarget → reset → clearSessionScopedProjection → clearConversationProjection
    /// 必须清空 activityEvents 与 currentTrace。
    func testSwitchTargetClearsTimelineAndTrace_NoCrossWindowLeak() {
        let store = ConversationStore()
        // 窗口 A（win-a）：产生一条 file.change → activity + trace
        store.setCurrentAgentId("win-a")
        store.accept(event("a-turn",
            .agent(.status(RemoteAgentStatus(value: "receiving", tool: nil, description: nil))),
            scope: RemoteEvent.Scope(agentId: "win-a", sessionId: nil, sessionFile: nil, targetAgentId: nil)))
        store.accept(event("a-file",
            .file(RemoteFileEvent(path: "a.swift", action: .modified, additions: 2, deletions: 0)),
            scope: RemoteEvent.Scope(agentId: "win-a", sessionId: nil, sessionFile: nil, targetAgentId: nil)))
        XCTAssertFalse(store.activityEvents.isEmpty, "窗口 A 应已产生 activity")
        XCTAssertNotNil(store.currentTrace, "窗口 A 应已产生 trace")
        XCTAssertEqual(store.messages.count, 1)
        
        // 模拟 ChatViewModel.switchTarget(to:)：设新 agent + reset + 清空
        store.setCurrentAgentId("win-b")
        store.reset()
        
        // 切到 B 后，A 的 Timeline / Trace / messages 全部清空，不得残留。
        XCTAssertTrue(store.activityEvents.isEmpty, "切窗口后 activityEvents 必须为空（B3）")
        XCTAssertNil(store.currentTrace, "切窗口后 currentTrace 必须为 nil（B3）")
        XCTAssertTrue(store.messages.isEmpty, "切窗口后 messages 必须为空")
        XCTAssertTrue(store.recentChanges.isEmpty, "切窗口后 recentChanges 必须为空")
        
        // 且 A 的迟到事件不会再进入（agent 过滤）。
        store.accept(event("a-late-file",
            .file(RemoteFileEvent(path: "a-late.swift", action: .modified, additions: 1, deletions: 0)),
            scope: RemoteEvent.Scope(agentId: "win-a", sessionId: nil, sessionFile: nil, targetAgentId: nil)))
        XCTAssertTrue(store.activityEvents.isEmpty, "迟到 A 事件不得污染当前窗口")
    }
    
    func testSessionHistoryReplacementDoesNotLeakPreviousSession() {
        let store = ConversationStore()
        let first = RemoteHistoryEntry(
            entryId: "a:user",
            sessionId: "session-a",
            role: "user",
            text: "A",
            timestamp: Date(timeIntervalSince1970: 1)
        )
        let second = RemoteHistoryEntry(
            entryId: "b:user",
            sessionId: "session-b",
            role: "user",
            text: "B",
            timestamp: Date(timeIntervalSince1970: 2)
        )
        store.accept(event("history-a", .session(.history(sessionId: "session-a", entries: [first]))))
        store.accept(event("history-b", .session(.history(sessionId: "session-b", entries: [second]))))
        
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.content, "B")
        XCTAssertFalse(store.activityEvents.contains(where: { $0.detail == "A" }))
    }
    
    func testSessionInfoChangeClearsPreviousLiveEventsBeforeHistoryArrives() {
        let store = ConversationStore()
        store.accept(event("info-a", .session(.info(sessionInfo("session-a")))))
        store.accept(event("assistant-a", .assistant(.end(messageId: "a", text: "A"))))
        store.accept(event("info-b", .session(.info(sessionInfo("session-b")))))
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertTrue(store.logs.isEmpty)
        XCTAssertTrue(store.activityEvents.isEmpty)
    }
    
    func testMismatchedAgentAndSessionEventsAreIgnored() {
        let store = ConversationStore()
        store.setCurrentAgentId("win-b")
        store.accept(event("info-b", .session(.info(sessionInfo("session-b", file: "sessions/b.jsonl"))), scope: .init(agentId: "win-b", sessionId: "session-b", sessionFile: "sessions/b.jsonl", targetAgentId: nil)))
        store.accept(event("assistant-a", .assistant(.end(messageId: "a", text: "A")), scope: .init(agentId: "win-a", sessionId: "session-a", sessionFile: "sessions/a.jsonl", targetAgentId: nil)))
        store.accept(event("assistant-b", .assistant(.end(messageId: "b", text: "B")), scope: .init(agentId: "win-b", sessionId: "session-b", sessionFile: "sessions/b.jsonl", targetAgentId: nil)))
        
        XCTAssertEqual(store.messages.count, 1)
        XCTAssertEqual(store.messages.first?.content, "B")
    }
    
    func testBeginSessionSwitchClearsSessionScopedState() {
        let store = ConversationStore()
        store.accept(event("info-a", .session(.info(sessionInfo("session-a", file: "sessions/a.jsonl")))))
        store.accept(event("assistant", .assistant(.end(messageId: "a", text: "hello"))))
        store.accept(RemoteEvent(id: "usage", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "claude", contextTokens: 1, contextWindow: 10, contextPercent: 10,
            totalInput: 1, totalOutput: 2, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 3, totalCost: 0
        ))))
        store.setPendingFileContext(files: ["src/App.swift"])
        store.setPendingWorkspaceFile("src/App.swift")
        store.setQuestionnaire(id: "q1", questions: [ProtocolMessage.QuestionPayload(question: "继续吗？", header: "Q1", multiSelect: false, options: nil)])
        store.accept(RemoteEvent(id: "ws", timestamp: Date(), payload: .workspace(.tree(RemoteWorkspaceTree(path: "", name: "demo", children: [])))))
        store.accept(RemoteEvent(id: "fc", timestamp: Date(), payload: .file(RemoteFileEvent(path: "src/App.swift", action: .modified, additions: 1, deletions: 0))))
        
        store.beginSessionSwitch(expectedSessionFile: "sessions/b.jsonl")
        
        XCTAssertTrue(store.messages.isEmpty)
        XCTAssertNil(store.usageInfo)
        XCTAssertTrue(store.workspaceChildren.isEmpty)
        XCTAssertNil(store.pendingFileContext)
        XCTAssertNil(store.pendingWorkspaceFile)
        XCTAssertTrue(store.recentChanges.isEmpty)
        XCTAssertFalse(store.showQuestionnaire)
    }
    
    func testPendingSessionDropsSessionIdOnlyEventWithoutSessionFile_B3() {
        // B3：pendingSessionFile 期间，仅有 sessionId、无 sessionFile 的事件应被丢弃
        let store = ConversationStore()
        store.setCurrentAgentId("win-a")
        // 先建立一个已知会话身份
        store.accept(event("info-a", .session(.info(sessionInfo("session-a", file: "sessions/a.jsonl"))),
                          scope: .init(agentId: "win-a", sessionId: "session-a", sessionFile: "sessions/a.jsonl", targetAgentId: nil)))
        // 发起切换到 b（进入 pending，期待 sessions/b.jsonl）
        store.beginSessionSwitch(expectedSessionFile: "sessions/b.jsonl")

        // 旧会话风格的迟到事件：只带 sessionId、不带 sessionFile —— 应被丢弃
        store.accept(event("late-usage", .usage(RemoteUsageEvent(
            model: "claude", contextTokens: 1, contextWindow: 10, contextPercent: 10,
            totalInput: 1, totalOutput: 2, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 3, totalCost: 0
        )), scope: .init(agentId: "win-a", sessionId: "session-a", sessionFile: nil, targetAgentId: nil)))
        XCTAssertNil(store.usageInfo, "pending 期间 sessionId-only 事件不应被接受")

        // 正确会话（带匹配的 sessionFile）的事件仍放行：session.info 解除 pending
        store.accept(event("info-b", .session(.info(sessionInfo("session-b", file: "sessions/b.jsonl"))),
                          scope: .init(agentId: "win-a", sessionId: "session-b", sessionFile: "sessions/b.jsonl", targetAgentId: nil)))
        XCTAssertEqual(store.sessionState?.sessionId, "session-b")
    }

    func testUnscopedUsageAndModelAreIgnoredWhenSessionKnown() {
        let store = ConversationStore()
        store.setCurrentAgentId("win-a")
        store.accept(event("info-a", .session(.info(sessionInfo("session-a", file: "sessions/a.jsonl"))), scope: .init(agentId: "win-a", sessionId: "session-a", sessionFile: "sessions/a.jsonl", targetAgentId: nil)))
        store.accept(RemoteEvent(id: "usage", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "claude", contextTokens: 1, contextWindow: 10, contextPercent: 10,
            totalInput: 1, totalOutput: 2, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 3, totalCost: 0
        ))))
        store.accept(RemoteEvent(id: "model", timestamp: Date(), payload: .model(.list(["claude"]))))
        
        XCTAssertNil(store.usageInfo)
        XCTAssertTrue(store.availableModels.isEmpty)
    }
    
    func testStaleGenerationModelListIsIgnored() {
        let store = ConversationStore()
        store.beginSnapshot(generation: 6, reason: "test")
        store.accept(RemoteEvent(id: "model", timestamp: Date(), payload: .model(.list(["old"])), generation: 5))
        XCTAssertTrue(store.availableModels.isEmpty)
    }
    
    func testStaleSelectionAckRequestIsIgnored() {
        let store = ConversationStore()
        store.beginModelSelection(requestId: "sel-new", modelId: "gpt")
        store.accept(RemoteEvent(
            id: "stale-ack",
            timestamp: Date(),
            payload: .model(.selectionAcknowledged(modelId: "claude", success: true, message: nil)),
            selectionRequestId: "sel-old"
        ))
        XCTAssertNil(store.currentModel)
        XCTAssertNil(store.lastModelSelection)
    }
    
    func testOneThousandLogEventsRemainUnique() {
        let store = ConversationStore()
        for index in 0..<1_000 {
            store.accept(event("output-\(index)", .tool(.output(data: "line \(index)"))))
        }
        XCTAssertEqual(store.logs.count, 1_000)
        XCTAssertEqual(Set(store.logs.map(\.id)).count, 1_000)
    }
    
    private func sessionInfo(_ id: String, file: String? = nil) -> RemoteSessionInfo {
        RemoteSessionInfo(
            sessionId: id,
            sessionFile: file,
            name: nil,
            leafId: nil,
            entryCount: 0,
            reason: nil
        )
    }
    
    private func event(_ id: String, _ payload: RemoteEvent.Payload, scope: RemoteEvent.Scope = .empty) -> RemoteEvent {
        RemoteEvent(id: id, timestamp: Date(timeIntervalSince1970: 1), payload: payload, scope: scope)
    }
}
