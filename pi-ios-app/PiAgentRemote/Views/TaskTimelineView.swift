import SwiftUI

// MARK: - Task Timeline View

/// Agent 任务执行时间线 — 展示一次完整任务的全部步骤。
/// 数据来自 ConversationStore.currentTrace + activityEvents（纯 UI 投影）。
struct TaskTimelineView: View {
    @ObservedObject var store: ConversationStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    @State private var expandedEventIndex: Int? = nil
    
    var body: some View {
        NavigationStack {
            Group {
                if timelineEntries.isEmpty {
                    emptyState
                } else {
                    timelineScroll
                }
            }
            .navigationTitle("任务时间线")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
            }
        }
    }
    
    // MARK: - Timeline Data
    
    /// 从 currentTrace.events 和最近 activityEvents 混合构建时间线条目
    private var timelineEntries: [TimelineEntry] {
        var entries: [TimelineEntry] = []
        let now = Date()
        
        // 1. Trace 事件优先（结构化，带状态）
        if let trace = store.currentTrace {
            for (index, event) in trace.events.enumerated() {
                entries.append(TimelineEntry(
                    id: "trace-\(index)",
                    timestamp: now, // TraceEvent 无独立时间戳，使用当前时间
                    type: timelineType(from: event.type),
                    title: event.title,
                    detail: event.detail,
                    additions: event.additions,
                    deletions: event.deletions,
                    state: entryState(from: event.state),
                    duration: nil
                ))
            }
        }
        
        // 2. 互补：无 Trace 时回退到 activityEvents
        if entries.isEmpty {
            entries = store.activityEvents.suffix(20).map { event in
                TimelineEntry(
                    id: event.id,
                    timestamp: event.timestamp,
                    type: timelineType(from: event.type),
                    title: event.title,
                    detail: event.detail,
                    additions: nil,
                    deletions: nil,
                    state: event.isRunning ? .running : .completed,
                    duration: nil
                )
            }
        }
        
        return entries
    }
    
    private func timelineType(from traceType: TraceEventType) -> TimelineEntryType {
        switch traceType {
        case .thinking:  return .thinking
        case .tool:      return .tool
        case .command:   return .tool
        case .fileChange:return .file
        case .completed: return .completed
        }
    }
    
    private func timelineType(from activityType: ActivityEventType) -> TimelineEntryType {
        switch activityType {
        case .userRequest:  return .userRequest
        case .thinking:     return .thinking
        case .toolExecution:return .tool
        case .fileChange:   return .file
        case .completed:    return .completed
        case .error:        return .error
        }
    }
    
    private func entryState(from traceState: TraceEventState) -> TimelineEntryState {
        switch traceState {
        case .running:   return .running
        case .succeeded: return .completed
        case .failed:    return .failed
        }
    }
    
    // MARK: - Timeline Scroll
    
    private var timelineScroll: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(timelineEntries.enumerated()), id: \.element.id) { index, entry in
                        TimelineRow(
                            entry: entry,
                            isLast: index == timelineEntries.count - 1,
                            isExpanded: expandedEventIndex == index,
                            onToggle: {
                                toggleExpansion(at: index)
                            }
                        )
                        .id(entry.id)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 14)
            }
            .onAppear {
                if let last = timelineEntries.last {
                    proxy.scrollTo(last.id, anchor: .bottom)
                }
            }
        }
    }
    
    private func toggleExpansion(at index: Int) {
        if reduceMotion {
            expandedEventIndex = (expandedEventIndex == index) ? nil : index
        } else {
            withAnimation(.easeInOut(duration: 0.22)) {
                expandedEventIndex = (expandedEventIndex == index) ? nil : index
            }
        }
    }
    
    // MARK: - Empty State
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.badge.questionmark")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("暂无任务时间线")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("开始一个 Agent 任务后，这里会显示执行过程的每个步骤。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Timeline Data Model

private struct TimelineEntry: Identifiable {
    let id: String
    let timestamp: Date
    let type: TimelineEntryType
    let title: String
    let detail: String?
    let additions: Int?
    let deletions: Int?
    let state: TimelineEntryState
    let duration: TimeInterval?
}

