import SwiftUI
import UIKit
import WebKit

// MARK: - File Viewer（只读）

/// 文件内容查看器：按文件类型路由到 Markdown / SVG / 图片 / 文本 / 二进制提示。
/// 数据流：ChatViewModel.loadWorkspaceFile → Extension → workspace.file → ConversationStore.workspaceFiles
struct FileViewerView: View {
    enum PreviewMode: String, CaseIterable, Identifiable {
        case preview
        case source
        var id: String { rawValue }
        var title: String { self == .preview ? "预览" : "源码" }
    }
    
    let file: RemoteWorkspaceFile
    /// 用于聊天联动/查看 diff。可 nil（预览场景）。
    var viewModel: ChatViewModel? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    @State private var searchText = ""
    @State private var currentMatchIndex = 0
    @State private var matchRanges: [Range<String.Index>] = []
    @State private var copied = false
    @State private var copiedPath = false
    @State private var previewImage: UIImage?
    @State private var imageLoadFailed = false
    @State private var previewMode: PreviewMode = .preview
    @State private var selectedDiff: FileChange?
    
    private var path: String { file.path }
    private var textContent: String { file.content ?? "" }
    private var currentKind: WorkspacePreviewKind {
        if previewMode == .source, (file.previewKind == .markdown || file.previewKind == .svg) {
            return .text
        }
        return file.previewKind
    }
    private var supportsPreviewToggle: Bool {
        file.previewKind == .markdown || file.previewKind == .svg
    }
    private var supportsSearch: Bool {
        currentKind == .text
    }
    private var latestDiff: FileChange? {
        viewModel?.conversationStore.latestFileChange(for: path)
    }
    
    private var language: String? {
        let ext = file.fileExtension
        let map: [String: String] = [
            "swift": "swift", "py": "python", "js": "javascript", "ts": "typescript",
            "tsx": "typescript", "jsx": "javascript", "md": "markdown", "markdown": "markdown",
            "json": "json", "yml": "yaml", "yaml": "yaml", "html": "html", "css": "css",
            "sh": "bash", "bash": "bash", "go": "go", "rs": "rust", "java": "java",
            "kt": "kotlin", "c": "c", "cpp": "cpp", "h": "c", "sql": "sql", "svg": "xml"
        ]
        return map[ext]
    }
    
    private var lineCount: Int { textContent.components(separatedBy: "\n").count }
    private var byteCount: Int { file.size }
    private var imageResolutionText: String? {
        guard let previewImage else { return nil }
        let width = previewImage.cgImage?.width ?? Int(previewImage.size.width * previewImage.scale)
        let height = previewImage.cgImage?.height ?? Int(previewImage.size.height * previewImage.scale)
        guard width > 0, height > 0 else { return nil }
        return "\(width)×\(height)"
    }
    
