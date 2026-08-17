import Foundation
import SwiftUI

// MARK: - Parsed document

struct MarkdownDocument: Equatable {
    let elements: [MarkdownElement]
}

enum MarkdownElement: Hashable {
    case heading(Int, String)
    case paragraph(String)
    case listItem(number: Int?, text: String, indent: Int)
    case taskItem(done: Bool, text: String)
    case quote(String)
    case table([[String]])
    case divider
    case code(String, String?)
}

/// 完整 Markdown 文档缓存。messageID 稳定时 SwiftUI 重绘只做 O(1) 查询。
final class MarkdownDocumentCache {
    static let shared = MarkdownDocumentCache()
    
    private final class Box: NSObject {
        let source: String
        let document: MarkdownDocument
        init(source: String, document: MarkdownDocument) {
            self.source = source
            self.document = document
        }
    }
    
    private let cache = NSCache<NSString, Box>()
    
    private init() {
        cache.countLimit = 200
        cache.totalCostLimit = 4 * 1024 * 1024
    }
    
    func document(messageID: String, markdown: String) -> MarkdownDocument {
        let key = messageID as NSString
        if let cached = cache.object(forKey: key), cached.source == markdown {
            return cached.document
        }
        let document = parseMarkdownDocument(markdown)
        cache.setObject(
            Box(source: markdown, document: document),
            forKey: key,
            cost: min(markdown.utf8.count, 256 * 1024)
        )
        return document
    }
}

// MARK: - Fenced code parsing

private struct MarkdownFence {
    let marker: Character
    let length: Int
    let language: String?
}

func parseMarkdownDocument(_ markdown: String) -> MarkdownDocument {
    let lines = markdown.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
    var elements: [MarkdownElement] = []
    var textLines: [String] = []
    var codeLines: [String] = []
    var activeFence: MarkdownFence?
    
    func flushText() {
        guard !textLines.isEmpty else { return }
        elements.append(contentsOf: parseMarkdownBlocks(textLines))
        textLines.removeAll(keepingCapacity: true)
    }
    
    for line in lines {
        if let fence = activeFence {
            if isClosingFence(line, matching: fence) {
                elements.append(.code(codeLines.joined(separator: "\n"), fence.language))
                codeLines.removeAll(keepingCapacity: true)
                activeFence = nil
            } else {
                codeLines.append(line)
            }
        } else if let fence = openingFence(line) {
            flushText()
            activeFence = fence
        } else {
            textLines.append(line)
        }
    }
    
    if let fence = activeFence {
        // assistant.end 偶尔可能收到未闭合 fence；仍按代码展示，避免丢失内容。
        elements.append(.code(codeLines.joined(separator: "\n"), fence.language))
    } else {
        flushText()
    }
    return MarkdownDocument(elements: elements)
}

private func openingFence(_ line: String) -> MarkdownFence? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    guard let marker = trimmed.first, marker == "`" || marker == "~" else { return nil }
    let count = trimmed.prefix { $0 == marker }.count
    guard count >= 3 else { return nil }
    let remainder = String(trimmed.dropFirst(count)).trimmingCharacters(in: .whitespaces)
    let rawLanguage = remainder.split(whereSeparator: { $0.isWhitespace }).first.map(String.init)
    let language = rawLanguage?
        .trimmingCharacters(in: CharacterSet(charactersIn: "{}"))
        .replacingOccurrences(of: ".", with: "")
    return MarkdownFence(marker: marker, length: count, language: language?.isEmpty == false ? language : nil)
}

private func isClosingFence(_ line: String, matching fence: MarkdownFence) -> Bool {
    let trimmed = line.trimmingCharacters(in: .whitespaces)
    let markerCount = trimmed.prefix { $0 == fence.marker }.count
    guard markerCount >= fence.length else { return false }
    return String(trimmed.dropFirst(markerCount)).trimmingCharacters(in: .whitespaces).isEmpty
}

// MARK: - Block parsing

private func parseMarkdownBlocks(_ lines: [String]) -> [MarkdownElement] {
    var result: [MarkdownElement] = []
    var paragraph: [String] = []
    var index = 0
    
    func flushParagraph() {
        guard !paragraph.isEmpty else { return }
        result.append(.paragraph(paragraph.joined(separator: "\n")))
        paragraph.removeAll(keepingCapacity: true)
    }
    
    while index < lines.count {
        let raw = lines[index]
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        
        if trimmed.isEmpty {
            flushParagraph()
            index += 1
            continue
        }
        
        if let heading = parseHeading(trimmed) {
            flushParagraph()
            result.append(.heading(heading.level, heading.text))
            index += 1
            continue
        }
        
        if isHorizontalDivider(trimmed) {
            flushParagraph()
            result.append(.divider)
            index += 1
            continue
        }
        
        if index + 1 < lines.count,
           trimmed.contains("|"),
           isTableDivider(lines[index + 1]) {
            flushParagraph()
            var rows = [parseTableRow(trimmed)]
            index += 2 // 跳过表头分隔行
            while index < lines.count {
                let row = lines[index].trimmingCharacters(in: .whitespaces)
                guard !row.isEmpty, row.contains("|") else { break }
                rows.append(parseTableRow(row))
                index += 1
            }
            result.append(.table(rows))
            continue
        }
        
        if let task = parseTaskItem(trimmed) {
            flushParagraph()
            result.append(.taskItem(done: task.done, text: task.text))
            index += 1
            continue
        }
        
        if let item = parseListItem(raw) {
            flushParagraph()
            result.append(.listItem(number: item.number, text: item.text, indent: item.indent))
            index += 1
            continue
        }
        
        if trimmed.hasPrefix(">") {
            flushParagraph()
            var quoteLines: [String] = []
            while index < lines.count {
                let quote = lines[index].trimmingCharacters(in: .whitespaces)
                guard quote.hasPrefix(">") else { break }
                quoteLines.append(String(quote.dropFirst()).trimmingCharacters(in: .whitespaces))
                index += 1
            }
            result.append(.quote(quoteLines.joined(separator: "\n")))
            continue
        }
        
        paragraph.append(trimmed)
        index += 1
    }
    
    flushParagraph()
    return result
}

