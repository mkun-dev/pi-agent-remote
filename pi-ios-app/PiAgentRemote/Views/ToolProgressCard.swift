import SwiftUI

// MARK: - ToolGroup（工作过程，不作为聊天主体）

struct ToolProgressCard: View {
    let content: String
    var toolEntries: [ToolEntry] = []
    let groupStatus: ToolGroupStatus
    let presentation: ToolGroupState
    let onToggle: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    /// 兼容旧会话：没有结构化 toolEntries 时从历史文本恢复条目。
    private var entries: [ToolEntry] {
        if !toolEntries.isEmpty { return toolEntries }
        
        var result: [ToolEntry] = []
        for line in content.components(separatedBy: "\n") where line.hasPrefix("▶") {
            let rest = line.dropFirst(2).trimmingCharacters(in: .whitespaces)
            let parts = rest.split(separator: ":", maxSplits: 1)
            result.append(ToolEntry(
                toolCallId: "",
                toolName: String(parts.first ?? "tool"),
                detail: parts.count > 1 ? String(parts[1]).trimmingCharacters(in: .whitespaces) : "",
                status: presentation == .working ? .running : .done
            ))
        }
        
        if result.isEmpty {
            let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                let parts = trimmed.split(separator: " ", maxSplits: 1)
                result.append(ToolEntry(
                    toolCallId: "",
                    toolName: parts.first.map(String.init) ?? "tool",
                    detail: parts.count > 1 ? String(parts[1]) : "",
                    status: presentation == .working ? .running : .done
                ))
            }
        }
        return result
    }
    
    private var isExpanded: Bool {
        presentation != .collapsed
    }
    
    private var operationCount: Int {
        entries.count
    }
    
    private var errorCount: Int {
        entries.filter { $0.status == .error }.count
    }
    
    private var effectiveStatus: ToolGroupStatus {
        if entries.contains(where: { $0.status == .running }) { return .running }
        if entries.contains(where: { $0.status == .error }) { return .failed }
        return groupStatus
    }
    
    private var summaryTitle: String {
        switch effectiveStatus {
        case .running:
            return "执行过程 · \(operationCount) 个操作"
        case .completed:
            return "已执行 \(operationCount) 个操作"
        case .failed:
            return "已执行 \(operationCount) 个操作 · \(errorCount) 个失败"
        }
    }
    
    /// 折叠态分类摘要，例如“读取/查找 3 · 修改 2 · 命令 1”。
    private var categorySummary: String {
        var counts: [ToolCategory: Int] = [:]
        for entry in entries {
            counts[ToolPresentation.resolve(name: entry.toolName, input: entry.detail).category, default: 0] += 1
        }
        let ordered: [(ToolCategory, String)] = [
            (.read, "读取/查找"),
            (.modify, "修改"),
            (.command, "命令"),
            (.other, "其他")
        ]
        return ordered.compactMap { category, label in
            guard let count = counts[category], count > 0 else { return nil }
            return "\(label) \(count)"
        }.joined(separator: " · ")
    }
    
    private func statusDescription(_ status: ToolStatus) -> String {
        switch status {
        case .running: return "执行中"
        case .done: return "已完成"
        case .error: return "执行失败"
        }
    }
    
    @ViewBuilder
    private func summaryIcon() -> some View {
        switch effectiveStatus {
        case .running:
            Image(systemName: "list.bullet.rectangle")
                .foregroundStyle(PiDesignSystem.Color.thinking)
        case .completed:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(PiDesignSystem.Color.completed)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(PiDesignSystem.Color.failed)
        }
    }
    
    @ViewBuilder
    private func statusIcon(for status: ToolStatus) -> some View {
        switch status {
        case .running:
            if reduceMotion {
                Image(systemName: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(PiDesignSystem.Color.thinking)
            } else {
                ProgressView()
                    .scaleEffect(0.62)
                    .tint(PiDesignSystem.Color.thinking)
            }
        case .done:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(PiDesignSystem.Color.completed)
        case .error:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(PiDesignSystem.Color.failed)
        }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.8)) {
                    onToggle()
                }
            } label: {
                HStack(spacing: 9) {
                    summaryIcon()
                        .frame(width: 18, height: 18)
                    
                    Text(summaryTitle)
                        .font(PiDesignSystem.Font.subheadline)
                        .foregroundStyle(PiDesignSystem.Color.primary)
                        .multilineTextAlignment(.leading)
                    
                    Spacer(minLength: 8)
                    
                    Text(isExpanded ? "收起" : "查看过程")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                    Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                        .font(PiDesignSystem.Font.captionBold)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(summaryTitle)
            .accessibilityHint(isExpanded ? "点按收起执行过程" : "点按查看执行过程")
            
            if isExpanded {
                Divider()
                    .overlay(PiDesignSystem.Color.divider)
                    .padding(.horizontal, 12)
                
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(entries.enumerated()), id: \.offset) { _, entry in
                        let visual = ToolPresentation.resolve(name: entry.toolName, input: entry.detail)
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: visual.systemImage)
                                .font(PiDesignSystem.Font.caption)
                                .foregroundStyle(PiDesignSystem.Color.secondary)
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                            
                            VStack(alignment: .leading, spacing: 2) {
                                Text(visual.displayName)
                                    .font(PiDesignSystem.Font.caption)
                                    .foregroundStyle(entry.status == .error ? PiDesignSystem.Color.failed : PiDesignSystem.Color.primary)
                                
                                if !entry.detail.isEmpty {
                                    Text(entry.detail)
                                        .font(PiDesignSystem.Font.monoDigit)
                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                        .lineLimit(2)
                                        .multilineTextAlignment(.leading)
                                }
                            }
                            
                            Spacer(minLength: 4)
                            statusIcon(for: entry.status)
                                .frame(width: 18, height: 18)
                                .accessibilityHidden(true)
                        }
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(
                            "\(visual.displayName)，\(statusDescription(entry.status))" +
                            (entry.detail.isEmpty ? "" : "，\(entry.detail)")
                        )
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 11)
                .transition(.opacity.combined(with: .move(edge: .top)))
            } else if !categorySummary.isEmpty {
                Text(categorySummary)
                    .font(PiDesignSystem.Font.caption)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
                    .transition(.opacity)
            }
        }
        .piCard()
        .animation(reduceMotion ? nil : PiDesignSystem.Animation.default, value: presentation)
        .animation(reduceMotion ? nil : PiDesignSystem.Animation.quick, value: effectiveStatus)
    }
}
