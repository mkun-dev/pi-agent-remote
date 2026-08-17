import XCTest
@testable import PiAgentRemote

/// Dashboard 派生数据测试（ConversationStore+Dashboard.swift）。
/// 只测派生 computed 的正确性，不测 UI。
final class DashboardDerivedDataTests: XCTestCase {

    // MARK: - 构造辅助

    private func connectedStore() -> ConversationStore {
        let store = ConversationStore()
        store.updateConnectionState(ConnectionStatusSnapshot(phase: .connected, summary: "已连接", relayConnected: true))
        return store
    }

    private func agentEvent(_ agents: [RemoteAgentDescriptor]) -> RemoteEvent {
        RemoteEvent(id: "agents-\(UUID().uuidString)", timestamp: Date(), payload: .relay(.agents(agents)))
    }

    private func descriptor(_ id: String, name: String? = nil, cwd: String? = nil) -> RemoteAgentDescriptor {
        RemoteAgentDescriptor(agentId: id, name: name, cwd: cwd, model: nil, online: true)
    }

    private func statusEvent(_ id: String, value: String, tool: String? = nil, description: String? = nil) -> RemoteEvent {
        RemoteEvent(id: id, timestamp: Date(), payload: .agent(.status(RemoteAgentStatus(value: value, tool: tool, description: description))))
    }

    private func fileEvent(_ id: String, path: String) -> RemoteEvent {
        RemoteEvent(id: id, timestamp: Date(), payload: .file(RemoteFileEvent(path: path, action: .modified, additions: 1, deletions: 0)))
    }

