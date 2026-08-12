import Foundation

/// Agent Trace 的人类可读事件类型，仅由 iOS 使用，不改变 WebSocket 协议。
enum TraceEventType: Equatable {
    case thinking
    case tool
    case fileChange
    case command
    case completed
}

enum TraceEventState: Equatable {
    case running
    case succeeded
    case failed
}

struct TraceEvent: Identifiable, Equatable {
    let id: String
    var type: TraceEventType
    var title: String
    var detail: String?
    var resource: String?
    var additions: Int?
    var deletions: Int?
    var state: TraceEventState
}

struct AgentTrace: Equatable {
    var events: [TraceEvent] = []
    var isExpanded: Bool = true
    var isComplete: Bool = false
    /// WebSocket 自动状态每变化一次递增；本地手动展开不改 revision，避免被旧状态覆盖。
    var revision: Int = 0
    
    /// 只有 Tool、命令或文件变化才展示 Trace；普通问候的 thinking 状态不会产生空 Trace。
    var shouldDisplay: Bool {
        events.contains { event in
            event.type == .tool || event.type == .command || event.type == .fileChange
        }
    }
    
    var operationCount: Int {
        events.filter {
            $0.type == .tool || $0.type == .command || $0.type == .fileChange
        }.count
    }
    
    mutating func recordThinking(status: String, detail: String?) {
        let title: String
        switch status {
        case "receiving": title = "接收任务"
        case "planning": title = "规划任务"
        default: title = "分析任务"
        }
        let readableDetail = Self.meaningfulStatusDetail(detail)
        let event = TraceEvent(
            id: "trace-thinking",
            type: .thinking,
            title: title,
            detail: readableDetail,
            resource: nil,
            additions: nil,
            deletions: nil,
            state: .running
        )
        upsert(event)
        isComplete = false
        if shouldDisplay { isExpanded = true }
        revision += 1
    }
    
    mutating func recordNarration(_ text: String) {
        guard shouldDisplay else { return }
        let value = Self.compact(text, limit: 240)
        guard !value.isEmpty else { return }
        if let index = events.firstIndex(where: { $0.type == .thinking }) {
            guard events[index].detail != value else { return }
            events[index].detail = value
        } else {
            events.insert(TraceEvent(
                id: "trace-thinking",
                type: .thinking,
                title: "分析任务",
                detail: value,
                resource: nil,
                additions: nil,
                deletions: nil,
                state: .succeeded
            ), at: 0)
        }
        revision += 1
    }
    
    mutating func recordToolStarted(toolCallId: String, toolName: String, detail: String) {
        if let thinkingIndex = events.firstIndex(where: { $0.type == .thinking }) {
            events[thinkingIndex].state = .succeeded
        }
        let presentation = Self.toolPresentation(toolName: toolName, detail: detail)
        let event = TraceEvent(
            id: "tool:\(toolCallId)",
            type: presentation.type,
            title: presentation.title,
            detail: presentation.detail,
            resource: presentation.resource,
            additions: nil,
            deletions: nil,
            state: .running
        )
        upsert(event)
        isExpanded = true
        isComplete = false
        revision += 1
    }
    
    mutating func recordToolEnded(toolCallId: String, success: Bool) {
        guard let index = events.firstIndex(where: { $0.id == "tool:\(toolCallId)" }) else { return }
        let nextState: TraceEventState = success ? .succeeded : .failed
        guard events[index].state != nextState else { return }
        events[index].state = nextState
        revision += 1
    }
    
    mutating func recordFileChange(_ change: FileChange) {
        let path = change.normalizedPath
        let normalizedPath = Self.normalizedResource(path)
        let title = Self.fileChangeTitle(change.type)
        let matchingToolIndex = events.lastIndex { event in
            event.type == .tool &&
            Self.isFileMutationTitle(event.title) &&
            event.resource.map(Self.normalizedResource) == normalizedPath
        }
        
        if let existingIndex = events.firstIndex(where: {
            $0.type == .fileChange && $0.resource.map(Self.normalizedResource) == normalizedPath
        }) {
            events[existingIndex].title = title
            events[existingIndex].detail = path
            events[existingIndex].state = .succeeded
            events[existingIndex].additions = Self.sum(events[existingIndex].additions, change.additions)
            events[existingIndex].deletions = Self.sum(events[existingIndex].deletions, change.deletions)
            if let matchingToolIndex, matchingToolIndex != existingIndex {
                events.remove(at: matchingToolIndex)
            }
        } else if let matchingToolIndex {
            events[matchingToolIndex].type = .fileChange
            events[matchingToolIndex].title = title
            events[matchingToolIndex].detail = path
            events[matchingToolIndex].resource = path
            events[matchingToolIndex].additions = change.additions
            events[matchingToolIndex].deletions = change.deletions
            events[matchingToolIndex].state = .succeeded
        } else {
            events.append(TraceEvent(
                id: "file:\(normalizedPath)",
                type: .fileChange,
                title: title,
                detail: path,
                resource: path,
                additions: change.additions,
                deletions: change.deletions,
                state: .succeeded
            ))
        }
        isExpanded = true
        isComplete = false
        revision += 1
    }
    
