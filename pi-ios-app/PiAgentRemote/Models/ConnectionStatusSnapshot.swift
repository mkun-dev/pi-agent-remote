import Foundation

enum ConnectionPhase: Equatable {
    case disconnected
    case connecting
    case connected
    case reconnecting(retryInSeconds: Int)
    case error
}

enum AgentReachability: Equatable {
    case unknown
    case noAgents
    case agentsAvailable(count: Int)
    case currentTargetOffline
    case ambiguousTarget

    var summaryText: String {
        switch self {
        case .unknown: return "未知"
        case .noAgents: return "无窗口"
        case .agentsAvailable(let count): return "\(count) 在线"
        case .currentTargetOffline: return "已离线"
        case .ambiguousTarget: return "待选择"
        }
    }
}

struct ConnectionStatusSnapshot: Equatable {
    var phase: ConnectionPhase = .disconnected
    var summary: String = "已断开"
    var detail: String? = nil
    var lastError: String? = nil
    var lastDisconnectReason: String? = nil
    var lastConnectedAt: Date? = nil
    var lastDisconnectedAt: Date? = nil
    var isAutoReconnectEnabled = false
    var relayConnected = false
    var agentReachability: AgentReachability = .unknown
    var targetAgentId: String? = nil

    var isConnected: Bool {
        if case .connected = phase { return true }
        return false
    }
}
