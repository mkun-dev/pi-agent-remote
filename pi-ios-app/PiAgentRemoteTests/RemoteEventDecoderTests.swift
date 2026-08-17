import XCTest
@testable import PiAgentRemote

final class RemoteEventDecoderTests: XCTestCase {
    func testAssistantStreamingEventsDecode() throws {
        let start = try decode(#"{"id":"1","type":"assistant.start","timestamp":1000,"payload":{"messageId":"m1"}}"#)
        let delta = try decode(#"{"id":"2","type":"assistant.delta","timestamp":1001,"payload":{"messageId":"m1","text":"你好","seq":2}}"#)
        let end = try decode(#"{"id":"3","type":"assistant.end","timestamp":1002,"payload":{"messageId":"m1","text":"你好世界"}}"#)
        XCTAssertEqual(start.payload, .assistant(.start(messageId: "m1")))
        XCTAssertEqual(delta.payload, .assistant(.delta(messageId: "m1", text: "你好", seq: 2)))
        XCTAssertEqual(end.payload, .assistant(.end(messageId: "m1", text: "你好世界")))
    }
    
    func testToolAndFileEventsDecode() throws {
        let tool = try decode(#"{"id":"1","type":"tool.start","payload":{"toolCallId":"call1","tool":"bash","command":"npm test"}}"#)
        let file = try decode(#"{"id":"2","type":"file.change","payload":{"path":"src/a.swift","action":"modified","additions":2,"deletions":1}}"#)
        XCTAssertEqual(tool.payload, .tool(.start(RemoteToolCall(id: "call1", name: "bash", input: "npm test"))))
        XCTAssertEqual(file.payload, .file(RemoteFileEvent(path: "src/a.swift", action: .modified, additions: 2, deletions: 1)))
    }
    
    func testCompatibilityAliasesDecodeToCanonicalEvents() throws {
        let completed = try decode(#"{"id":"1","type":"agent.completed","payload":{"description":"done"}}"#)
        let update = try decode(#"{"id":"2","type":"tool.update","payload":{"data":"partial"}}"#)
        XCTAssertEqual(completed.payload, .agent(.status(RemoteAgentStatus(
            value: "completed",
            tool: nil,
            description: "done"
        ))))
        XCTAssertEqual(update.payload, .tool(.output(data: "partial")))
    }
    
    func testScopeMetadataDecodesForSessionAndAgentRouting() throws {
        let event = try decode(#"{"id":"1","type":"assistant.delta","timestamp":1001,"payload":{"messageId":"m1","text":"hi","seq":1,"agentId":"win-1","sessionId":"session-a","sessionFile":"sessions/a.jsonl","targetAgentId":"win-1","generation":12,"selectionRequestId":"sel-1"}}"#)
        XCTAssertEqual(event.scope.agentId, "win-1")
        XCTAssertEqual(event.scope.sessionId, "session-a")
        XCTAssertEqual(event.scope.sessionFile, "sessions/a.jsonl")
        XCTAssertEqual(event.scope.targetAgentId, "win-1")
        XCTAssertEqual(event.generation, 12)
        XCTAssertEqual(event.selectionRequestId, "sel-1")
    }

    func testHistoryRewoundDecodes() throws {
        let event = try decode(#"{"id":"rw1","type":"history.rewound","timestamp":1003,"payload":{"text":"把 foo 改成 bar","removedMessageCount":2}}"#)
        XCTAssertEqual(event.payload, .history(.rewound(rewoundContent: "把 foo 改成 bar", removedUserMessageCount: 2)))
    }
    
    private func decode(_ json: String) throws -> RemoteEvent {
        try XCTUnwrap(RemoteEventDecoder.decode(text: json))
    }
}
