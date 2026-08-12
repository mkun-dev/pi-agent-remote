import Foundation

/// 文件变化类型（协议 created 在客户端映射为 added）。
enum FileChangeType: String, Equatable {
    case added
    case modified
    case deleted
}

/// 单个文件变化摘要。第一阶段只同步路径、类型和行数统计，不传输完整 diff。
struct FileChange: Identifiable, Equatable {
    let path: String
    var type: FileChangeType
    var additions: Int?
    var deletions: Int?
    /// 可选：真实 diff 内容（协议扩展后可用）
    var diffHunks: [DiffHunk]? = nil
    
    var id: String { normalizedPath }
    
    var normalizedPath: String {
        path.replacingOccurrences(of: "\\", with: "/")
    }
    
    var fileName: String {
        (normalizedPath as NSString).lastPathComponent
    }
    
    var parentPath: String {
        let parent = (normalizedPath as NSString).deletingLastPathComponent
        return parent == "." ? "" : parent
    }
    
    /// 同一 Agent 回合反复修改同一文件时合并，保留语义并累计行数。
    func merging(_ newer: FileChange) -> FileChange {
        let mergedType: FileChangeType
        switch (type, newer.type) {
        case (.added, .modified), (.added, .added):
            mergedType = .added
        case (_, .deleted):
            mergedType = .deleted
        case (.deleted, .added):
            mergedType = .modified
        default:
            mergedType = newer.type
        }
        
        return FileChange(
            path: newer.path,
            type: mergedType,
            additions: Self.sum(additions, newer.additions),
            deletions: Self.sum(deletions, newer.deletions)
        )
    }
    
    private static func sum(_ lhs: Int?, _ rhs: Int?) -> Int? {
        guard lhs != nil || rhs != nil else { return nil }
        return max(0, lhs ?? 0) + max(0, rhs ?? 0)
    }
}

// MARK: - Diff Data Models

/// Diff 块：一组连续的同类型 diff 行
struct DiffHunk: Equatable {
    let oldStart: Int
    let newStart: Int
    let lines: [DiffLine]
}

/// 单行 diff 内容
struct DiffLine: Identifiable, Equatable {
    enum LineType: String, Equatable {
        case added
        case removed
        case context
    }
    
    var id: String { "\(type.rawValue)-\(oldLine ?? 0)-\(newLine ?? 0)-\(content.hashValue)" }
    let type: LineType
    let oldLine: Int?
    let newLine: Int?
    let content: String
}
