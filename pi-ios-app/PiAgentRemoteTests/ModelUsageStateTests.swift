import XCTest
@testable import PiAgentRemote

/// Tests for the unified model & usage state in ConversationStore (RemoteEvent driven).
final class ModelUsageStateTests: XCTestCase {

    func testModelListAndCurrentModelFromEvents() {
        let store = ConversationStore()

        // Simulate model.list
        let listEvent = RemoteEvent(
            id: "m1",
            timestamp: Date(),
            payload: .model(.list(["claude-sonnet", "gpt-4o"]))
        )
        store.accept(listEvent)

        XCTAssertEqual(store.availableModels, ["claude-sonnet", "gpt-4o"])

        // Simulate select ack (success)
        let ack = RemoteEvent(
            id: "m2",
            timestamp: Date(),
            payload: .model(.selectionAcknowledged(modelId: "gpt-4o", success: true, message: nil))
        )
        store.accept(ack)

        XCTAssertEqual(store.currentModel, "gpt-4o")
        XCTAssertNotNil(store.lastModelSelection)
        XCTAssertTrue(store.lastModelSelection?.success == true)
    }

    func testUsageAdoptsModelWhenNoCurrentYet() {
        let store = ConversationStore()
        let usage = RemoteUsageEvent(
            model: "claude-sonnet",
            contextTokens: 1200,
            contextWindow: 200000,
            contextPercent: 3,
            totalInput: 100,
            totalOutput: 50,
            totalCacheRead: 10,
            totalCacheWrite: 5,
            totalReasoning: 0,
            totalTokens: 150,
            totalCost: 0.0012
        )
        store.accept(RemoteEvent(id: "u1", timestamp: Date(), payload: .usage(usage)))

        XCTAssertEqual(store.usageInfo?.model, "claude-sonnet")
        XCTAssertEqual(store.currentModel, "claude-sonnet")
    }

    func testUsageSnapshotUpdatesModelChangedOnPC() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "u1", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "model-a", contextTokens: nil, contextWindow: 0, contextPercent: nil,
            totalInput: 10, totalOutput: 5, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 15, totalCost: 0
        ))))
        store.accept(RemoteEvent(id: "u2", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "model-b", contextTokens: nil, contextWindow: 0, contextPercent: nil,
            totalInput: 20, totalOutput: 8, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 28, totalCost: 0
        ))))

        XCTAssertEqual(store.currentModel, "model-b")
        XCTAssertEqual(store.usageInfo?.totalTokens, 28)
    }

    func testSelectionResultDoesNotPolluteMessages() {
        let store = ConversationStore()
        let before = store.messages.count

        let ack = RemoteEvent(
            id: "m3",
            timestamp: Date(),
            payload: .model(.selectionAcknowledged(modelId: "x", success: true, message: "ok"))
        )
        store.accept(ack)

        // No new chat messages should be appended for model switch feedback
        XCTAssertEqual(store.messages.count, before)
        XCTAssertNotNil(store.lastModelSelection)
    }
    
    func testFailedSelectionDoesNotOverrideCurrentModel() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "u", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "claude", contextTokens: nil, contextWindow: 0, contextPercent: nil,
            totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 0, totalCost: 0
        ))))
        store.accept(RemoteEvent(id: "fail", timestamp: Date(), payload: .model(.selectionAcknowledged(modelId: "gpt", success: false, message: "nope"))))
        
        XCTAssertEqual(store.currentModel, "claude")
        XCTAssertEqual(store.lastModelSelection?.success, false)
    }

    func testResetClearsModelState() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "l", timestamp: Date(), payload: .model(.list(["a", "b"]))))
        store.accept(RemoteEvent(id: "u", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "a", contextTokens: nil, contextWindow: 0, contextPercent: nil,
            totalInput: 0, totalOutput: 0, totalCacheRead: 0, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 0, totalCost: 0
        ))))
        store.accept(RemoteEvent(id: "s", timestamp: Date(), payload: .model(.selectionAcknowledged(modelId: "b", success: true, message: nil))))

        XCTAssertFalse(store.availableModels.isEmpty)
        XCTAssertNotNil(store.currentModel)
        XCTAssertNotNil(store.usageInfo)
        XCTAssertNotNil(store.lastModelSelection)

        store.reset()

        XCTAssertTrue(store.availableModels.isEmpty)
        XCTAssertNil(store.currentModel)
        XCTAssertNil(store.usageInfo)
        XCTAssertNil(store.lastModelSelection)
    }
    
    func testDisconnectClearsStaleModelAndUsage() {
        let store = ConversationStore()
        store.accept(RemoteEvent(id: "l", timestamp: Date(), payload: .model(.list(["claude"]))))
        store.accept(RemoteEvent(id: "u", timestamp: Date(), payload: .usage(RemoteUsageEvent(
            model: "claude", contextTokens: 10, contextWindow: 100, contextPercent: 10,
            totalInput: 5, totalOutput: 6, totalCacheRead: 1, totalCacheWrite: 0,
            totalReasoning: 0, totalTokens: 11, totalCost: 0.01
        ))))
        store.updateConnectionState(ConnectionStatusSnapshot(phase: .disconnected, summary: "已断开", relayConnected: false))
        
        XCTAssertTrue(store.availableModels.isEmpty)
        XCTAssertNil(store.currentModel)
        XCTAssertNil(store.usageInfo)
    }
    
    func testStaleGenerationUsageIsIgnored() {
        let store = ConversationStore()
        store.beginSnapshot(generation: 5, reason: "test")
        store.accept(RemoteEvent(
            id: "old-usage",
            timestamp: Date(),
            payload: .usage(RemoteUsageEvent(
                model: "claude", contextTokens: nil, contextWindow: 0, contextPercent: nil,
                totalInput: 1, totalOutput: 2, totalCacheRead: 0, totalCacheWrite: 0,
                totalReasoning: 0, totalTokens: 3, totalCost: 0
            )),
            generation: 4
        ))
        XCTAssertNil(store.usageInfo)
    }
    
    func testSuccessfulSelectionPreventsOlderUsageModelRollback() {
        let store = ConversationStore()
        store.beginSnapshot(generation: 10, reason: "initial")
        store.beginModelSelection(requestId: "sel-1", modelId: "gpt")
        store.accept(RemoteEvent(
            id: "ack",
            timestamp: Date(),
            payload: .model(.selectionAcknowledged(modelId: "gpt", success: true, message: nil)),
            selectionRequestId: "sel-1"
        ))
        store.accept(RemoteEvent(
            id: "late-usage",
            timestamp: Date(),
            payload: .usage(RemoteUsageEvent(
                model: "claude", contextTokens: nil, contextWindow: 0, contextPercent: nil,
                totalInput: 5, totalOutput: 5, totalCacheRead: 0, totalCacheWrite: 0,
                totalReasoning: 0, totalTokens: 10, totalCost: 0
            )),
            generation: 10
        ))
        
        XCTAssertEqual(store.currentModel, "gpt")
        XCTAssertEqual(store.usageInfo?.model, "gpt")
    }
}
