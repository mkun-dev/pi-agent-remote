import SwiftUI
import UIKit

struct CodeBlockView: View {
    let code: String
    let language: String?
    
    @State private var isExpanded = false
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private let profile: CodeLanguageProfile
    private let lines: [String]
    private let collapsedLineLimit = 100
    
    init(code: String, language: String?) {
        self.code = code
        self.language = language
        self.profile = codeLanguageProfile(for: language)
        var parsedLines = code.replacingOccurrences(of: "\r\n", with: "\n")
            .components(separatedBy: "\n")
        if parsedLines.last == "" { parsedLines.removeLast() }
        self.lines = parsedLines
    }
    
    private var shouldCollapse: Bool {
        lines.count > collapsedLineLimit
    }
    
    /// 当 language 标签形如文件路径时（如 "src/auth.swift"），识别为文件胶囊标题。
    private var detectedFilePath: String? {
        guard let lang = language, !lang.isEmpty else { return nil }
        let known = Set(["swift", "typescript", "javascript", "js", "python", "py",
                         "json", "bash", "sh", "shell", "zsh", "markdown", "md",
                         "yaml", "yml", "xml", "html", "css", "sql", "ruby", "go",
                         "rust", "java", "kotlin", "c", "cpp", "objc"])
        if known.contains(lang.lowercased()) { return nil }
        // 含有路径特征 → 视为文件路径
        if lang.contains("/") || lang.contains(".") {
            return lang
        }
        return nil
    }
    
