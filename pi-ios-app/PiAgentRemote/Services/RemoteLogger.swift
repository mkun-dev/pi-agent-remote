import Foundation
import os.log

/// 统一日志等级（第六阶段：日志分级）。
/// 命名避开 LogEntry.LogLevel（消息条目等级）→ 使用 LoggingLevel（日志可见性等级）。
///
/// - debug:   开发模式专用（[WORKSPACE]/[MODEL]/[USAGE] 等调试事件），
///            默认不进入任何用户可见通道，仅 Console / Debug Panel / File Log。
/// - info:    正常业务信息（连接/会话/模型切换/用量广播等），用户聊天中不可见。
/// - warning: 可恢复异常（认证失败、心跳超时等）。
/// - error:   真实错误，始终保留可见（Console / File Log）。
enum LoggingLevel: Int, Comparable {
    case debug = 0
    case info = 1
    case warning = 2
    case error = 3

    static func < (lhs: LoggingLevel, rhs: LoggingLevel) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// 统一分类日志系统，方便后续定位问题。
/// 使用 OSLog（Apple Unified Logging），发布构建不输出到控制台，零性能开销。
/// 在 Debug 构建中可通过 Console.app 或 Xcode 控制台按 subsystem/category 筛选。
/// 日志只进入 Console / Debug Panel / File Log，**永远不会进入聊天消息列表**。
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
        log(message, type: .debug, level: .debug, category: category, file: file, line: line)
    }

    static func info(_ message: String, category: Category, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, level: .info, category: category, file: file, line: line)
    }

    static func warning(_ message: String, category: Category, file: String = #fileID, line: Int = #line) {
        log(message, type: .default, level: .warning, category: category, file: file, line: line)
    }

    static func error(_ message: String, category: Category = .error, file: String = #fileID, line: Int = #line) {
        log(message, type: .error, level: .error, category: category, file: file, line: line)
    }

    /// 当前最低可见日志等级：
    /// - Debug 构建：`.debug`（开发模式，允许 [WORKSPACE]/[MODEL]/[USAGE]）
    /// - Release 构建：`.warning`（用户环境，调试日志一律关闭）
    /// 只影响 Console 输出；聊天消息列表始终不接收任何日志。
    #if DEBUG
    static let minimumVisibleLevel: LoggingLevel = .debug
    #else
    static let minimumVisibleLevel: LoggingLevel = .warning
    #endif

    /// 内部：按最低可见等级过滤后写入 OSLog。
    private static func log(
        _ message: String,
        type: OSLogType,
        level: LoggingLevel,
        category: Category,
        file: String,
        line: Int
    ) {
        guard level >= minimumVisibleLevel else { return }
        guard let logger = loggers[category] else { return }
        os_log("%{public}@:%d %{public}@", log: logger, type: type, file, line, message)
    }
}

// MARK: - Convenience extensions

extension RemoteLogger {
    /// WebSocket 连接/断开/重连日志
    static func ws(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, level: .info, category: .websocket, file: file, line: line)
    }

    /// RemoteEvent 收发日志
    static func event(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, level: .debug, category: .event, file: file, line: line)
    }

    /// ConversationStore 状态变更日志
    static func store(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, level: .debug, category: .store, file: file, line: line)
    }
    
    static func session(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, level: .info, category: .session, file: file, line: line)
    }
    
    static func model(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, level: .info, category: .model, file: file, line: line)
    }
    
    static func workspace(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .debug, level: .debug, category: .workspace, file: file, line: line)
    }
    
    static func usage(_ message: String, file: String = #fileID, line: Int = #line) {
        log(message, type: .info, level: .info, category: .usage, file: file, line: line)
    }
    
    static func scroll(_ message: String, file: String = #fileID, line: Int = #line) {
        #if DEBUG
        log(message, type: .debug, level: .debug, category: .scroll, file: file, line: line)
        #endif
    }
}
