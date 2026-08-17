import SwiftUI

extension FileChangeType {
    var localizedName: String {
        switch self {
        case .added: return "新增"
        case .modified: return "修改"
        case .deleted: return "删除"
        }
    }
    
    var marker: String {
        switch self {
        case .added: return "+"
        case .modified: return "M"
        case .deleted: return "−"
        }
    }
    
    var tint: Color {
        switch self {
        case .added: return PiDesignSystem.Color.diffAdd
        case .modified: return PiDesignSystem.Color.thinking
        case .deleted: return PiDesignSystem.Color.diffRemove
        }
    }
}

struct FileChangeRow: View {
    let change: FileChange
    
    var body: some View {
        HStack(spacing: 10) {
            Text(change.type.marker)
                .font(.caption.bold().monospaced())
                .foregroundStyle(change.type.tint)
                .frame(width: 28, height: 28)
                .background(change.type.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(change.fileName.isEmpty ? change.normalizedPath : change.fileName)
                    .font(PiDesignSystem.Font.subheadline)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                    .lineLimit(1)
                if !change.parentPath.isEmpty {
                    Text(change.parentPath)
                        .font(PiDesignSystem.Font.mono)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer(minLength: 6)
            
            if change.additions != nil || change.deletions != nil {
                HStack(spacing: 5) {
                    if let additions = change.additions {
                        Text("+\(additions)").foregroundStyle(PiDesignSystem.Color.diffAdd)
                    }
                    if let deletions = change.deletions {
                        Text("−\(deletions)").foregroundStyle(PiDesignSystem.Color.diffRemove)
                    }
                }
                .font(.caption.monospacedDigit())
            }
            
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(PiDesignSystem.Color.tertiary)
                .accessibilityHidden(true)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityHint("打开文件变化详情")
    }
    
    private var accessibilityLabel: String {
        var parts = [change.type.localizedName, change.normalizedPath]
        if let additions = change.additions { parts.append("新增 \(additions) 行") }
        if let deletions = change.deletions { parts.append("删除 \(deletions) 行") }
        return parts.joined(separator: "，")
    }
}
