import SwiftUI

/// Assistant 完成态 Markdown 渲染器。
/// Streaming 阶段不创建此 View；assistant.end 后按 messageID 缓存完整解析结果。
struct MarkdownContent: View {
    let messageID: String
    let markdown: String
    
    private var document: MarkdownDocument {
        MarkdownDocumentCache.shared.document(messageID: messageID, markdown: markdown)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(document.elements.enumerated()), id: \.offset) { _, element in
                MarkdownElementView(element: element)
            }
        }
        .accessibilityElement(children: .contain)
    }
}

private struct MarkdownElementView: View {
    let element: MarkdownElement
    
    @ViewBuilder
    var body: some View {
        switch element {
        case .heading(let level, let text):
            Text(parseInlineMarkdown(text))
                .font(headingFont(level))
                .foregroundStyle(.primary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, level <= 2 ? 4 : 2)
                .accessibilityAddTraits(.isHeader)
        
        case .paragraph(let text):
            InlineMarkdownText(text)
        
        case .listItem(let number, let text, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(number.map { "\($0)." } ?? "•")
                    .font(.body.weight(number == nil ? .bold : .regular))
                    .foregroundStyle(.secondary)
                    .frame(minWidth: number == nil ? 10 : 24, alignment: .trailing)
                    .accessibilityHidden(true)
                InlineMarkdownText(text)
            }
            .padding(.leading, CGFloat(min(indent, 4) * 16))
            .accessibilityElement(children: .combine)
            .accessibilityLabel(number.map { "第 \($0) 项，\(text)" } ?? "列表项，\(text)")
        
        case .taskItem(let done, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: done ? "checkmark.square.fill" : "square")
                    .font(.body)
                    .foregroundStyle(done ? Color.green : Color.secondary)
                    .accessibilityHidden(true)
                InlineMarkdownText(text)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("\(done ? "已完成" : "未完成")，\(text)")
        
        case .quote(let text):
            HStack(alignment: .top, spacing: 10) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor.opacity(0.7))
                    .frame(width: 3)
                    .accessibilityHidden(true)
                InlineMarkdownText(text)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .accessibilityElement(children: .combine)
            .accessibilityLabel("引用，\(text)")
        
        case .table(let rows):
            MarkdownTableView(rows: rows)
        
        case .divider:
            Divider().padding(.vertical, 2)
        
        case .code(let code, let language):
            CodeBlockView(code: code, language: language)
        }
    }
    
    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title2.bold()
        case 2: return .title3.bold()
        case 3: return .headline.bold()
        case 4: return .subheadline.bold()
        default: return .subheadline.weight(.semibold)
        }
    }
}

struct InlineMarkdownText: View {
    let text: String
    
    init(_ text: String) {
        self.text = text
    }
    
    var body: some View {
        Text(parseInlineMarkdown(text))
            .font(.body)
            .lineSpacing(3)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }
}

private struct MarkdownTableView: View {
    let rows: [[String]]
    
    private var columnCount: Int {
        max(rows.map(\.count).max() ?? 0, 1)
    }
    
    var body: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(rows.indices, id: \.self) { rowIndex in
                    HStack(alignment: .top, spacing: 0) {
                        ForEach(0..<columnCount, id: \.self) { columnIndex in
                            let value = columnIndex < rows[rowIndex].count ? rows[rowIndex][columnIndex] : ""
                            Text(parseInlineMarkdown(value))
                                .font(rowIndex == 0 ? .caption.weight(.semibold) : .caption)
                                .foregroundStyle(rowIndex == 0 ? Color.primary : Color.secondary)
                                .lineSpacing(2)
                                .frame(width: 120, alignment: .leading)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 8)
                                .fixedSize(horizontal: false, vertical: true)
                                .overlay(alignment: .trailing) {
                                    if columnIndex < columnCount - 1 {
                                        Divider()
                                    }
                                }
                        }
                    }
                    .background(rowIndex == 0 ? Color.accentColor.opacity(0.09) : Color.clear)
                    .overlay(alignment: .bottom) {
                        if rowIndex < rows.count - 1 {
                            Divider()
                        }
                    }
                }
            }
            .background(Color(uiColor: .tertiarySystemBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("表格，共 \(rows.count) 行，\(columnCount) 列")
    }
}
