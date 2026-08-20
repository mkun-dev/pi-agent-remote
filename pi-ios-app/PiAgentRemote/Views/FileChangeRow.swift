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
        case .added: return .green
        case .modified: return .orange
        case .deleted: return .red
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
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !change.parentPath.isEmpty {
                    Text(change.parentPath)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            
            Spacer(minLength: 6)
            
            if change.additions != nil || change.deletions != nil {
                HStack(spacing: 5) {
                    if let additions = change.additions {
                        Text("+\(additions)").foregroundStyle(.green)
                    }
                    if let deletions = change.deletions {
                        Text("−\(deletions)").foregroundStyle(.red)
                    }
                }
                .font(.caption.monospacedDigit())
            }
            
            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
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
