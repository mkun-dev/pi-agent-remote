import Foundation

/// Tool 的唯一展示规则。Trace、Activity、Logs 和 Tool 卡片都从这里获取名称与分类。
enum ToolCategory: Hashable {
    case read
    case modify
    case command
    case other
}

enum ToolSemantic: Equatable {
    case readFile
    case search
    case find
    case list
    case editFile
    case writeFile
    case command
    case test
    case agent
    case question
    case todo
    case sendToIOS
    case sendImageToIOS
    case other
}

struct ToolPresentation: Equatable {
    let canonicalName: String
    let displayName: String
    let systemImage: String
    let category: ToolCategory
    let semantic: ToolSemantic
    
    var isShell: Bool { semantic == .command || semantic == .test }
    var isFileMutation: Bool { semantic == .editFile || semantic == .writeFile }
    
    static func resolve(name rawName: String, input: String = "") -> ToolPresentation {
        let name = canonicalName(rawName)
        switch name {
        case "read", "read_file":
            return value(name, "读取文件", "doc.text", .read, .readFile)
        case "grep":
            return value(name, "搜索内容", "magnifyingglass", .read, .search)
        case "find", "glob":
            return value(name, "查找文件", "folder", .read, .find)
        case "ls":
            return value(name, "列出目录", "folder", .read, .list)
        case "edit", "edit_file":
            return value(name, "修改文件", "pencil", .modify, .editFile)
        case "write", "write_file":
            return value(name, "写入文件", "square.and.pencil", .modify, .writeFile)
        case "bash", "shell":
            return isTestCommand(input)
                ? value(name, "执行测试", "checkmark.seal", .command, .test)
                : value(name, "执行命令", "terminal", .command, .command)
        case "agent":
            return value(name, "运行子代理", "person.2", .other, .agent)
        case "ask_user_question":
            return value(name, "等待用户回答", "questionmark.bubble", .other, .question)
        case "todo":
            return value(name, "更新任务", "checklist", .other, .todo)
        case "send_to_ios":
            return value(name, "发送到 iPhone", "iphone", .other, .sendToIOS)
        case "send_image_to_ios":
            return value(name, "发送图片", "photo", .other, .sendImageToIOS)
        default:
            return value(name, rawName.isEmpty ? "工具操作" : rawName, "gearshape", .other, .other)
        }
    }
    
    static func canonicalName(_ rawName: String) -> String {
        rawName.split(separator: ".").last.map(String.init)?.lowercased() ?? rawName.lowercased()
    }
    
    private static func value(
        _ canonicalName: String,
        _ displayName: String,
        _ systemImage: String,
        _ category: ToolCategory,
        _ semantic: ToolSemantic
    ) -> ToolPresentation {
        ToolPresentation(
            canonicalName: canonicalName,
            displayName: displayName,
            systemImage: systemImage,
            category: category,
            semantic: semantic
        )
    }
    
    private static func isTestCommand(_ command: String) -> Bool {
        let value = command.lowercased()
        return [
            "npm test", "npm run test", "pnpm test", "yarn test", "bun test",
            "pytest", "swift test", "xcodebuild", "vitest", "jest", "cargo test", "go test"
        ].contains { value.contains($0) }
    }
}
