import SwiftUI

struct FileChangeCard: View {
    let changes: [FileChange]
    let isExpanded: Bool
    let onToggle: () -> Void
    let onSelect: (FileChange) -> Void
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        VStack(spacing: 0) {
            Button(action: onToggle) {
                HStack(spacing: 10) {
                    Image(systemName: "doc.on.doc")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                    
                    VStack(alignment: .leading, spacing: 2) {
                        Text("修改了 \(changes.count) 个文件")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                        if let statisticsText {
                            Text(statisticsText)
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    
                    Spacer(minLength: 8)
                    
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isExpanded ? 180 : 0))
                        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isExpanded)
                }
                .frame(minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("修改了 \(changes.count) 个文件")
            .accessibilityValue(isExpanded ? "已展开" : "已折叠")
            .accessibilityHint(isExpanded ? "收起文件列表" : "展开文件列表")
            
            if isExpanded {
                Divider().padding(.vertical, 6)
                VStack(spacing: 2) {
                    ForEach(changes) { change in
                        Button {
                            onSelect(change)
                        } label: {
                            FileChangeRow(change: change)
                        }
                        .buttonStyle(.plain)
                        if change.id != changes.last?.id {
                            Divider().padding(.leading, 38)
                        }
                    }
                }
                .transition(reduceMotion ? .identity : .opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.horizontal, PiDesignSystem.Spacing.md)
        .padding(.vertical, PiDesignSystem.Spacing.sm)
        .piCard()
        .animation(reduceMotion ? nil : PiDesignSystem.Animation.default, value: isExpanded)
    }
    
    private var statisticsText: String? {
        let additions = changes.compactMap(\.additions).reduce(0, +)
        let deletions = changes.compactMap(\.deletions).reduce(0, +)
        guard changes.contains(where: { $0.additions != nil || $0.deletions != nil }) else { return nil }
        return "+\(additions)  −\(deletions)"
    }
}