    mutating func markThinkingFinished() {
        guard let index = events.firstIndex(where: { $0.type == .thinking }),
              events[index].state == .running else { return }
        events[index].state = .succeeded
        revision += 1
    }
    
    mutating func expandForActiveWork() {
        guard shouldDisplay, !isComplete, !isExpanded else { return }
        isExpanded = true
        revision += 1
    }
    
    mutating func collapseAfterAssistantMessage() {
        guard shouldDisplay, isExpanded else { return }
        isExpanded = false
        revision += 1
    }
    
    mutating func complete(success: Bool, detail: String? = nil) {
        if let thinkingIndex = events.firstIndex(where: { $0.type == .thinking }) {
            events[thinkingIndex].state = success ? .succeeded : .failed
        }
        isComplete = true
        isExpanded = false
        guard shouldDisplay else {
            revision += 1
            return
        }
        let event = TraceEvent(
            id: "trace-completed",
            type: .completed,
            title: success ? "执行完成" : "执行失败",
            detail: success ? nil : Self.compactOptional(detail, limit: 180),
            resource: nil,
            additions: nil,
            deletions: nil,
            state: success ? .succeeded : .failed
        )
        upsert(event)
        revision += 1
    }
    
    private mutating func upsert(_ event: TraceEvent) {
        if let index = events.firstIndex(where: { $0.id == event.id }) {
            events[index] = event
        } else {
            events.append(event)
        }
    }
    
    private static func meaningfulStatusDetail(_ detail: String?) -> String? {
        guard let detail else { return nil }
        let value = compact(detail, limit: 180)
        let generic = ["Pi 收到请求", "Pi 正在思考", "继续分析"]
        return generic.contains(value) ? nil : (value.isEmpty ? nil : value)
    }
    
    private static func toolPresentation(
        toolName: String,
        detail: String
    ) -> (type: TraceEventType, title: String, detail: String?, resource: String?) {
        let presentation = ToolPresentation.resolve(name: toolName, input: detail)
        let compactDetail = compact(detail, limit: 240)
        let fileResource = extractFileResource(from: detail)
        switch presentation.semantic {
        case .readFile, .editFile, .writeFile:
            return (.tool, presentation.displayName, fileResource ?? compactOptional(compactDetail), fileResource)
        case .command, .test:
            return (.command, presentation.displayName, compactOptional(compactDetail), nil)
        case .question:
            return (.tool, presentation.displayName, nil, nil)
        default:
            return (.tool, presentation.displayName, compactOptional(compactDetail), nil)
        }
    }
    
    private static func extractFileResource(from raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if let data = trimmed.data(using: .utf8),
           let json = try? JSONSerialization.jsonObject(with: data),
           let object = json as? [String: Any] {
            for key in ["path", "file", "file_path"] {
                if let path = object[key] as? String, !path.isEmpty { return path }
            }
        }
        if trimmed.hasPrefix("{") || trimmed.contains("\n") { return nil }
        if let range = trimmed.range(of: " (offset=") {
            return String(trimmed[..<range.lowerBound])
        }
        return compact(trimmed, limit: 200)
    }
    
    private static func fileChangeTitle(_ type: FileChangeType) -> String {
        switch type {
        case .added: return "新增文件"
        case .modified: return "修改文件"
        case .deleted: return "删除文件"
        }
    }
    
    private static func isFileMutationTitle(_ title: String) -> Bool {
        title == "修改文件" || title == "写入文件" || title == "新增文件" || title == "删除文件"
    }
    
    private static func normalizedResource(_ value: String) -> String {
        value.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
    }
    
    private static func compactOptional(_ value: String?, limit: Int = 240) -> String? {
        guard let value else { return nil }
        let compacted = compact(value, limit: limit)
        return compacted.isEmpty ? nil : compacted
    }
    
    private static func compact(_ value: String, limit: Int) -> String {
        let compacted = value
            .replacingOccurrences(of: "\r", with: "")
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        guard compacted.count > limit else { return compacted }
        return String(compacted.prefix(max(0, limit - 1))) + "…"
    }
    
    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return max(0, lhs ?? 0) + max(0, rhs ?? 0)
    }
}