private func parseHeading(_ line: String) -> (level: Int, text: String)? {
    let level = line.prefix { $0 == "#" }.count
    guard (1...6).contains(level), line.count > level else { return nil }
    let contentStart = line.index(line.startIndex, offsetBy: level)
    guard line[contentStart].isWhitespace else { return nil }
    let text = String(line[contentStart...]).trimmingCharacters(in: .whitespaces)
    return text.isEmpty ? nil : (level, text)
}

private func isHorizontalDivider(_ line: String) -> Bool {
    let compact = line.replacingOccurrences(of: " ", with: "")
    guard compact.count >= 3, let marker = compact.first,
          marker == "-" || marker == "*" || marker == "_" else { return false }
    return compact.allSatisfy { $0 == marker }
}

func parseTableRow(_ line: String) -> [String] {
    var value = line.trimmingCharacters(in: .whitespaces)
    if value.hasPrefix("|") { value.removeFirst() }
    if value.hasSuffix("|") { value.removeLast() }
    return value.split(separator: "|", omittingEmptySubsequences: false).map {
        $0.trimmingCharacters(in: .whitespaces)
    }
}

func isTableDivider(_ line: String) -> Bool {
    let cells = parseTableRow(line)
    guard cells.count >= 2 else { return false }
    return cells.allSatisfy { cell in
        let value = cell.replacingOccurrences(of: ":", with: "")
        return !value.isEmpty && value.allSatisfy { $0 == "-" }
    }
}

private func parseTaskItem(_ line: String) -> (done: Bool, text: String)? {
    let lower = line.lowercased()
    guard lower.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ") else { return nil }
    return (lower.hasPrefix("- [x] "), String(line.dropFirst(6)))
}

private func parseListItem(_ raw: String) -> (number: Int?, text: String, indent: Int)? {
    let leadingSpaces = raw.prefix { $0 == " " || $0 == "\t" }.reduce(0) { count, character in
        count + (character == "\t" ? 2 : 1)
    }
    let indent = leadingSpaces / 2
    let line = raw.trimmingCharacters(in: .whitespaces)
    
    for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
        return (nil, String(line.dropFirst(marker.count)), indent)
    }
    
    guard let dot = line.firstIndex(of: "."), dot != line.startIndex else { return nil }
    let numberText = line[..<dot]
    guard numberText.allSatisfy({ $0.isNumber }) else { return nil }
    let afterDot = line.index(after: dot)
    guard afterDot < line.endIndex, line[afterDot].isWhitespace else { return nil }
    let text = String(line[afterDot...]).trimmingCharacters(in: .whitespaces)
    guard !text.isEmpty else { return nil }
    return (Int(numberText), text, indent)
}

// MARK: - Inline Markdown

private final class AttributedMarkdownBox: NSObject {
    let value: AttributedString
    init(_ value: AttributedString) { self.value = value }
}

private let inlineMarkdownCache: NSCache<NSString, AttributedMarkdownBox> = {
    let cache = NSCache<NSString, AttributedMarkdownBox>()
    cache.countLimit = 1_000
    cache.totalCostLimit = 2 * 1024 * 1024
    return cache
}()

/// 粗体、斜体、行内代码和链接由 Foundation AttributedString 原生解析。
func parseInlineMarkdown(_ text: String) -> AttributedString {
    let key = text as NSString
    if let cached = inlineMarkdownCache.object(forKey: key) {
        return cached.value
    }
    
    var options = AttributedString.MarkdownParsingOptions()
    options.interpretedSyntax = .inlineOnlyPreservingWhitespace
    var result = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
    
    let codeRanges = result.runs.compactMap { run -> Range<AttributedString.Index>? in
        guard run.inlinePresentationIntent?.contains(.code) == true else { return nil }
        return run.range
    }
    for range in codeRanges {
        result[range].font = .system(.subheadline, design: .monospaced)
        result[range].foregroundColor = PiDesignSystem.Color.accent
        result[range].backgroundColor = PiDesignSystem.Color.secondary.opacity(0.12)
    }
    
    inlineMarkdownCache.setObject(
        AttributedMarkdownBox(result),
        forKey: key,
        cost: min(text.utf8.count, 32 * 1024)
    )
    return result
}
