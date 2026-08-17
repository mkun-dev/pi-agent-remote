import Photos
import SwiftUI
import UIKit

struct FullScreenImageViewer: View {
    let item: ImagePreviewItem
    
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showShareSheet = false
    @State private var showSaveError = false
    @State private var didSave = false
    
    var body: some View {
        GeometryReader { geometry in
            ZStack {
                PiDesignSystem.Color.background.ignoresSafeArea()
                ZoomableImageView(image: item.image, reduceMotion: reduceMotion)
                    .ignoresSafeArea()
                
                VStack(spacing: 0) {
                    toolbar
                        .padding(.top, geometry.safeAreaInsets.top + 8)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 10)
                        .background(
                            LinearGradient(
                                colors: [PiDesignSystem.Color.background.opacity(0.9), PiDesignSystem.Color.background.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    Spacer()
                    Text("双指缩放 · 双击放大")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.primary.opacity(0.78))
                        .padding(.horizontal, 12)
                        .frame(minHeight: 44)
                        .piCapsuleSurface(tint: PiDesignSystem.Color.panelElevated.opacity(0.72))
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 12)
                        .accessibilityHidden(true)
                }
                
                if didSave {
                    Label("已保存到相册", systemImage: "checkmark.circle.fill")
                        .font(PiDesignSystem.Font.subheadline)
                        .foregroundStyle(Color.white)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 44)
                        .piTintCapsule(PiDesignSystem.Color.completed, opacity: 0.88)
                        .transition(reduceMotion ? .opacity : .opacity.combined(with: .scale(scale: 0.96)))
                        .accessibilityLabel("图片已保存到相册")
                }
            }
        }
        .statusBarHidden(true)
        .sheet(isPresented: $showShareSheet) {
            ActivityShareSheet(items: [item.image])
        }
        .alert("无法保存图片", isPresented: $showSaveError) {
            Button("取消", role: .cancel) {}
            Button("打开设置") {
                if let url = URL(string: UIApplication.openSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        } message: {
            Text("请在系统设置中允许 Pi Agent 添加照片。")
        }
    }
    
    private var toolbar: some View {
        HStack(spacing: 10) {
            viewerButton(systemImage: "xmark", label: "关闭图片") {
                dismiss()
            }
            
            Text(item.fileName)
                .font(PiDesignSystem.Font.subheadline)
                .foregroundStyle(PiDesignSystem.Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer(minLength: 8)
            
            viewerButton(systemImage: "square.and.arrow.down", label: "保存图片") {
                saveImage()
            }
            viewerButton(systemImage: "square.and.arrow.up", label: "分享图片") {
                showShareSheet = true
            }
        }
    }
    
    private func viewerButton(
        systemImage: String,
        label: String,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(PiDesignSystem.Color.primary)
                .frame(width: 44, height: 44)
                .piFilledCircle(PiDesignSystem.Color.panelElevated.opacity(0.88))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
    
    private func saveImage() {
        PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
            guard status == .authorized || status == .limited else {
                DispatchQueue.main.async { showSaveError = true }
                return
            }
            PHPhotoLibrary.shared().performChanges {
                PHAssetChangeRequest.creationRequestForAsset(from: item.image)
            } completionHandler: { success, _ in
                DispatchQueue.main.async {
                    guard success else {
                        showSaveError = true
                        return
                    }
                    if reduceMotion {
                        didSave = true
                    } else {
                        withAnimation(.easeOut(duration: 0.2)) { didSave = true }
                    }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                        didSave = false
                    }
                }
            }
        }
    }
}

/// UIScrollView 提供原生捏合/平移/双击缩放，避免 SwiftUI 手势与全屏关闭手势冲突。
private struct ZoomableImageView: UIViewRepresentable {
    let image: UIImage
    let reduceMotion: Bool
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    func makeUIView(context: Context) -> UIScrollView {
        let scrollView = UIScrollView()
        scrollView.delegate = context.coordinator
        scrollView.minimumZoomScale = 1
        scrollView.maximumZoomScale = 5
        scrollView.bouncesZoom = true
        scrollView.showsHorizontalScrollIndicator = false
        scrollView.showsVerticalScrollIndicator = false
        scrollView.backgroundColor = .black
        
        let imageView = UIImageView(image: image)
        imageView.contentMode = .scaleAspectFit
        imageView.translatesAutoresizingMaskIntoConstraints = false
        imageView.isUserInteractionEnabled = true
        scrollView.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
            imageView.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
            imageView.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
            imageView.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor),
            imageView.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
            imageView.heightAnchor.constraint(equalTo: scrollView.frameLayoutGuide.heightAnchor)
        ])
        
        let doubleTap = UITapGestureRecognizer(
            target: context.coordinator,
            action: #selector(Coordinator.handleDoubleTap(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        scrollView.addGestureRecognizer(doubleTap)
        context.coordinator.imageView = imageView
        context.coordinator.scrollView = scrollView
        context.coordinator.reduceMotion = reduceMotion
        return scrollView
    }
    
    func updateUIView(_ scrollView: UIScrollView, context: Context) {
        context.coordinator.imageView?.image = image
        context.coordinator.reduceMotion = reduceMotion
    }
    
    final class Coordinator: NSObject, UIScrollViewDelegate {
        weak var imageView: UIImageView?
        weak var scrollView: UIScrollView?
        var reduceMotion = false
        
        func viewForZooming(in scrollView: UIScrollView) -> UIView? {
            imageView
        }
        
        @objc func handleDoubleTap(_ recognizer: UITapGestureRecognizer) {
            guard let scrollView, let imageView else { return }
            if scrollView.zoomScale > 1.05 {
                scrollView.setZoomScale(1, animated: !reduceMotion)
                return
            }
            let targetScale = min(3, scrollView.maximumZoomScale)
            let point = recognizer.location(in: imageView)
            let width = scrollView.bounds.width / targetScale
            let height = scrollView.bounds.height / targetScale
            let rect = CGRect(
                x: point.x - width / 2,
                y: point.y - height / 2,
                width: width,
                height: height
            )
            scrollView.zoom(to: rect, animated: !reduceMotion)
        }
    }
}

private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