    var body: some View {
        NavigationStack {
            ZStack {
                PiDesignSystem.Color.background.ignoresSafeArea()
                VStack(spacing: 0) {
                if supportsSearch, (!searchText.isEmpty || isSearchFocused) {
                    searchBar
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                viewerBody
            }
                .background(PiDesignSystem.Color.background)
            }
            .navigationTitle(file.fileName)
            .preferredColorScheme(.dark)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        Button {
                            copyPath()
                        } label: {
                            Label(copiedPath ? "已复制路径" : "复制路径", systemImage: copiedPath ? "checkmark" : "link")
                        }
                        if file.type == .text, !textContent.isEmpty {
                            Button {
                                copyContent()
                            } label: {
                                Label(copied ? "已复制内容" : "复制内容", systemImage: copied ? "checkmark" : "doc.on.doc")
                            }
                        }
                        Divider()
                        Button {
                            askAgent()
                        } label: {
                            Label("询问Agent", systemImage: "bubble.left.and.bubble.right")
                        }
                        .disabled(viewModel == nil)
                        Button {
                            referenceInChat()
                        } label: {
                            Label("在Chat引用", systemImage: "text.quote")
                        }
                        .disabled(viewModel == nil)
                        Divider()
                        Button {
                            selectedDiff = latestDiff
                        } label: {
                            Label("查看Diff", systemImage: "arrow.left.arrow.right.square")
                        }
                        .disabled(latestDiff == nil)
                    } label: {
                        Image(systemName: "ellipsis.circle")
                    }
                    .accessibilityLabel("文件操作")
                }
                ToolbarItem(placement: .secondaryAction) {
                    Button {
                        toggleSearch()
                    } label: {
                        Image(systemName: "magnifyingglass")
                    }
                    .accessibilityLabel("搜索")
                    .disabled(!supportsSearch)
                }
            }
            .task(id: file.path) {
                await loadImageIfNeeded()
            }
            .sheet(item: $selectedDiff) { change in
                DiffViewer(change: change, onOpenInWorkspace: { path in
                    viewModel?.openFileInWorkspace(path: path)
                })
            }
        }
    }
    
    @ViewBuilder
    private var viewerBody: some View {
        switch currentKind {
        case .markdown:
            markdownViewer
        case .svg:
            svgViewer
        case .image:
            imageViewer
        case .text:
            textViewer
        case .binary:
            binaryViewer
        }
    }
    
    // MARK: - Text / Markdown / SVG
    
    private var textViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                fileMetaHeader
                if textContent.isEmpty {
                    Text("空文件")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .padding()
                } else if !searchText.isEmpty && !matchRanges.isEmpty {
                    highlightedText
                        .font(.system(.footnote, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    CodeBlockView(code: textContent, language: language)
                        .frame(maxWidth: .infinity)
                }
            }
        }
    }
    
    private var markdownViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                fileMetaHeader
                if textContent.isEmpty {
                    Text("空文件")
                        .font(PiDesignSystem.Font.caption)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                        .padding(.horizontal, 12)
                } else {
                    MarkdownContent(messageID: "workspace:\(path)", markdown: textContent)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 18)
                }
            }
            .padding(.vertical, 12)
        }
    }
    
    private var svgViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileMetaHeader
                if textContent.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    unsupportedPreviewView(title: "空 SVG", detail: "该 SVG 文件没有可渲染内容。")
                } else {
                    SVGPreviewView(svgContent: textContent)
                        .frame(height: 320)
                        .piPreviewClip(radius: 14)
                        .padding(.horizontal, 12)
                }
            }
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Image
    
    private var imageViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileMetaHeader
                
                if let previewImage {
                    Image(uiImage: previewImage)
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: .infinity)
                        .piPreviewClip(radius: 14)
                        .padding(.horizontal, 12)
                } else if imageLoadFailed {
                    unsupportedPreviewView(title: "图片加载失败", detail: "文件已识别为图片，但解码失败。")
                } else {
                    VStack(spacing: 12) {
                        ProgressView()
                        Text("加载图片预览...")
                            .font(PiDesignSystem.Font.caption)
                            .foregroundStyle(PiDesignSystem.Color.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 40)
                }
            }
            .padding(.vertical, 12)
        }
    }
    
    // MARK: - Binary
    
    private var binaryViewer: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                fileMetaHeader
                unsupportedPreviewView(title: "不支持预览", detail: "该文件被识别为二进制文件，暂不支持在 iPhone 上直接查看。")
            }
            .padding(.vertical, 12)
        }
    }
    
    private func unsupportedPreviewView(title: String, detail: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: currentKind == .image || currentKind == .svg ? "photo" : "doc.badge.questionmark")
                .font(.system(size: 42))
                .foregroundStyle(PiDesignSystem.Color.secondary)
            Text(title)
                .font(.headline)
                .foregroundStyle(PiDesignSystem.Color.primary)
            Text(detail)
                .font(.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
        .piCard(color: PiDesignSystem.Color.surface, radius: 18)
    }
    
    private var fileMetaHeader: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(path)
                .font(.caption.monospaced())
                .foregroundStyle(PiDesignSystem.Color.secondary)
                .textSelection(.enabled)
            
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 120), spacing: 10, alignment: .leading)], alignment: .leading, spacing: 8) {
                metaPill(systemImage: "internaldrive", text: formattedFileSize(byteCount))
                if let mime = effectiveMimeType {
                    metaPill(systemImage: currentKind == .image || currentKind == .svg ? "photo" : "doc.text", text: mime)
                }
                if currentKind == .text || currentKind == .markdown {
                    metaPill(systemImage: "text.alignleft", text: "\(lineCount) 行")
                }
                if let imageResolutionText {
                    metaPill(systemImage: "arrow.up.left.and.arrow.down.right", text: imageResolutionText)
                }
            }
            
            if supportsPreviewToggle {
                Picker("查看模式", selection: $previewMode) {
                    ForEach(PreviewMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 6)
    }
    
    private func metaPill(systemImage: String, text: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(PiDesignSystem.Font.caption2)
            .foregroundStyle(PiDesignSystem.Color.secondary)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .piTintCapsule(PiDesignSystem.Color.secondary, opacity: 0.08)
    }
    
    private var effectiveMimeType: String? {
        if let mime = file.mimeType, !mime.isEmpty { return mime }
        switch file.previewKind {
        case .markdown: return "text/markdown"
        case .svg: return "image/svg+xml"
        case .image, .text, .binary: return nil
        }
    }
    
    private func formattedFileSize(_ bytes: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(bytes))
    }
    
    private func loadImageIfNeeded() async {
        guard currentKind == .image else { return }
        guard previewImage == nil else { return }
        guard let base64 = file.base64, let data = Data(base64Encoded: base64) else {
            await MainActor.run { imageLoadFailed = true }
            return
        }
        let key = ImageCache.cacheKey(for: data)
        let image = await ImageCache.shared.image(for: key, fallbackData: data)
        await MainActor.run {
            previewImage = image
            imageLoadFailed = (image == nil)
        }
    }
    
    // MARK: - Search
    
    @FocusState private var isSearchFocused: Bool
    
    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(PiDesignSystem.Color.secondary)
            TextField("搜索文件内容", text: $searchText)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isSearchFocused)
                .submitLabel(.done)
                .onChange(of: searchText) { _ in
                    recomputeMatches()
                }
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
                .accessibilityLabel("清除搜索")
            }
            if !matchRanges.isEmpty {
                Text("\(currentMatchIndex + 1)/\(matchRanges.count)")
                    .font(PiDesignSystem.Font.monoDigit)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
                Button {
                    cycleMatch(forward: true)
                } label: {
                    Image(systemName: "chevron.down")
                }
                .accessibilityLabel("下一个匹配")
                Button {
                    cycleMatch(forward: false)
                } label: {
                    Image(systemName: "chevron.up")
                }
                .accessibilityLabel("上一个匹配")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .piInputSurface(radius: 20)
    }
    
    private var highlightedText: some View {
        Text(attributedContent)
            .font(.system(.footnote, design: .monospaced))
    }
    
    private var attributedContent: AttributedString {
        var attr = AttributedString(textContent)
        for (index, range) in matchRanges.enumerated() {
            let attRange = Range(range, in: attr)
            if let attRange {
                attr[attRange].backgroundColor = index == currentMatchIndex
                    ? PiDesignSystem.Color.thinking.opacity(0.5)
                    : PiDesignSystem.Color.thinking.opacity(0.22)
                attr[attRange].foregroundColor = .primary
            }
        }
        return attr
    }
    
    private func recomputeMatches() {
        currentMatchIndex = 0
        let lower = textContent.lowercased()
        let query = searchText.lowercased()
        guard !query.isEmpty else {
            matchRanges = []
            return
        }
        var ranges: [Range<String.Index>] = []
        var start = textContent.startIndex
        while start < textContent.endIndex,
              let range = lower.range(of: query, options: .literal, range: start..<textContent.endIndex) {
            ranges.append(range)
            start = range.upperBound
        }
        matchRanges = ranges
    }
    
    private func cycleMatch(forward: Bool) {
        guard !matchRanges.isEmpty else { return }
        if forward {
            currentMatchIndex = (currentMatchIndex + 1) % matchRanges.count
        } else {
            currentMatchIndex = (currentMatchIndex - 1 + matchRanges.count) % matchRanges.count
        }
    }
    
    private func toggleSearch() {
        guard supportsSearch else { return }
        if isSearchFocused {
            isSearchFocused = false
        } else {
            isSearchFocused = true
        }
    }
    
    // MARK: - Actions
    
    private func copyPath() {
        UIPasteboard.general.string = path
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copiedPath = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copiedPath = false }
        }
    }
    
    private func copyContent() {
        guard file.type == .text else { return }
        UIPasteboard.general.string = textContent
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.2)) { copied = false }
        }
    }
    
    /// 设置文件上下文 → 切到聊天 Tab → 预填输入框。
    private func askAgent() {
        guard let viewModel else { return }
        let selection = (supportsSearch && !searchText.isEmpty) ? "搜索: \(searchText)" : nil
        viewModel.conversationStore.setPendingFileContext(files: [path], selection: selection)
        viewModel.inputText = "关于 \(file.fileName)："
        viewModel.activeTab = 1   // tab 索引：0=首页 1=聊天
        dismiss()
    }
    
    /// 仅引用路径到聊天输入框，不附带 Agent 上下文。
    private func referenceInChat() {
        guard let viewModel else { return }
        viewModel.conversationStore.clearPendingFileContext()
        viewModel.inputText = "参考文件：\(path)\n"
        viewModel.activeTab = 1   // tab 索引：0=首页 1=聊天
        dismiss()
    }
}

private struct SVGPreviewView: UIViewRepresentable {
    let svgContent: String
    
    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.scrollView.isScrollEnabled = false
        webView.scrollView.backgroundColor = .clear
        return webView
    }
    
    func updateUIView(_ webView: WKWebView, context: Context) {
        let html = """
        <!doctype html>
        <html>
        <head>
          <meta name=\"viewport\" content=\"width=device-width, initial-scale=1.0\">
          <style>
            html, body { margin:0; padding:0; background: transparent; }
            body { display:flex; align-items:center; justify-content:center; min-height:100%; }
            svg { max-width: 100%; max-height: 100%; height: auto; width: auto; }
          </style>
        </head>
        <body>
        \(svgContent)
        </body>
        </html>
        """
        webView.loadHTMLString(html, baseURL: nil)
    }
}
