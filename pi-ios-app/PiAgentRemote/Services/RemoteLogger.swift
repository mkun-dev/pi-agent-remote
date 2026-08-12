import Foundation
import os.log

/// 统一分类日志系统，方便后续定位问题。
/// 使用 OSLog（Apple Unified Logging），发布构建不输出到控制台，零性能开销。
/// 在 Debug 构建中可通过 Console.app 或 Xcode 控制台按 subsystem/category 筛选。
enum RemoteLogger {
    /// 日志分类，对应不同子系统
    enum Category: String {
        case websocket = "WebSocket"
        case event = "Event"
        case store = "Store"
        case ui = "UI"
        case media = "Media"
        case model = "Model"
        case usage = "Usage"
        case session = "Session"
        case workspace = "Workspace"
        case lifecycle = "Lifecycle"
        case scroll = "Scroll"
        case error = "Error"
    }

    private static let subsystem = "com.piagent.remote"

    /// 缓存各 category 对应的 OSLog 实例，避免重复创建
    private static let loggers: [Category: OSLog] = {
        var map: [Category: OSLog] = [:]
        for category in [
            Category.websocket, .event, .store, .ui, .media,
            .model, .usage, .session, .workspace, .lifecycle, .scroll, .error
        ] {
            map[category] = OSLog(subsystem: subsystem, category: category.rawValue)
        }
        return map
    }()

    // MARK: - Public API

    static func debug(_ message: String, category: Category, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, category: category, file: file, line: line)
    }

    static func info(_ message: String, category: Category, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, category: category, file: file, line: line)
    }

    static func warning(_ message: String, category: Category, file: String = #fileID, line: Int = #line) {
        log(message, type: .default, category: category, file: file, line: line)
    }

    static func error(_ message: String, category: Category = .error, file: String = #fileID, line: Int = #line) {
        log(message, type: .error, category: category, file: file, line: line)
    }

    // MARK: - Internal

    private static func log(
        _ message: String,
        type: OSLogType,
        category: Category,
        file: String,
        line: Int
    ) {
        guard let logger = loggers[category] else { return }
        os_log("%{public}@:%d %{public}@", log: logger, type: type, file, line, message)
    }
}

// MARK: - Convenience extensions

extension RemoteLogger {
    /// WebSocket 连接/断开/重连日志
    static func ws(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, category: .websocket, file: file, line: line)
    }

    /// RemoteEvent 收发日志
    static func event(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, category: .event, file: file, line: line)
    }

    /// ConversationStore 状态变更日志
    static func store(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, category: .store, file: file, line: line)
    }
    
    static func session(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, category: .session, file: file, line: line)
    }
    
    static func model(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, category: .model, file: file, line: line)
    }
    
    static func workspace(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, category: .workspace, file: file, line: line)
    }
    
    static func usage(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, category: .usage, file: file, line: line)
    }
    
    static func scroll(_ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        log(message, type: .debug, category: .scroll, file: file, line: line)
        #endif
    }
}
