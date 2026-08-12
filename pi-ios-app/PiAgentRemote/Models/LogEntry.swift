import Foundation

enum LogLevel: Equatable {
    case info
    case success
    case warning
    case error
}

enum LogType: Equatable {
    case tool
    case shell
    case stdout
    case stderr
    case system
}

struct LogEntry: Identifiable, Equatable {
    let id: String
    let timestamp: Date
    let level: LogLevel
    let type: LogType
    let title: String
    let content: String
    let isRunning: Bool
    
    var lineCount: Int {
        guard !content.isEmpty else { return 0 }
        return content.components(separatedBy: "\n").count
    }
}
