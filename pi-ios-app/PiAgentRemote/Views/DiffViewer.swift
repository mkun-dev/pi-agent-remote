import SwiftUI

// MARK: - Diff Viewer

/// 文件修改查看器 — 展示 Agent 对单个文件的具体变更。
/// 数据来自 FileChange 模型（路径、类型、增删行数）。
struct DiffViewer: View {
    let change: FileChange
    /// 「在Workspace打开」回调，传入文件路径。nil 时隐藏按钮。
    var onOpenInWorkspace: ((String) -> Void)? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    fileHeader
                    Divider().padding(.horizontal, 16)
                    changeStats
                    Divider().padding(.horizontal, 16)
                    diffPreview
                }
            }
            .background(Color(uiColor: .systemBackground))
            .navigationTitle(change.fileName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        UIPasteboard.general.string = summaryText
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                    } label: {
                        Label("复制摘要", systemImage: "doc.on.doc")
                    }
                }
                // 在Workspace打开（仅未删除的文件可查看内容）
                if let onOpenInWorkspace, change.type != .deleted {
                    ToolbarItem(placement: .bottomBar) {
                        Button {
                            onOpenInWorkspace(change.normalizedPath)
                            dismiss()
                        } label: {
                            Label("在Workspace打开", systemImage: "folder")
                        }
                    }
                }
            }
        }
    }
    
    // MARK: - File Header
    
    private var fileHeader: some View {
        VStack(spacing: 10) {
            Image(systemName: fileIcon)
                .font(.system(size: 36))
                .foregroundStyle(change.type.tint)
                .padding(.top, 24)
            
            Text(change.fileName)
                .font(.title3.weight(.bold))
                .foregroundStyle(.primary)
            
            Text(change.normalizedPath)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .padding(.horizontal, 16)
                .multilineTextAlignment(.center)
            
            HStack(spacing: 6) {
                Circle()
                    .fill(change.type.tint)
                    .frame(width: 8, height: 8)
                Text(change.type.localizedName)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(change.type.tint)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(change.type.tint.opacity(0.1), in: Capsule())
        }
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
    }
    
    // MARK: - Change Stats
    
    private var changeStats: some View {
        VStack(spacing: 12) {
            Text("变更摘要")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            HStack(spacing: 20) {
                if let additions = change.additions, additions > 0 {
                    statItem(
                        icon: "plus.circle.fill",
                        label: "新增",
                        value: "+\(additions) 行",
                        color: .green
                    )
                }
                if let deletions = change.deletions, deletions > 0 {
                    statItem(
                        icon: "minus.circle.fill",
                        label: "删除",
                        value: "−\(deletions) 行",
                        color: .red
                    )
                }
                if change.additions == nil && change.deletions == nil {
                    statItem(
                        icon: change.type == .deleted ? "trash.circle.fill" : "doc.circle.fill",
                        label: change.type.localizedName,
                        value: "—",
                        color: change.type.tint
                    )
                }
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
            .frame(maxWidth: .infinity)
        }
    }
    
    private func statItem(icon: String, label: String, value: String, color: Color) -> some View {
        VStack(spacing: 4) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(color)
            Text(value)
                .font(.headline.monospacedDigit())
                .foregroundStyle(.primary)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 70)
        .padding(.vertical, 10)
        .padding(.horizontal, 14)
        .background(color.opacity(0.07), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
    
    // MARK: - Diff Preview
    
    private var diffPreview: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("变更预览")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            if let hunks = change.diffHunks, !hunks.isEmpty {
                realDiffView(hunks)
            } else {
                simulatedDiffView
                
                HStack(spacing: 6) {
                    Image(systemName: "info.circle")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                    Text("完整 diff 请在 PC 端查看")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
            }
            
            Spacer().frame(height: 24)
        }
    }
    
    // MARK: - Real Diff
    
    private func realDiffView(_ hunks: [DiffHunk]) -> some View {
        ScrollView(.horizontal, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(hunks.indices, id: \.self) { hunkIndex in
                    let hunk = hunks[hunkIndex]
                    // Hunk header
                    Text("@@ −\(hunk.oldStart) +\(hunk.newStart) @@")
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 12)
                    
                    ForEach(hunk.lines) { line in
                        diffLineRow(line)
                    }
                }
            }
            .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .padding(.horizontal, 16)
    }
    
    private func diffLineRow(_ line: DiffLine) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            // 行号
            if let oldLine = line.oldLine {
                Text("\(oldLine)")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text("")
                    .frame(width: 32)
            }
            if let newLine = line.newLine {
                Text("\(newLine)")
                    .frame(width: 32, alignment: .trailing)
                    .foregroundStyle(.secondary)
            } else {
                Text("")
                    .frame(width: 32)
            }
            
            // 符号 + 内容
            Text(line.type == .added ? "+" : (line.type == .removed ? "−" : " "))
                .foregroundStyle(line.type == .added ? .green : (line.type == .removed ? .red : .secondary))
                .frame(width: 12, alignment: .center)
            
            Text(line.content)
                .foregroundStyle(.primary)
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
        }
        .font(.system(size: 11, design: .monospaced))
        .lineSpacing(2)
        .padding(.vertical, 1)
        .padding(.horizontal, 8)
        .background(lineBackground(line.type))
    }
    
    private func lineBackground(_ type: DiffLine.LineType) -> Color {
        switch type {
        case .added:   return PiDesignSystem.Color.diffAddBg
        case .removed: return PiDesignSystem.Color.diffRemoveBg
        case .context: return Color.clear
        }
    }
    
    // MARK: - Simulated Diff (fallback)
    
    private var simulatedDiffView: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("变更预览")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 16)
            
            VStack(alignment: .leading, spacing: 0) {
                switch change.type {
                case .added:
                    diffBlock(symbol: "+", lines: previewAddLines, color: .green)
                case .deleted:
                    diffBlock(symbol: "−", lines: previewDelLines, color: .red)
                case .modified:
                    diffBlock(symbol: "−", lines: previewDelLines, color: .red)
                    diffBlock(symbol: "+", lines: previewAddLines, color: .green)
                }
            }
            .font(.system(.caption, design: .monospaced))
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.black.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .padding(.horizontal, 16)
            
            // 提示
            HStack(spacing: 6) {
                Image(systemName: "info.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                Text("完整 diff 请在 PC 端查看")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 24)
        }
    }
    
    @ViewBuilder
    private func diffBlock(symbol: String, lines: [String], color: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(lines.indices, id: \.self) { index in
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(symbol)
                        .foregroundStyle(color)
                        .frame(width: 12, alignment: .center)
                    Text(lines[index])
                        .foregroundStyle(.primary)
                        .textSelection(.enabled)
                }
            }
        }
        if !lines.isEmpty && lines != previewDelLines {
            Divider().padding(.vertical, 4).opacity(0.3)
        }
    }
    
    /// 模拟新增行预览（基于 additions 计数生成占位符）
    private var previewAddLines: [String] {
        guard let count = change.additions, count > 0 else { return [] }
        let previewCount = min(count, 15)
        var result: [String] = []
        for i in 0..<previewCount {
            result.append("+ 第 \(i + 1) 处修改")
        }
        if count > 15 {
            result.append("... 共 \(count) 行新增")
        }
        return result
    }
    
    /// 模拟删除行预览
    private var previewDelLines: [String] {
        guard let count = change.deletions, count > 0 else { return [] }
        let previewCount = min(count, 15)
        var result: [String] = []
        for i in 0..<previewCount {
            result.append("− 原始第 \(i + 1) 行")
        }
        if count > 15 {
            result.append("... 共 \(count) 行删除")
        }
        return result
    }
    
    // MARK: - Helpers
    
    private var fileIcon: String {
        switch change.type {
        case .added:   return "doc.badge.plus"
        case .modified:return "doc.badge.gearshape"
        case .deleted: return "doc.badge.minus"
        }
    }
    
    private var summaryText: String {
        """
        📄 \(change.normalizedPath)
        类型: \(change.type.localizedName)
        新增: +\(change.additions ?? 0) 行
        删除: −\(change.deletions ?? 0) 行
        """
    }
}
