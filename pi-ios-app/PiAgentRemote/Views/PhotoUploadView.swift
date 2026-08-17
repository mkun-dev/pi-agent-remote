import PhotosUI
import SwiftUI
import UIKit

/// 多图选择 → 后台压缩 → 可选说明 → 复用现有 media.upload。
struct PhotoUploadView: View {
    let onUpload: ([PreparedImageUpload], String) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var selectedItems: [PhotosPickerItem] = []
    @State private var preparedImages: [PreparedImageUpload] = []
    @State private var caption = ""
    @State private var isProcessing = false
    @State private var errorMessage: String?
    
    private let columns = [
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8),
        GridItem(.flexible(), spacing: 8)
    ]
    
    var body: some View {
        NavigationStack {
            ZStack {
                PiDesignSystem.Color.background.ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 18) {
                    if isProcessing {
                        ProgressView("正在处理图片…")
                            .padding(.vertical, 32)
                    } else if preparedImages.isEmpty {
                        emptyPicker
                    } else {
                        previewGrid
                        TextField("添加说明（可选）", text: $caption, axis: .vertical)
                            .font(PiDesignSystem.Font.body)
                            .foregroundStyle(PiDesignSystem.Color.primary)
                            .lineLimit(1...4)
                            .padding(12)
                            .piInputSurface()
                        
                        Button {
                            onUpload(preparedImages, caption)
                            dismiss()
                        } label: {
                            Label("发送 \(preparedImages.count) 张图片", systemImage: "paperplane.fill")
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .piPrimaryButton()
                        
                        PhotosPicker(selection: $selectedItems, maxSelectionCount: 6, matching: .images) {
                            Label("重新选择", systemImage: "photo.on.rectangle")
                                .frame(minWidth: 140, minHeight: 44)
                        }
                        .piSecondaryButton()
                    }
                    
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(PiDesignSystem.Color.failed)
                            .accessibilityLabel("图片处理失败，\(errorMessage)")
                    }
                    
                    Text("最多选择 6 张图片；将压缩到最长边 1600 像素后保存到 PC。")
                        .font(.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .multilineTextAlignment(.center)
                }
                    .padding(16)
                }
            }
            .navigationTitle("发送图片")
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { dismiss() }
                }
            }
            .onChange(of: selectedItems) { items in
                guard !items.isEmpty else { return }
                Task { await prepare(items) }
            }
        }
    }
    
    private var emptyPicker: some View {
        VStack(spacing: 14) {
            Image(systemName: "photo.stack")
                .font(.system(size: 42))
                .foregroundStyle(PiDesignSystem.Color.accent)
                .accessibilityHidden(true)
            Text("选择要发送给 Pi 的图片")
                .font(.headline)
            PhotosPicker(selection: $selectedItems, maxSelectionCount: 6, matching: .images) {
                Label("从相册选择", systemImage: "photo.on.rectangle")
                    .frame(minWidth: 160, minHeight: 44)
            }
            .padding(.horizontal, 18)
            .piPrimaryButton()
        }
        .padding(.vertical, 28)
    }
    
    private var previewGrid: some View {
        LazyVGrid(columns: columns, spacing: 8) {
            ForEach(preparedImages) { image in
                if let uiImage = UIImage(data: image.data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .scaledToFill()
                        .frame(height: 108)
                        .frame(maxWidth: .infinity)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                        .accessibilityLabel(image.fileName)
                }
            }
        }
    }
    
    @MainActor
    private func prepare(_ items: [PhotosPickerItem]) async {
        isProcessing = true
        errorMessage = nil
        preparedImages = []
        var output: [PreparedImageUpload] = []
        
        for (index, item) in items.enumerated() {
            guard let data = try? await item.loadTransferable(type: Data.self) else {
                errorMessage = "有图片无法读取，请重新选择。"
                continue
            }
            let compressed = await Task.detached(priority: .userInitiated) {
                Self.compressImage(data, maxDimension: 1_600) ?? data
            }.value
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyyMMdd_HHmmss"
            let suffix = String(UUID().uuidString.prefix(6))
            let fileName = "IMG_\(formatter.string(from: Date()))_\(index + 1)_\(suffix).jpg"
            output.append(PreparedImageUpload(
                id: UUID().uuidString,
                fileName: fileName,
                data: compressed,
                base64: compressed.base64EncodedString(),
                cacheKey: ImageCache.cacheKey(for: compressed)
            ))
        }
        preparedImages = output
        isProcessing = false
        if output.isEmpty, errorMessage == nil {
            errorMessage = "没有可发送的图片。"
        }
    }
    
    private static func compressImage(_ data: Data, maxDimension: CGFloat) -> Data? {
        guard let image = UIImage(data: data) else { return nil }
        let maxSide = max(image.size.width, image.size.height)
        let targetSize: CGSize
        if maxSide > maxDimension {
            let scale = maxDimension / maxSide
            targetSize = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        } else {
            targetSize = image.size
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let renderer = UIGraphicsImageRenderer(size: targetSize, format: format)
        let resized = renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: targetSize))
        }
        return resized.jpegData(compressionQuality: 0.82)
    }
}