    private func usageEvent(model: String?, tokens: Int?) -> RemoteEvent {
        RemoteEvent(id: "usage-\(UUID().uuidString)", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: model, contextTokens: tokens, contextWindow: 200000, contextPercent: nil,
            totalInput: 100, totalOutput: 50, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 150, totalCost: 0.001
        )))
    }

    private func sessionEvent(id: String, name: String?) -> RemoteEvent {
        RemoteEvent(id: "info-\(id)", timestamp: Date(), payload: .session(.info(RemoteSessionInfo(
            sessionId: id, sessionFile: "sessions/\(id).jsonl", name: name,
            leafId: nil, entryCount: 0, reason: nil
        ))))
    }

    // MARK: - ① 项目与会话

    func testProjectName_NoCurrentAgent_ReturnsUnconnected() {
        let store = connectedStore()
        XCTAssertEqual(store.projectName, "未连接")
    }

    func testProjectName_UsesAgentDisplayName_NamePreference() {
        let store = connectedStore()
        store.accept(agentEvent([descriptor("win-a", name: "Pi-link", cwd: "/x/pi-link")]))
        store.setCurrentAgentId("win-a")
        XCTAssertEqual(store.projectName, "Pi-link")
    }

    func testProjectName_FallsBackToCwdBasename() {
        let store = connectedStore()
        store.accept(agentEvent([descriptor("win-a", name: nil, cwd: "/root/projects/pi-link")]))
        store.setCurrentAgentId("win-a")
        XCTAssertEqual(store.projectName, "pi-link")
    }

    func testSessionDisplayName_FallbackToCurrentSession() {
        let store = connectedStore()
        XCTAssertEqual(store.sessionDisplayName, "当前会话")
    }

    func testSessionDisplayName_UsesSessionName() {
        let store = connectedStore()
        store.accept(sessionEvent(id: "s1", name: "Multi Window Support"))
        XCTAssertEqual(store.sessionDisplayName, "Multi Window Support")
    }

    // MARK: - ② Agent 状态

    func testStatusLevel_Disconnected() {
        let store = ConversationStore() // 未 connect
        XCTAssertEqual(store.dashboardStatusLevel, .disconnected)
    }

    func testStatusLevel_Offline_WhenNoAgentsOnline() {
        let store = connectedStore()
        store.accept(agentEvent([]))
        XCTAssertEqual(store.dashboardStatusLevel, .offline)
    }

    func testStatusLevel_Active_ForThinking() {
        let store = connectedStore()
        store.accept(statusEvent("s1", value: "thinking"))
        XCTAssertEqual(store.dashboardStatusLevel, .active)
    }

    func testStatusLevel_Working_ForUsingTool() {
        let store = connectedStore()
        store.accept(statusEvent("s1", value: "using_tool", tool: "run_tests", description: "Running tests"))
        XCTAssertEqual(store.dashboardStatusLevel, .working)
    }

    func testStatusLevel_Working_ForStreaming() {
        let store = connectedStore()
        store.accept(statusEvent("s1", value: "streaming"))
        XCTAssertEqual(store.dashboardStatusLevel, .working)
    }

    func testStatusLevel_Completed() {
        let store = connectedStore()
        store.accept(statusEvent("s1", value: "completed"))
        XCTAssertEqual(store.dashboardStatusLevel, .completed)
    }

    func testStatusLevel_Failed() {
        let store = connectedStore()
        store.accept(statusEvent("s1", value: "error", description: "编译失败"))
        XCTAssertEqual(store.dashboardStatusLevel, .failed)
    }

    func testStatusText_MapsKnownStates() {
        let idle = connectedStore()
        XCTAssertEqual(idle.dashboardStatusText, "就绪")

        let thinking = connectedStore()
        thinking.accept(statusEvent("t", value: "thinking"))
        XCTAssertEqual(thinking.dashboardStatusText, "思考中")

        let tool = connectedStore()
        tool.accept(statusEvent("t", value: "using_tool", tool: "run_tests"))
        XCTAssertEqual(tool.dashboardStatusText, "执行工具")

        let streaming = connectedStore()
        streaming.accept(statusEvent("t", value: "streaming"))
        XCTAssertEqual(streaming.dashboardStatusText, "生成中")

        let error = connectedStore()
        error.accept(statusEvent("t", value: "error", description: "网络失败"))
        XCTAssertEqual(error.dashboardStatusText, "网络失败")
    }

    func testIsDashboardWorking_TrueOnlyWhileBusy() {
        let idle = connectedStore()
        XCTAssertFalse(idle.isDashboardWorking)

        let tool = connectedStore()
        tool.accept(statusEvent("t", value: "using_tool", tool: "run_tests"))
        XCTAssertTrue(tool.isDashboardWorking)

        let done = connectedStore()
        done.accept(statusEvent("t", value: "completed"))
        XCTAssertFalse(done.isDashboardWorking)
    }

    // MARK: - ③ 当前任务

    func testCurrentActionText_UsingToolDescriptionWins() {
        let store = connectedStore()
        store.accept(statusEvent("t", value: "using_tool", tool: "run_tests", description: "Running tests"))
        XCTAssertEqual(store.currentActionText, "Running tests")
    }

    func testCurrentActionText_UsingToolFallsBackToToolName() {
        let store = connectedStore()
        store.accept(statusEvent("t", value: "using_tool", tool: "run_tests", description: ""))
        XCTAssertEqual(store.currentActionText, "run_tests")
    }

    func testCurrentActionText_StreamingPlaceholder() {
        let store = connectedStore()
        store.accept(statusEvent("t", value: "streaming"))
        XCTAssertEqual(store.currentActionText, "生成回复中…")
    }

    func testCurrentActionText_IdleFallsBackToLastActivityTitle() {
        let store = connectedStore()
        store.accept(fileEvent("f1", path: "src/App.swift"))
        let lastActivity = store.activityEvents.last(where: { $0.type != .userRequest })
        XCTAssertNotNil(lastActivity, "file.change 应产生 activity")
        XCTAssertEqual(store.currentActionText, lastActivity?.title)
    }

    func testRecentFileChangeCount_CountsChanges() {
        let store = connectedStore()
        store.accept(fileEvent("f1", path: "a.swift"))
        store.accept(fileEvent("f2", path: "b.swift"))
        XCTAssertEqual(store.recentFileChangeCount, 2)
    }

    // MARK: - ④ 最近修改

    func testRecentChangesForDashboard_PrefixesFive() {
        let store = connectedStore()
        for i in 1...6 {
            store.accept(fileEvent("f\(i)", path: "file\(i).swift"))
        }
        XCTAssertEqual(store.recentChangesForDashboard.count, 5)
        // 最新在前（recentChanges 插入序即最新）
        XCTAssertEqual(store.recentChangesForDashboard.first?.fileName, "file6.swift")
    }

    // MARK: - ⑦ 模型与用量

    func testModelDisplayName_NoModel_ReturnsUnloaded() {
        let store = connectedStore()
        XCTAssertEqual(store.modelDisplayName, "未加载")
    }

    func testModelDisplayName_AdoptsUsageModel() {
        let store = connectedStore()
        store.accept(usageEvent(model: "claude-sonnet", tokens: 1200))
        XCTAssertEqual(store.modelDisplayName, "claude-sonnet")
    }

    func testUsageDisplayText_FormatsKilokens() {
        let store = connectedStore()
        store.accept(usageEvent(model: "claude-sonnet", tokens: 12000))
        XCTAssertEqual(store.usageDisplayText, "12k tokens")
    }

    func testUsageDisplayText_NilWhenNoUsage() {
        let store = connectedStore()
        XCTAssertNil(store.usageDisplayText)
    }

    // MARK: - ⑥ 最近活动

    func testRecentActivitiesForDashboard_LastThreeReversed() {
        let store = connectedStore()
        for i in 1...5 {
            store.accept(fileEvent("f\(i)", path: "file\(i).swift"))
        }
        let activities = store.recentActivitiesForDashboard
        XCTAssertEqual(activities.count, 3)
        let all = store.activityEvents
        XCTAssertEqual(activities.map(\.title), all.suffix(3).reversed().map(\.title))
    }

    // MARK: - ⑤ 快速继续

    func testCanContinue_RequiresConnectedAndOnline() {
        let disconnected = ConversationStore()
        XCTAssertFalse(disconnected.canContinue)

        let connected = connectedStore()
        XCTAssertTrue(connected.canContinue)

        let offline = connectedStore()
        offline.accept(agentEvent([]))
        XCTAssertFalse(offline.canContinue)
    }
}
