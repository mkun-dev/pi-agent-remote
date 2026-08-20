import SwiftUI
import UIKit

private enum LogFilter: String, CaseIterable, Identifiable, Hashable {
    case all
    case tools
    case output
    case errors
    
    var id: String { rawValue }
    
    var label: String {
        switch self {
        case .all: return "全部"
        case .tools: return "工具"
        case .output: return "输出"
        case .errors: return "错误"
        }
    }
}

/// 原 Terminal 重构为只读 Logs；没有命令输入或 Shell 控制能力。
struct LogsView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @State private var filter: LogFilter = .all
    @State private var searchText = ""
    @State private var copied = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }
    
    private var filteredEntries: [LogEntry] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return store.logs.filter { entry in
            let matchesFilter: Bool
            switch filter {
            case .all:
                matchesFilter = true
            case .tools:
                matchesFilter = entry.type == .tool || entry.type == .shell
            case .output:
                matchesFilter = entry.type == .stdout || entry.type == .stderr
            case .errors:
                matchesFilter = entry.level == .error
            }
            guard matchesFilter else { return false }
            guard !query.isEmpty else { return true }
            return entry.title.localizedCaseInsensitiveContains(query)
                || entry.content.localizedCaseInsensitiveContains(query)
        }
    }
    
    var body: some View {
        VStack(spacing: 10) {
            logsHeader
            searchField
            filterPicker
            logsPanel
        }
        .padding(.top, 8)
        .background(Color(uiColor: .systemBackground))
        .navigationTitle("执行日志")
        .navigationBarTitleDisplayMode(.inline)
    }
    
    private var logsHeader: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(store.agentState.isWorking ? Color.green : Color.secondary.opacity(0.45))
                .frame(width: 8, height: 8)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 1) {
                Text("只读执行日志")
                    .font(.caption.weight(.semibold))
                Text("\(store.logs.count) / 5000 条")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.agentState.isWorking {
                Label("运行中", systemImage: "circle.dotted")
                    .font(.caption2)
                    .foregroundStyle(Color.green)
            }
            Button {
                copyVisibleLogs()
            } label: {
                Label(copied ? "已复制" : "复制", systemImage: copied ? "checkmark" : "doc.on.doc")
                    .font(.caption.weight(.medium))
                    .frame(minWidth: 44, minHeight: 44)
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color.green : Color.accentColor)
            .disabled(filteredEntries.isEmpty)
            .accessibilityLabel("复制当前筛选的日志")
        }
        .padding(.horizontal, 16)
    }
    
    private var searchField: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索命令、文件或错误", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .accessibilityLabel("搜索日志")
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                        .frame(width: 44, height: 44)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("清除日志搜索")
            }
        }
        .padding(.leading, 12)
        .padding(.trailing, searchText.isEmpty ? 12 : 0)
        .frame(minHeight: 44)
        .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
        .padding(.horizontal, 12)
    }
    
    private var filterPicker: some View {
        Picker("日志过滤", selection: $filter) {
            ForEach(LogFilter.allCases) { item in
                Text(item.label).tag(item)
            }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 12)
        .accessibilityHint("按全部、工具、输出或错误过滤日志")
    }
    
    private var logsPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                if filteredEntries.isEmpty {
                    VStack(spacing: 10) {
                        Image(systemName: searchText.isEmpty ? "doc.text.magnifyingglass" : "magnifyingglass")
                            .font(.title2)
                            .foregroundStyle(Color.gray)
                        Text(searchText.isEmpty ? "还没有执行日志" : "没有匹配的日志")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Color.gray)
                        if !searchText.isEmpty {
                            Text("尝试搜索工具名称、命令、文件路径或错误内容。")
                                .font(.caption)
                                .foregroundStyle(Color.gray.opacity(0.8))
                                .multilineTextAlignment(.center)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 48)
                    .padding(.horizontal, 24)
                } else {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                                .id(entry.id)
                        }
                    }
                    .padding(10)
                }
            }
            // 监听最后一个 LogEntry；Tool 状态原地更新时 count 不变也会触发。
            .onChange(of: filteredEntries.last) { latest in
                guard let latest else { return }
                if reduceMotion {
                    proxy.scrollTo(latest.id, anchor: .bottom)
                } else {
                    withAnimation(.easeOut(duration: 0.2)) {
                        proxy.scrollTo(latest.id, anchor: .bottom)
                    }
                }
            }
            .onAppear {
                if let latest = filteredEntries.last {
                    proxy.scrollTo(latest.id, anchor: .bottom)
                }
            }
        }
        .background(Color.black)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 12)
        .padding(.bottom, 12)
    }
    
    private func copyVisibleLogs() {
        let text = filteredEntries.map { entry in
            "[\(entry.title)]\n\(entry.content)"
        }.joined(separator: "\n\n")
        guard !text.isEmpty else { return }
        UIPasteboard.general.string = text
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            if reduceMotion {
                copied = false
            } else {
                withAnimation(.easeOut(duration: 0.18)) { copied = false }
            }
        }
    }
}

private struct LogEntryRow: View {
    let entry: LogEntry
    @State private var isExpanded = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = .autoupdatingCurrent
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
    
    private var isLong: Bool {
        entry.lineCount > 20 || entry.content.count > 1_200
    }
    
    private var displayedContent: String {
        guard isLong, !isExpanded else { return entry.content }
        let lines = entry.content.components(separatedBy: "\n")
        let preview = lines.prefix(12).joined(separator: "\n")
        return preview.count > 4_000 ? String(preview.prefix(4_000)) + "…" : preview
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: levelIcon)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                    .frame(width: 18, height: 18)
                    .accessibilityHidden(true)
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(Color.gray)
                Text(typeLabel)
                    .font(.caption2.weight(.bold).monospaced())
                    .foregroundStyle(levelColor)
                Text(entry.title)
                    .font(.caption.weight(.semibold).monospaced())
                    .foregroundStyle(Color.white)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if entry.isRunning {
                    if reduceMotion {
                        Image(systemName: "circle.dotted")
                            .font(.caption)
                            .foregroundStyle(Color.orange)
                    } else {
                        ProgressView().scaleEffect(0.58).tint(.orange)
                    }
                }
            }
            
            if !entry.content.isEmpty {
                Text(displayedContent)
                    .font(.system(.footnote, design: .monospaced))
                    .foregroundStyle(entry.level == .error ? Color.red.opacity(0.9) : Color.green.opacity(0.82))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            
            if isLong {
                HStack(spacing: 8) {
                    Text("\(entry.lineCount) 行")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(Color.gray)
                    Button(isExpanded ? "收起" : "查看完整输出") {
                        if reduceMotion {
                            isExpanded.toggle()
                        } else {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                isExpanded.toggle()
                            }
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .frame(minWidth: 44, minHeight: 44)
                    .buttonStyle(.plain)
                    .foregroundStyle(Color.blue)
                    .accessibilityHint(isExpanded ? "折叠长日志" : "展开完整长日志")
                }
            }
        }
        .padding(10)
        .background(Color.white.opacity(0.055), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(levelColor.opacity(0.22), lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
    }
    
    private var typeLabel: String {
        switch entry.type {
        case .tool: return "TOOL"
        case .shell: return "SHELL"
        case .stdout: return "OUTPUT"
        case .stderr: return "STDERR"
        case .system: return "SYSTEM"
        }
    }
    
    private var levelIcon: String {
        switch entry.level {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }
    
    private var levelColor: Color {
        switch entry.level {
        case .info: return .blue
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