    private var displayedCode: String {
        if shouldCollapse && !isExpanded {
            return lines.prefix(collapsedLineLimit).joined(separator: "\n")
        }
        return code
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            codeBody
            if shouldCollapse {
                expandButton
            }
        }
        .background(PiDesignSystem.Color.surface)
        .clipShape(RoundedRectangle(cornerRadius: PiDesignSystem.Radius.lg, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: PiDesignSystem.Radius.lg, style: .continuous)
                .stroke(PiDesignSystem.Color.border, lineWidth: 1)
        }
    }
    
    private var header: some View {
        HStack(spacing: 8) {
            // 文件路径检测：language 形如 "src/auth.swift" → 文件胶囊
            if let filePath = detectedFilePath {
                HStack(spacing: 4) {
                    Image(systemName: "doc.text")
                        .font(.system(size: 10))
                    Text(filePath)
                        .lineLimit(1)
                }
                .font(.caption.weight(.medium).monospaced())
                .foregroundStyle(.indigo)
            } else {
                Text(profile.displayName)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(.secondary)
            }
            if !lines.isEmpty {
                Text("\(lines.count) 行")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)
            Button(action: copyCode) {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(copied ? Color.green : Color.accentColor)
                    .frame(minHeight: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(copied ? "代码已复制" : "复制代码")
            .accessibilityHint("将完整代码复制到剪贴板")
        }
        .padding(.leading, 12)
        .padding(.trailing, 10)
        .background(Color(uiColor: .tertiarySystemBackground))
        .overlay(alignment: .bottom) { Divider() }
    }
    
    private var codeBody: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            Text(highlightCode(displayedCode, languageID: profile.id))
                .font(.system(.caption, design: .monospaced))
                .lineSpacing(3)
                .fixedSize(horizontal: true, vertical: true)
                .textSelection(.enabled)
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(PiDesignSystem.Color.codeBg)
        .accessibilityLabel("\(profile.displayName)代码，共 \(lines.count) 行")
    }
    
    private var expandButton: some View {
        Button {
            isExpanded.toggle()
        } label: {
            Label(
                isExpanded ? "收起代码" : "查看完整代码（\(lines.count) 行）",
                systemImage: isExpanded ? "chevron.up" : "chevron.down"
            )
            .font(.caption.weight(.semibold))
            .frame(maxWidth: .infinity, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(Color.accentColor)
        .background(Color(uiColor: .tertiarySystemBackground))
        .overlay(alignment: .top) { Divider() }
        .accessibilityValue(isExpanded ? "已展开" : "已折叠")
    }
    
    private func copyCode() {
        UIPasteboard.general.string = code
        UINotificationFeedbackGenerator().notificationOccurred(.success)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if reduceMotion {
                copied = false
            } else {
                withAnimation(.easeOut(duration: 0.2)) {
                    copied = false
                }
            }
        }
    }
}

// MARK: - Language profiles

private struct CodeLanguageProfile {
    let id: String
    let displayName: String
    let keywords: Set<String>
    let lineComments: [String]
    let blockComment: (start: String, end: String)?
    let supportsBacktickStrings: Bool
}

private func codeLanguageProfile(for rawLanguage: String?) -> CodeLanguageProfile {
    let language = rawLanguage?
        .lowercased()
        .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    
    switch language {
    case "swift":
        return CodeLanguageProfile(
            id: "swift", displayName: "Swift",
            keywords: swiftKeywords,
            lineComments: ["//"], blockComment: ("/*", "*/"), supportsBacktickStrings: false
        )
    case "ts", "typescript", "tsx":
        return CodeLanguageProfile(
            id: "typescript", displayName: "TypeScript",
            keywords: typeScriptKeywords,
            lineComments: ["//"], blockComment: ("/*", "*/"), supportsBacktickStrings: true
        )
    case "js", "javascript", "jsx", "node":
        return CodeLanguageProfile(
            id: "javascript", displayName: "JavaScript",
            keywords: javaScriptKeywords,
            lineComments: ["//"], blockComment: ("/*", "*/"), supportsBacktickStrings: true
        )
    case "py", "python":
        return CodeLanguageProfile(
            id: "python", displayName: "Python",
            keywords: pythonKeywords,
            lineComments: ["#"], blockComment: nil, supportsBacktickStrings: false
        )
    case "json", "jsonc":
        return CodeLanguageProfile(
            id: "json", displayName: "JSON",
            keywords: ["true", "false", "null"],
            lineComments: language == "jsonc" ? ["//"] : [],
            blockComment: language == "jsonc" ? ("/*", "*/") : nil,
            supportsBacktickStrings: false
        )
    case "bash", "sh", "shell", "zsh":
        return CodeLanguageProfile(
            id: "bash", displayName: "Bash",
            keywords: bashKeywords,
            lineComments: ["#"], blockComment: nil, supportsBacktickStrings: true
        )
    case "md", "markdown":
        return CodeLanguageProfile(
            id: "markdown", displayName: "Markdown",
            keywords: [], lineComments: [], blockComment: nil, supportsBacktickStrings: true
        )
    default:
        return CodeLanguageProfile(
            id: language.isEmpty ? "code" : language,
            displayName: language.isEmpty ? "代码" : language.uppercased(),
            keywords: [], lineComments: ["//"], blockComment: ("/*", "*/"), supportsBacktickStrings: true
        )
    }
}

private let swiftKeywords: Set<String> = [
    "actor", "any", "as", "associatedtype", "async", "await", "break", "case", "catch",
    "class", "continue", "convenience", "default", "defer", "deinit", "do", "else", "enum",
    "extension", "fallthrough", "false", "fileprivate", "final", "for", "func", "get", "guard",
    "if", "import", "in", "indirect", "init", "inout", "internal", "is", "isolated", "lazy",
    "let", "macro", "mutating", "nil", "nonisolated", "open", "operator", "override", "private",
    "protocol", "public", "repeat", "required", "return", "self", "set", "some", "static",
    "struct", "subscript", "super", "switch", "throw", "throws", "true", "try", "typealias",
    "var", "weak", "where", "while"
]

private let typeScriptKeywords: Set<String> = [
    "abstract", "any", "as", "asserts", "async", "await", "boolean", "break", "case", "catch",
    "class", "const", "constructor", "continue", "declare", "default", "delete", "do", "else",
    "enum", "export", "extends", "false", "finally", "for", "from", "function", "get", "if",
    "implements", "import", "in", "infer", "instanceof", "interface", "is", "keyof", "let",
    "module", "namespace", "never", "new", "null", "number", "object", "of", "private",
    "protected", "public", "readonly", "return", "satisfies", "set", "static", "string", "super",
    "switch", "symbol", "this", "throw", "true", "try", "type", "typeof", "undefined", "unknown",
    "var", "void", "while", "with", "yield"
]

private let javaScriptKeywords: Set<String> = [
    "async", "await", "break", "case", "catch", "class", "const", "continue", "debugger",
    "default", "delete", "do", "else", "export", "extends", "false", "finally", "for", "from",
    "function", "get", "if", "import", "in", "instanceof", "let", "new", "null", "of", "return",
    "set", "static", "super", "switch", "this", "throw", "true", "try", "typeof", "undefined",
    "var", "void", "while", "with", "yield"
]

private let pythonKeywords: Set<String> = [
    "and", "as", "assert", "async", "await", "break", "case", "class", "continue", "def", "del",
    "elif", "else", "except", "False", "finally", "for", "from", "global", "if", "import", "in",
    "is", "lambda", "match", "None", "nonlocal", "not", "or", "pass", "raise", "return", "True",
    "try", "while", "with", "yield"
]

private let bashKeywords: Set<String> = [
    "case", "do", "done", "elif", "else", "esac", "fi", "for", "function", "if", "in", "select",
    "then", "time", "until", "while"
]

// MARK: - Lightweight syntax highlighter

private final class HighlightedCodeBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private let highlightedCodeCache: NSCache<NSString, HighlightedCodeBox> = {
    let cache = NSCache<NSString, HighlightedCodeBox>()
    cache.countLimit = 300
    cache.totalCostLimit = 4 * 1024 * 1024
    return cache
}()

func highlightCode(_ code: String, languageID: String) -> AttributedString {
    let key = "\(languageID)\u{0}\(code)" as NSString
    if let cached = highlightedCodeCache.object(forKey: key) {
        return cached.value
    }
    let profile = codeLanguageProfile(for: languageID)
    let value = highlightCodeRaw(code, profile: profile)
    if code.utf8.count <= 100_000 {
        highlightedCodeCache.setObject(
            HighlightedCodeBox(value),
            forKey: key,
            cost: max(code.utf8.count, 1)
        )
    }
    return value
}

private func highlightCodeRaw(_ code: String, profile: CodeLanguageProfile) -> AttributedString {
    var output = AttributedString()
    var index = code.startIndex
    
    func append(_ value: String, color: Color) {
        var token = AttributedString(value)
        token.foregroundColor = color
        output += token
    }
    
    while index < code.endIndex {
        let character = code[index]
        
        // Markdown 标题
        let isLineStart = index == code.startIndex || code[code.index(before: index)] == "\n"
        if profile.id == "markdown", isLineStart, character == "#" {
            var end = index
            while end < code.endIndex, code[end] != "\n" {
                end = code.index(after: end)
            }
            append(String(code[index..<end]), color: .blue)
            index = end
            continue
        }
        
        // 行注释
        if let marker = profile.lineComments.first(where: { code[index...].hasPrefix($0) }) {
            var end = code.index(index, offsetBy: marker.count)
            while end < code.endIndex, code[end] != "\n" {
                end = code.index(after: end)
            }
            append(String(code[index..<end]), color: .secondary)
            index = end
            continue
        }
        
        // 块注释
        if let block = profile.blockComment, code[index...].hasPrefix(block.start) {
            let contentStart = code.index(index, offsetBy: block.start.count)
            let end = code.range(of: block.end, range: contentStart..<code.endIndex)?.upperBound ?? code.endIndex
            append(String(code[index..<end]), color: .secondary)
            index = end
            continue
        }
        
        // 字符串
        if character == "\"" || character == "'" || (character == "`" && profile.supportsBacktickStrings) {
            let quote = character
            var end = code.index(after: index)
            while end < code.endIndex {
                if code[end] == "\\" {
                    end = code.index(end, offsetBy: 2, limitedBy: code.endIndex) ?? code.endIndex
                    continue
                }
                if code[end] == quote {
                    end = code.index(after: end)
                    break
                }
                end = code.index(after: end)
            }
            append(String(code[index..<end]), color: .green)
            index = end
            continue
        }
        
        // Bash 变量
        if profile.id == "bash", character == "$" {
            var end = code.index(after: index)
            if end < code.endIndex, code[end] == "{" {
                end = code.index(after: end)
                while end < code.endIndex, code[end] != "}" {
                    end = code.index(after: end)
                }
                if end < code.endIndex { end = code.index(after: end) }
            } else {
                while end < code.endIndex, code[end].isLetter || code[end].isNumber || code[end] == "_" {
                    end = code.index(after: end)
                }
            }
            append(String(code[index..<end]), color: .cyan)
            index = end
            continue
        }
        
        // 关键词 / 标识符
        if character.isLetter || character == "_" {
            var end = code.index(after: index)
            while end < code.endIndex, code[end].isLetter || code[end].isNumber || code[end] == "_" {
                end = code.index(after: end)
            }
            let word = String(code[index..<end])
            append(word, color: profile.keywords.contains(word) ? .purple : .primary)
            index = end
            continue
        }
        
        // 数字
        if character.isNumber {
            var end = code.index(after: index)
            let numericCharacters = CharacterSet(charactersIn: "0123456789abcdefABCDEFxX._")
            while end < code.endIndex,
                  String(code[end]).unicodeScalars.allSatisfy({ numericCharacters.contains($0) }) {
                end = code.index(after: end)
            }
            append(String(code[index..<end]), color: .orange)
            index = end
            continue
        }
        
        append(String(character), color: .primary)
        index = code.index(after: index)
    }
    
    return output
}
