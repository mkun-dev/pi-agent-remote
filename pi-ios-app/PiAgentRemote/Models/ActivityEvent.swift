import Foundation

enum ActivityEventType: Equatable {
    case userRequest
    case thinking
    case toolExecution
    case fileChange
    case completed
    case error
}

struct ActivityEvent: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let type: ActivityEventType
    let title: String
    let detail: String?
    var isRunning: Bool = false
}
