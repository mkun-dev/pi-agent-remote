import SwiftUI
import UIKit

struct ImagePreviewItem: Identifiable {
    let id: String
    let fileName: String
    let image: UIImage
}

/// ChatGPT 风格图片消息：单图大预览、多图网格、说明文字与附件状态。
struct ImageMessageView: View {
    let message: Message
    let onOpen: (ImagePreviewItem) -> Void
    
    private var resolvedAttachments: [Attachment] {
        if !message.attachments.isEmpty { return message.attachments }
        guard message.imageData != nil else { return [] }
        return [Attachment(
            id: message.id,
            type: .image,
            fileName: message.content.isEmpty ? "image.png" : message.content,
            cacheKey: "legacy-\(message.id)",
            status: .completed
        )]
    }
    
    private var caption: String {
        message.attachments.isEmpty && message.imageData != nil ? "" : message.content
    }
    
    var body: some View {
        VStack(alignment: message.isUser ? .trailing : .leading, spacing: 0) {
            if resolvedAttachments.count == 1, let attachment = resolvedAttachments.first {
                singleImage(attachment)
                    .padding(4)
            } else {
                multiImageGrid
                    .padding(4)
            }
            
            if !caption.isEmpty {
                Text(caption)
                    .font(.body)
                    .foregroundStyle(message.isUser ? Color.white : Color.primary)
                    .multilineTextAlignment(message.isUser ? .trailing : .leading)
                    .textSelection(.enabled)
                    .padding(.horizontal, 12)
                    .padding(.top, 6)
                    .padding(.bottom, statusText == nil ? 10 : 5)
            }
            
            if let statusText {
                Label(statusText, systemImage: statusIcon)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(statusColor)
                    .padding(.horizontal, 12)
                    .padding(.top, caption.isEmpty ? 5 : 0)
                    .padding(.bottom, 8)
                    .accessibilityLabel(statusText)
            }
        }
        .frame(maxWidth: resolvedAttachments.count == 1 ? 260 : 300)
        .background(bubbleColor)
        .clipShape(RoundedRectangle(cornerRadius: 17, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 17, style: .continuous)
                .stroke(Color.secondary.opacity(message.isUser ? 0 : 0.12), lineWidth: 1)
        }
    }
    
    private func singleImage(_ attachment: Attachment) -> some View {
        CachedAttachmentImage(
            attachment: attachment,
            fallbackData: message.imageData,
            contentMode: .fit,
            onOpen: onOpen
        )
        .frame(width: 252, height: 210)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
    
    private var multiImageGrid: some View {
        LazyVGrid(
            columns: [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)],
            spacing: 4
        ) {
            ForEach(resolvedAttachments) { attachment in
                CachedAttachmentImage(
                    attachment: attachment,
                    fallbackData: nil,
                    contentMode: .fill,
                    onOpen: onOpen
                )
                .frame(height: resolvedAttachments.count == 2 ? 170 : 132)
                .clipShape(RoundedRectangle(cornerRadius: 11, style: .continuous))
            }
        }
    }
    
    private var bubbleColor: Color {
        message.isUser ? Color.blue : Color(uiColor: .secondarySystemBackground)
    }
    
    private var statusText: String? {
        guard !message.attachments.isEmpty else { return nil }
        if message.attachments.contains(where: { $0.status == .failed }) { return "上传失败" }
        if message.attachments.contains(where: { $0.status == .uploading }) { return "上传中…" }
        if message.attachments.contains(where: { $0.status == .processing }) { return "处理中…" }
        return "完成"
    }
    
    private var statusIcon: String {
        if message.attachments.contains(where: { $0.status == .failed }) {
            return "exclamationmark.circle.fill"
        }
        if message.attachments.allSatisfy({ $0.status == .completed }) {
            return "checkmark.circle.fill"
        }
        return "arrow.triangle.2.circlepath"
    }
    
    private var statusColor: Color {
        if message.attachments.contains(where: { $0.status == .failed }) { return .red }
        if message.attachments.allSatisfy({ $0.status == .completed }) {
            return message.isUser ? .white.opacity(0.85) : .green
        }
        return message.isUser ? .white.opacity(0.9) : .orange
    }
}

private struct CachedAttachmentImage: View {
    let attachment: Attachment
    let fallbackData: Data?
    let contentMode: ContentMode
    let onOpen: (ImagePreviewItem) -> Void
    
    @State private var image: UIImage?
    
    var body: some View {
        ZStack {
            Color(uiColor: .tertiarySystemBackground)
            if let image {
                Button {
                    onOpen(ImagePreviewItem(
                        id: attachment.id,
                        fileName: attachment.fileName,
                        image: image
                    ))
                } label: {
                    imageView(image)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("查看图片 \(attachment.fileName)")
                .accessibilityHint("打开全屏图片查看器")
            } else {
                ProgressView()
                    .accessibilityLabel("正在加载图片")
            }
            attachmentStatusOverlay
        }
        .clipped()
        .onAppear {
            image = ImageCache.shared.memoryImage(for: attachment.cacheKey)
        }
        .task(id: attachment.cacheKey) {
            guard image == nil else { return }
            image = await ImageCache.shared.image(
                for: attachment.cacheKey,
                localPath: attachment.localPath,
                fallbackData: fallbackData
            )
        }
    }
    
    @ViewBuilder
    private func imageView(_ image: UIImage) -> some View {
        if contentMode == .fill {
            Image(uiImage: image)
                .resizable()
                .scaledToFill()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        } else {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .contentShape(Rectangle())
        }
    }
    
    @ViewBuilder
    private var attachmentStatusOverlay: some View {
        switch attachment.status {
        case .uploading, .processing:
            Color.black.opacity(0.2)
                .overlay {
                    ProgressView()
                        .tint(.white)
                        .accessibilityHidden(true)
                }
                .allowsHitTesting(false)
        case .failed:
            Color.black.opacity(0.3)
                .overlay {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.title2)
                        .foregroundStyle(Color.white)
                        .accessibilityLabel(attachment.errorMessage ?? "图片上传失败")
                }
                .allowsHitTesting(false)
        case .completed:
            EmptyView()
        }
    }
}
