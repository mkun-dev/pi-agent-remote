import SwiftUI

/// 原 Timeline 重构为 Activity：展示 Agent 做了什么，而不是底层消息流水。
struct ActivityView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }
    
    private var activityEvents: [ActivityEvent] {
        store.activityEvents
    }
    
    var body: some View {
        let events = activityEvents
        Group {
            if events.isEmpty {
                emptyState
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ForEach(events) { event in
                                ActivityRow(
                                    event: event,
                                    isLast: event.id == events.last?.id
                                )
                                .id(event.id)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 14)
                    }
                    // 监听最后一个 ActivityEvent 本身；Tool running→done 原地变化也能触发。
                    .onChange(of: events.last) { lastEvent in
                        guard let lastID = lastEvent?.id else { return }
                        if reduceMotion {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        } else {
                            withAnimation(.easeOut(duration: 0.22)) {
                                proxy.scrollTo(lastID, anchor: .bottom)
                            }
                        }
                    }
                    .onAppear {
                        if let lastID = events.last?.id {
                            proxy.scrollTo(lastID, anchor: .bottom)
                        }
                    }
                }
            }
        }
        .navigationTitle("活动")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var emptyState: some View {
        VStack(spacing: 12) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text("还没有活动")
                .font(.headline)
                .foregroundStyle(.secondary)
            Text("与 Pi 对话后，这里会展示请求、工具、文件变化和完成摘要。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .combine)
    }
}

private struct ActivityRow: View {
    let event: ActivityEvent
    let isLast: Bool
    
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(spacing: 0) {
                eventIcon
                    .frame(width: 32, height: 32)
                    .background(eventColor.opacity(0.12), in: Circle())
                if !isLast {
                    Rectangle()
                        .fill(Color.secondary.opacity(0.2))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: 32)
            
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(Self.timeFormatter.string(from: event.timestamp))
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(event.title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(event.type == .error ? Color.red : Color.primary)
                    Spacer(minLength: 4)
                    if event.isRunning {
                        if reduceMotion {
                            Image(systemName: "circle.dotted")
                                .font(.caption)
                                .foregroundStyle(Color.orange)
                        } else {
                            ProgressView().scaleEffect(0.62).tint(.orange)
                        }
                    }
                }
                
                if let detail = event.detail, !detail.isEmpty {
                    Text(detail)
                        .font(detailFont)
                        .foregroundStyle(.secondary)
                        .lineLimit(isExpanded ? nil : 3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                    
                    if isLongDetail(detail) {
                        Button(isExpanded ? "收起" : "展开") {
                            if reduceMotion {
                                isExpanded.toggle()
                            } else {
                                withAnimation(.easeInOut(duration: 0.2)) {
                                    isExpanded.toggle()
                                }
                            }
                        }
                        .font(.caption.weight(.semibold))
                        .frame(minWidth: 44, minHeight: 44, alignment: .leading)
                        .buttonStyle(.plain)
                        .foregroundStyle(Color.accentColor)
                        .accessibilityHint(isExpanded ? "收起活动详情" : "展开完整活动详情")
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 1)
            }
            .padding(.bottom, isLast ? 0 : 12)
        }
        .accessibilityElement(children: .contain)
    }
    
    @ViewBuilder
    private var eventIcon: some View {
        Image(systemName: systemImage)
            .font(.system(size: 14, weight: .semibold))
            .foregroundStyle(eventColor)
            .accessibilityHidden(true)
    }
    
    private var systemImage: String {
        switch event.type {
        case .userRequest: return "person.fill"
        case .thinking: return "brain"
        case .toolExecution:
            return event.title.contains("测试") ? "checkmark.seal" : "gearshape"
        case .fileChange:
            if event.title.contains("新增") { return "doc.badge.plus" }
            if event.title.contains("删除") { return "trash" }
            return "pencil"
        case .completed: return "checkmark.circle.fill"
        case .error: return "exclamationmark.triangle.fill"
        }
    }
    
    private var eventColor: Color {
        switch event.type {
        case .userRequest: return .blue
        case .thinking: return .orange
        case .toolExecution: return .purple
        case .fileChange: return .indigo
        case .completed: return .green
        case .error: return .red
        }
    }
    
    private var detailFont: Font {
        switch event.type {
        case .toolExecution, .fileChange:
            return .caption.monospaced()
        default:
            return .callout
        }
    }
    
    private func isLongDetail(_ detail: String) -> Bool {
        detail.count > 160 || detail.components(separatedBy: "\n").count > 3
    }
}
