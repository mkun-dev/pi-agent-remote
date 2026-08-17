import Foundation

#if DEBUG
extension Message {
    static let sampleUser: Message = .init(
        id: "u1",
        sender: .user,
        content: "帮我分析一下这个项目",
        timestamp: Date(),
        kind: .text
    )
    
    static let sampleThinking: Message = .init(
        id: "t1",
        sender: .pi,
        content: "我正在分析项目结构...",
        timestamp: Date(),
        kind: .thinking
    )
    
    static let sampleReply: Message = .init(
        id: "r1",
        sender: .pi,
        content: "这是一个 Swift + TypeScript 的混合项目，包含 Pi 扩展和 iOS 远程客户端。",
        timestamp: Date(),
        kind: .text
    )
    
    static let sampleTool: Message = .init(
        id: "tool1",
        sender: .pi,
        content: "▶ shell: ls -la",
        timestamp: Date(),
        kind: .tool
    )
    
    static let sampleTerminal: Message = .init(
        id: "term1",
        sender: .pi,
        content: "src/\nREADME.md\npackage.json",
        timestamp: Date(),
        kind: .terminal
    )
}

extension ChatViewModel {
    static var preview: ChatViewModel {
        let vm = ChatViewModel()
        vm.conversationStore.loadPreviewMessages([
            .sampleUser,
            .sampleThinking,
            .sampleReply,
            .sampleTool,
            .sampleTerminal
        ])
        vm.conversationStore.updateConnectionState(ConnectionStatusSnapshot(phase: .connected, summary: "Connected (Preview)", relayConnected: true))
        return vm
    }
}
#endif
