import SwiftUI

/// Assistant Message 内部的渐进披露区域；不创建独立页面或 Timeline。
struct AgentTraceView: View {
    @ObservedObject private var store: ConversationStore
    let onToggle: () -> Void
    
    init(store: ConversationStore, onToggle: @escaping () -> Void) {
        self.store = store
        self.onToggle = onToggle
    }
    
    private var trace: AgentTrace {
        store.currentTrace ?? AgentTrace()
    }
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private var hasFailure: Bool {
        trace.events.contains { $0.state == .failed }
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                if reduceMotion {
                    onToggle()
                } else {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        onToggle()
                    }
                }
            } label: {
                HStack(spacing: 9) {
                    traceStatusIcon
                        .frame(width: 18, height: 18)
                        .accessibilityHidden(true)
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text(trace.isComplete ? "查看执行过程" : "Pi 正在工作")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        Text("\(trace.operationCount) 个步骤")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    
                    Spacer(minLength: 8)
                    
                    Image(systemName: "chevron.right")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(trace.isExpanded ? 90 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: trace.isExpanded)
                        .accessibilityHidden(true)
                }
                .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                .padding(.horizontal, 12)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(trace.isComplete ? "查看执行过程" : "Pi 正在工作")
            .accessibilityValue("\(trace.operationCount) 个步骤，\(trace.isExpanded ? "已展开" : "已折叠")")
            .accessibilityHint(trace.isExpanded ? "点按收起执行过程" : "点按展开执行过程")
            
            if trace.isExpanded {
                Divider().padding(.horizontal, 12)
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(trace.events.enumerated()), id: \.offset) { index, event in
                        TraceEventRow(event: event)
                        if index < trace.events.count - 1 {
                            Divider().padding(.leading, 39)
                        }
                    }
                }
                .padding(.vertical, 4)
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .background(Color(uiColor: .tertiarySystemBackground).opacity(0.72))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.secondary.opacity(0.14), lineWidth: 1)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.22), value: trace.isExpanded)
    }
    
    @ViewBuilder
    private var traceStatusIcon: some View {
        if !trace.isComplete {
            if reduceMotion {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(Color.orange)
            } else {
                ProgressView()
                    .scaleEffect(0.7)
                    .tint(.orange)
            }
        } else if hasFailure {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(Color.red)
        } else {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.green)
        }
    }
}

private struct TraceEventRow: View {
    let event: TraceEvent
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: systemImage)
                .font(.caption.weight(.medium))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
                .padding(.top, 1)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(event.title)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(event.state == .failed ? Color.red : Color.primary)
                
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                        .multilineTextAlignment(.leading)
                        .textSelection(.enabled)
                }
                
                if event.additions != nil || event.deletions != nil {
                    HStack(spacing: 7) {
                        if let additions = event.additions {
                            Text("+\(additions)").foregroundStyle(.green)
                        }
                        if let deletions = event.deletions {
                            Text("−\(deletions)").foregroundStyle(.red)
                        }
                    }
                    .font(.caption2.monospacedDigit())
                }
            }
            
            Spacer(minLength: 6)
            eventStateIcon
                .frame(width: 18, height: 18)
                .accessibilityHidden(true)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }
    
    private var detailFont: Font {
        switch event.type {
        case .command, .fileChange:
            return .caption2.monospaced()
        default:
            return .caption
        }
    }
    
    private var systemImage: String {
        switch event.type {
        case .thinking:
            return "brain"
        case .command:
            return event.title == "执行测试" ? "checkmark.seal" : "terminal"
        case .fileChange:
            if event.title == "新增文件" { return "doc.badge.plus" }
            if event.title == "删除文件" { return "trash" }
            return "pencil"
        case .completed:
            return event.state == .failed ? "exclamationmark.circle" : "checkmark.circle"
        case .tool:
            if event.title.contains("读取") { return "doc.text" }
            if event.title.contains("搜索") || event.title.contains("查找") { return "magnifyingglass" }
            if event.title.contains("目录") { return "folder" }
            if event.title.contains("修改") || event.title.contains("写入") { return "pencil" }
            if event.title.contains("回答") { return "questionmark.bubble" }
            if event.title.contains("任务") { return "checklist" }
            return "gearshape"
        }
    }
    
    private var iconColor: Color {
        switch event.state {
        case .running: return .orange
        case .succeeded: return event.type == .completed ? .green : .secondary
        case .failed: return .red
        }
    }
    
    @ViewBuilder
    private var eventStateIcon: some View {
        switch event.state {
        case .running:
            if reduceMotion {
                Image(systemName: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(Color.orange)
            } else {
                ProgressView()
                    .scaleEffect(0.62)
                    .tint(.orange)
            }
        case .succeeded:
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.green)
        case .failed:
            Image(systemName: "xmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.red)
        }
    }
    
    private var accessibilityLabel: String {
        let state: String
        switch event.state {
        case .running: state = "执行中"
        case .succeeded: state = "已完成"
        case .failed: state = "执行失败"
        }
        var parts = [event.title, state]
        if let detail = event.detail, !detail.isEmpty { parts.append(detail) }
        if let additions = event.additions { parts.append("新增 \(additions) 行") }
        if let deletions = event.deletions { parts.append("删除 \(deletions) 行") }
        return parts.joined(separator: "，")
    }
}