private enum TimelineEntryType {
    case userRequest
    case thinking
    case tool
    case file
    case completed
    case error
}

private enum TimelineEntryState {
    case running
    case completed
    case failed
}

// MARK: - Timeline Row

private struct TimelineRow: View {
    let entry: TimelineEntry
    let isLast: Bool
    let isExpanded: Bool
    let onToggle: () -> Void
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = .autoupdatingCurrent
        f.dateFormat = "HH:mm:ss"
        return f
    }()
    
    var body: some View {
        Button {
            onToggle()
        } label: {
            HStack(alignment: .top, spacing: 12) {
                // 左侧时间轴：图标 + 连线
                VStack(spacing: 0) {
                    timelineIcon
                        .frame(width: 34, height: 34)
                        .background(stateColor.opacity(0.12), in: Circle())
                    
                    if !isLast {
                        Rectangle()
                            .fill(Color.secondary.opacity(0.18))
                            .frame(width: 2)
                            .frame(maxHeight: .infinity)
                            .accessibilityHidden(true)
                    }
                }
                .frame(width: 34)
                
                // 右侧内容
                VStack(alignment: .leading, spacing: 4) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(Self.timeFormatter.string(from: entry.timestamp))
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                        
                        Text(entry.title)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(titleColor)
                        
                        Spacer(minLength: 4)
                        
                        if entry.state == .running {
                            if reduceMotion {
                                Image(systemName: "circle.dotted")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            } else {
                                ProgressView().scaleEffect(0.6).tint(.orange)
                            }
                        }
                    }
                    
                    if let detail = entry.detail, !detail.isEmpty {
                        Text(detail)
                            .font(detailFont)
                            .foregroundStyle(.secondary)
                            .lineLimit(isExpanded ? nil : 2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    
                    if entry.additions != nil || entry.deletions != nil {
                        HStack(spacing: 8) {
                            if let a = entry.additions {
                                Text("+\(a)").foregroundStyle(.green).font(.caption2.monospacedDigit())
                            }
                            if let d = entry.deletions {
                                Text("−\(d)").foregroundStyle(.red).font(.caption2.monospacedDigit())
                            }
                        }
                    }
                    
                    if isExpandable {
                        HStack(spacing: 4) {
                            Image(systemName: isExpanded ? "chevron.up" : "chevron.down")
                                .font(.system(size: 9, weight: .semibold))
                            Text(isExpanded ? "收起" : "展开")
                                .font(.caption2)
                        }
                        .foregroundStyle(Color.accentColor)
                        .padding(.top, 2)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .piCard()
                .padding(.bottom, isLast ? 0 : PiDesignSystem.Spacing.md)
            }
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .contain)
        .accessibilityHint(isExpanded ? "收起详情" : "展开查看完整内容")
    }
    
    @ViewBuilder
    private var timelineIcon: some View {
        Image(systemName: iconName)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(stateColor)
            .accessibilityHidden(true)
    }
    
    private var iconName: String {
        switch entry.type {
        case .userRequest: return "person.fill"
        case .thinking:    return "brain"
        case .tool:
            return entry.title.contains("测试") ? "checkmark.seal" : "gearshape"
        case .file:
            if entry.title.contains("新增") { return "doc.badge.plus" }
            if entry.title.contains("删除") { return "trash" }
            return "pencil"
        case .completed:   return entry.state == .failed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill"
        case .error:       return "xmark.octagon.fill"
        }
    }
    
    private var stateColor: Color {
        switch entry.state {
        case .running:   return PiDesignSystem.Color.thinking
        case .completed: return entry.type == .error ? PiDesignSystem.Color.failed : PiDesignSystem.Color.completed
        case .failed:    return PiDesignSystem.Color.failed
        }
    }
    
    private var titleColor: Color {
        if entry.state == .failed { return PiDesignSystem.Color.failed }
        if entry.type == .error { return PiDesignSystem.Color.failed }
        return .primary
    }
    
    private var detailFont: Font {
        entry.type == .tool || entry.type == .file ? .caption.monospaced() : .callout
    }
    
    private var isExpandable: Bool {
        guard let detail = entry.detail, !detail.isEmpty else { return false }
        return detail.count > 100 || detail.contains("\n")
    }
}
