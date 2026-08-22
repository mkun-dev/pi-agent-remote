import SwiftUI
import UIKit
import PhotosUI

/// 聊天气泡形状：靠发言者一侧圆角较小，营造对话气泡方向感。
/// 用户消息右侧底角小圆角（靠近头像），Pi 消息左侧底角小圆角。
struct BubbleShape: Shape {
    let isUser: Bool
    
    func path(in rect: CGRect) -> Path {
        let r: CGFloat = 18
        let tailR: CGFloat = 4   // 靠发言者一侧的收窄圆角
        // RectangleCornerRadii 参数顺序：topLeading, bottomLeading, bottomTrailing, topTrailing
        let radii: RectangleCornerRadii = isUser
            ? RectangleCornerRadii(topLeading: r, bottomLeading: r, bottomTrailing: tailR, topTrailing: r)   // 用户右下收窄
            : RectangleCornerRadii(topLeading: r, bottomLeading: tailR, bottomTrailing: r, topTrailing: r)   // Pi 左下收窄
        return UnevenRoundedRectangle(cornerRadii: radii, style: .continuous).path(in: rect)
    }
}

/// 聊天流展示过滤（纯展示层，不删除底层数据）。
/// 聊天窗口只展示用户消息与 Assistant 最终回复（含 streaming）；
/// 内部 Tool 执行过程由 TaskTimelineView / Trace 承担展示。
private struct ChatScrollBottomPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

private struct ChatScrollContentHeightPreferenceKey: PreferenceKey {
    static let defaultValue: CGFloat = 0

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

enum ChatDisplayFilter {
    /// 返回聊天流应展示的消息（输入保持原始顺序）。
    static func filter(_ messages: [Message]) -> [Message] {
        messages.filter(shouldDisplay)
    }

    /// 单条消息是否应展示在聊天流中。
    static func shouldDisplay(_ message: Message) -> Bool {
        // 终端/思考：原始输出仅在 Logs 页展示
        if message.kind == .terminal || message.kind == .thinking { return false }
        // 中间 Assistant / 媒体状态消息：底层保留，聊天页隐藏
        if message.isIntermediateAssistant || message.isMediaStatusMessage { return false }
        // Tool 执行过程不在聊天流展示（TaskTimelineView 有完整 Trace + Activity 数据源）
        if message.kind == .tool { return false }
        // 空 Pi 占位（无内容、无 Trace 展示需求）不显示；streaming 中的内容始终保留
        if message.kind == .text && message.sender == .pi &&
           message.content.isEmpty && !message.isStreaming && message.trace?.shouldDisplay != true { return false }
        return true
    }
}

struct ChatView: View {
    @ObservedObject var viewModel: ChatViewModel
    @ObservedObject private var store: ConversationStore
    @EnvironmentObject var settings: SettingsStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showSessionList = false
    @State private var showClearAlert = false
    @State private var showPhotoPicker = false
    @State private var selectedFileChange: FileChange?
    @State private var selectedImagePreview: ImagePreviewItem?
    @StateObject private var speechService = SpeechRecognitionService()
    @State private var voiceBaseText = ""
    @State private var isVoiceCancelPending = false
    @State private var showVoiceError = false
    @State private var showTaskTimeline = false
    @FocusState private var inputFocused: Bool
    @StateObject private var scrollController = ChatScrollController()
    
    /// 聊天窗口每次布局最多显示的可见消息。
    /// 直接从 store 实时计算，避免独立缓存层导致的流式内容过时和多余重算。
    /// ChatDisplayFilter 为轻量谓词过滤，消息量通常 <200，O(n) 开销可忽略。
    private var visibleMessages: [Message] {
        ChatDisplayFilter.filter(store.messages)
    }
    private let bottomAnchorID = "chat-scroll-bottom-anchor"
    
    init(viewModel: ChatViewModel) {
        self.viewModel = viewModel
        _store = ObservedObject(wrappedValue: viewModel.conversationStore)
    }
    
    private var isVoiceActive: Bool {
        speechService.state.isActive
    }
    
    private func startVoiceInput() {
        inputFocused = false
        voiceBaseText = viewModel.inputText
        isVoiceCancelPending = false
        speechService.startRecording(language: settings.voiceLanguage)
    }
    
    private func stopVoiceInput() {
        speechService.stopRecording()
    }
    
    private func cancelVoiceInput() {
        speechService.cancelRecording()
        viewModel.inputText = voiceBaseText
        isVoiceCancelPending = false
    }
    
    private func combinedVoiceText(_ transcript: String) -> String {
        let recognized = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !recognized.isEmpty else { return voiceBaseText }
        guard !voiceBaseText.isEmpty else { return recognized }
        if voiceBaseText.last?.isWhitespace == true {
            return voiceBaseText + recognized
        }
        return voiceBaseText + " " + recognized
    }
    
    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
    
    private func performScroll(_ request: ChatScrollController.ScrollRequest, proxy: ScrollViewProxy) {
        guard scrollController.consumeIfValid(request) else { return }
        if request.animated && !reduceMotion {
            withAnimation(PiDesignSystem.Animation.default) {
                proxy.scrollTo(bottomAnchorID, anchor: .bottom)
            }
        } else {
            proxy.scrollTo(bottomAnchorID, anchor: .bottom)
        }
    }
    
    private func handleSendTapped() {
        scrollController.noteUserMessageSent()
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        viewModel.send()
    }
    
    /// 单条消息行（EquatableView 包裹，按内容判等跳过未变化行）。
    /// 抽为独立方法，避免 body 表达式过长导致 Swift 类型检查超时。
    @ViewBuilder
    private func messageRowItem(for msg: Message) -> some View {
        EquatableView {
            MessageRow(
                message: msg,
                store: store,
                onToggleToolGroup: { viewModel.toggleToolGroup(messageId: msg.id) },
                onToggleFileChanges: { viewModel.toggleFileChanges(messageId: msg.id) },
                onToggleTrace: { viewModel.toggleAgentTrace(messageId: msg.id) },
                onSelectFileChange: { selectedFileChange = $0 },
                onSelectImage: { selectedImagePreview = $0 }
            )
        }
        .id(msg.id)
        .transition(.asymmetric(
            insertion: .opacity.combined(with: .offset(y: 8)),
            removal: .opacity
        ))
    }

    /// 底部锚点（滚动定位 + 偏移测量）。
    @ViewBuilder
    private func bottomAnchorPreference() -> some View {
        Color.clear
            .frame(height: 1)
            .id(bottomAnchorID)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: ChatScrollBottomPreferenceKey.self,
                        value: geometry.frame(in: .named("chat-scroll")).maxY
                    )
                }
            )
    }

    /// 消息列表内容（LazyVStack），不含 ScrollView 及其修饰符。
    @ViewBuilder
    private func messageListContent(msgs: [Message], messageIDs: [String]) -> some View {
        LazyVStack(alignment: .leading, spacing: 16) {
            ForEach(msgs) { msg in
                messageRowItem(for: msg)
            }
            bottomAnchorPreference()
        }
        .background(
            GeometryReader { geometry in
                Color.clear.preference(
                    key: ChatScrollContentHeightPreferenceKey.self,
                    value: geometry.size.height
                )
            }
        )
        .animation(
            reduceMotion ? nil : PiDesignSystem.Animation.default,
            value: messageIDs
        )
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    /// 聊天滚动视图及其全部修饰符。拆分为多个子方法以满足 Swift 类型检查时限。
    @ViewBuilder
    private func chatScrollContent(msgs: [Message], messageIDs: [String], viewport: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        ScrollView {
            messageListContent(msgs: msgs, messageIDs: messageIDs)
        }
        .coordinateSpace(name: "chat-scroll")
        .background(Color(UIColor.systemGroupedBackground).ignoresSafeArea())
        .onPreferenceChange(ChatScrollBottomPreferenceKey.self) { bottomY in
            scrollController.handleBottomAnchor(bottomY: bottomY, viewportHeight: viewport.size.height)
        }
        .onPreferenceChange(ChatScrollContentHeightPreferenceKey.self) { height in
            scrollController.handleContentHeightChange(height)
        }
        .scrollDismissesKeyboard(.interactively)
        .simultaneousGesture(TapGesture().onEnded {
            inputFocused = false
        })
        .simultaneousGesture(DragGesture(minimumDistance: 8).onChanged { value in
            guard value.translation.height > 8, !inputFocused else { return }
            scrollController.userStartedReadingHistory()
        })
        .onAppear {
            if scrollController.sessionRevision != store.sessionProjectionRevision {
                scrollController.beginSessionRevision(store.sessionProjectionRevision)
            }
            scrollController.handleViewAppear(hasMessages: !msgs.isEmpty)
        }
        .onChange(of: messageIDs) { ids in
            scrollController.handleMessageIDsChanged(
                hasMessages: !ids.isEmpty,
                animated: !reduceMotion
            )
        }
        .onChange(of: store.streamingRevision) { revision in
            scrollController.handleStreamingRevisionChange(
                hasActiveStreamingMessage: store.activeStreamingMessageID != nil,
                revision: revision,
                messageID: store.activeStreamingMessageID
            )
        }
        .onChange(of: store.activeStreamingMessageID) { messageID in
            if messageID == nil {
                scrollController.handleStreamingEnded()
            }
        }
        .onChange(of: scrollController.pendingScrollRequest) { request in
            guard let request else { return }
            performScroll(request, proxy: proxy)
        }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Agent 状态 Header — 概览：连接、阶段、Tool、Model、Session、窗口选择、断开
            AgentStatusHeader(
                store: store,
                onShowTimeline: { showTaskTimeline = true },
                onShowSessions: { showSessionList = true },
                onToggleConnection: {
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                    if store.isConnected { viewModel.disconnect() }
                    else { viewModel.connect() }
                },
                onSwitchTarget: { agentId in viewModel.switchTarget(to: agentId) },
                wsURL: settings.wsURL
            )
                .padding(.horizontal, 12)
                .padding(.top, 4)
            
            ScrollViewReader { proxy in
                GeometryReader { viewport in
                    let msgs = visibleMessages
                    let messageIDs = msgs.map(\.id)
                    ZStack(alignment: .bottomTrailing) {
                        chatScrollContent(msgs: msgs, messageIDs: messageIDs, viewport: viewport, proxy: proxy)
                        
                        if scrollController.shouldShowJumpButton && !msgs.isEmpty {
                            Button {
                                scrollController.requestReturnToBottom(animated: true)
                            } label: {
                                Label("跳到底部", systemImage: "arrow.down")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .background(.regularMaterial, in: Capsule())
                                    .overlay {
                                        Capsule()
                                            .stroke(Color.secondary.opacity(0.18), lineWidth: 0.5)
                                    }
                                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.primary)
                            .accessibilityLabel("跳到底部")
                            .accessibilityHint("显示最新消息")
                            .padding(.trailing, 18)
                            .padding(.bottom, 16)
                            .transition(
                                reduceMotion
                                    ? .identity
                                    : .scale(scale: 0.85).combined(with: .opacity)
                            )
                            .zIndex(1)
                        }
                    }
                }
            }
            .animation(
                reduceMotion ? nil : .easeInOut(duration: 0.18),
                value: scrollController.shouldShowJumpButton
            )
            
            Divider()
            
            // 斜杠命令补全
            if !isVoiceActive && viewModel.inputText.hasPrefix("/") {
                SlashSuggestionsView(input: viewModel.inputText) { cmd in
                    viewModel.inputText = cmd.id + " "
                    inputFocused = true
                }
            }
            
            if isVoiceActive {
                VoiceRecordingBanner(
                    state: speechService.state,
                    transcript: speechService.transcript,
                    isCancelPending: isVoiceCancelPending,
                    onCancel: cancelVoiceInput
                )
                .padding(.horizontal, 16)
                .padding(.top, 8)
                .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
            
            // 输入栏：语音识别只写入现有 inputText，仍由用户确认后发送。
            HStack(alignment: .bottom, spacing: 10) {
                Button {
                    showPhotoPicker = true
                } label: {
                    Image(systemName: "photo.on.rectangle")
                        .font(.system(size: 20))
                        .foregroundColor(.blue)
                        .frame(width: 44, height: 44)
                }
                .accessibilityLabel("发送图片到 PC")
                .disabled(isVoiceActive)
                
                TextField("输入消息发送给 Pi...", text: $viewModel.inputText, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($inputFocused)
                    .disabled(isVoiceActive)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(Color(UIColor.tertiarySystemBackground))
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .stroke(inputFocused ? Color.accentColor.opacity(0.5) : Color.secondary.opacity(0.15),
                                    lineWidth: inputFocused ? 1.5 : 1)
                    )
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: inputFocused)
                
                VoiceInputButton(
                    state: speechService.state,
                    isCancelPending: $isVoiceCancelPending,
                    onStart: startVoiceInput,
                    onStop: stopVoiceInput,
                    onCancel: cancelVoiceInput
                )
                
                Button {
                    handleSendTapped()
                } label: {
                    Image(systemName: "paperplane.fill")
                        .font(.system(size: 18, weight: .semibold))
                }
                .buttonStyle(.borderedProminent)
                .frame(width: 44, height: 44)
                .disabled(
                    isVoiceActive ||
                    viewModel.inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.regularMaterial)
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: store.agentState)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: speechService.state)
        .onChange(of: speechService.transcript) { transcript in
            guard speechService.state.isActive || speechService.state == .completed else { return }
            viewModel.inputText = combinedVoiceText(transcript)
        }
        .onChange(of: speechService.state) { state in
            switch state {
            case .completed:
                viewModel.inputText = combinedVoiceText(speechService.transcript)
                isVoiceCancelPending = false
                UINotificationFeedbackGenerator().notificationOccurred(.success)
                DispatchQueue.main.async { speechService.reset() }
            case .failed:
                viewModel.inputText = voiceBaseText
                isVoiceCancelPending = false
                showVoiceError = true
            default:
                break
            }
        }
        .onChange(of: store.sessionProjectionRevision) { revision in
            showSessionList = false
            showClearAlert = false
            showPhotoPicker = false
            selectedFileChange = nil
            selectedImagePreview = nil
            showTaskTimeline = false
            inputFocused = false
            scrollController.beginSessionRevision(revision)
            if speechService.state.isActive { cancelVoiceInput() }
        }
        .onDisappear {
            if speechService.state.isActive { cancelVoiceInput() }
        }
        .navigationTitle("Pi Agent")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .navigationBarTrailing) {
                Button("清空") {
                    showClearAlert = true
                }
                .disabled(store.messages.isEmpty)
            }
        }
        .sheet(isPresented: $showSessionList) {
            SessionListView(viewModel: viewModel)
        }
        .sheet(isPresented: $viewModel.showModelPicker) {
            let models = store.availableModels
            let current = store.currentModel ?? store.usageInfo?.model
            ModelPickerView(
                models: models,
                currentModel: current,
                isSwitching: viewModel.isSwitchingModel,
                onSelect: { model in
                    viewModel.selectModel(model)
                },
                onDismiss: {
                    viewModel.showModelPicker = false
                    store.modelPickerRequested = false
                }
            )
        }
        .sheet(isPresented: $showPhotoPicker) {
            PhotoUploadView { images, caption in
                viewModel.uploadMedia(images: images, caption: caption)
                showPhotoPicker = false
            }
        }
        .sheet(item: $selectedFileChange) { change in
            DiffViewer(change: change, onOpenInWorkspace: { path in
                viewModel.openFileInWorkspace(path: path)
            })
        }
        .fullScreenCover(item: $selectedImagePreview) { item in
            FullScreenImageViewer(item: item)
        }
        .sheet(isPresented: $showTaskTimeline) {
            TaskTimelineView(store: store)
        }
        .alert("清空聊天记录", isPresented: $showClearAlert) {
            Button("取消", role: .cancel) {}
            Button("清空", role: .destructive) { viewModel.conversationStore.reset() }
        } message: {
            Text("将清除所有聊天、终端和时间线消息，不可恢复。")
        }
        .alert("无法使用语音输入", isPresented: $showVoiceError) {
            Button("取消", role: .cancel) { speechService.reset() }
            Button("打开设置") {
                speechService.reset()
                openSystemSettings()
            }
        } message: {
            Text(speechService.errorMessage ?? "请检查语音识别与麦克风权限后重试。")
        }
        // 键盘工具栏：提供「完成」按钮收起输入法（中文输入法无回车键时尤其需要）
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button {
                    inputFocused = false
                } label: {
                    Text("完成")
                        .fontWeight(.semibold)
                }
            }
        }
    }
}

struct MessageRow: View, Equatable {
    let message: Message
    let store: ConversationStore
    let onToggleToolGroup: () -> Void
    let onToggleFileChanges: () -> Void
    let onToggleTrace: () -> Void
    let onSelectFileChange: (FileChange) -> Void
    let onSelectImage: (ImagePreviewItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    // 流式性能优化：只按 message 内容判等，忽略闭包/store 引用。
    // 父视图每个 delta 都重算 body，但未变化的行通过 EquatableView 跳过。
    static func == (lhs: MessageRow, rhs: MessageRow) -> Bool {
        lhs.message == rhs.message
    }
    
    var body: some View {
        if message.kind == .status {
            statusRow
        } else if message.kind == .terminal {
            EmptyView()
        } else {
            normalRow
        }
    }
    
    // MARK: - 居中状态提示（如 running）
    private var statusRow: some View {
        Text(message.content)
            .font(.caption)
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 2)
    }
    
    // MARK: - 常规消息行（气泡布局）
    private var normalRow: some View {
        HStack(alignment: .top, spacing: 8) {
            if !message.isUser { avatar }
            if message.isUser { Spacer(minLength: 40) }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                contentBody
                if message.kind != .tool && message.kind != .fileChanges {
                    metaRow
                }
            }
            .frame(
                maxWidth: message.kind == .text && !message.isUser ? .infinity : 300,
                alignment: message.isUser ? .trailing : .leading
            )
            
            if message.isUser { avatar }
            if !message.isUser && message.kind != .text {
                Spacer(minLength: 40)
            }
        }
        // 长按复制消息文本
        .contextMenu {
            Button {
                UIPasteboard.general.string = message.content
            } label: {
                Label("复制", systemImage: "doc.on.doc")
            }
        }
    }
    
    // MARK: - 气泡内容（按消息类型分区渲染）
    @ViewBuilder
    private var contentBody: some View {
        switch message.kind {
        case .text:
            if message.isUser {
                // 用户气泡：柔和渐变 + 记忆处圆角收窄（对话气泡感）
                Text(message.content)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(
                        LinearGradient(
                            colors: [PiDesignSystem.Color.userBubbleStart, PiDesignSystem.Color.userBubbleEnd],
                            startPoint: .topLeading, endPoint: .bottomTrailing
                        )
                    )
                    .foregroundColor(.white)
                    .clipShape(BubbleShape(isUser: true))
                    .shadow(color: .black.opacity(0.08), radius: 3, x: 0, y: 1)
                    .textSelection(.enabled)
            } else {
                // Pi：最终 Markdown 正文 + 轻量 Agent Trace + 左侧 accent 条
                HStack(spacing: 0) {
                    // 左侧 accent 条（Claude/Cursor 风格）
                    Rectangle()
                        .fill(PiDesignSystem.Color.border)
                        .frame(width: 3)
                        .padding(.vertical, 4)
                    
                    VStack(alignment: .leading, spacing: 0) {
                        // Pi 标识头
                        piHeader
                            .padding(.horizontal, PiDesignSystem.Spacing.md)
                            .padding(.top, PiDesignSystem.Spacing.sm)
                        
                        if !message.content.isEmpty || message.isStreaming {
                            piBubbleContent
                                .padding(.horizontal, PiDesignSystem.Spacing.md)
                                .padding(.vertical, 10)
                        }
                        if let trace = message.trace, trace.shouldDisplay {
                            AgentTraceView(store: store, onToggle: onToggleTrace)
                                .padding(.horizontal, PiDesignSystem.Spacing.sm)
                                .padding(.top, message.content.isEmpty ? 8 : 0)
                                .padding(.bottom, PiDesignSystem.Spacing.sm)
                        }
                    }
                }
                .background(PiDesignSystem.Color.surface)
                .clipShape(BubbleShape(isUser: false))
                .overlay(
                    BubbleShape(isUser: false)
                        .stroke(PiDesignSystem.Color.border, lineWidth: 0.5)
                )
            }
        case .thinking:
            // 思考：半透明橙气泡 + 闪烁光标
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(message.content)
                    .foregroundColor(.primary)
                ThinkingCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(Color.orange.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        case .tool:
            // 工作期间展开，Agent 完成后自动折叠；用户可随时查看历史详情。
            ToolProgressCard(
                content: message.content,
                toolEntries: message.toolEntries,
                groupStatus: message.toolGroupStatus,
                presentation: message.toolGroupState,
                onToggle: onToggleToolGroup
            )
        case .terminal:
            EmptyView() // 原始输出仅在“终端”页展示
        case .fileChanges:
            FileChangeCard(
                changes: message.fileChanges,
                isExpanded: message.isFileChangesExpanded,
                onToggle: onToggleFileChanges,
                onSelect: onSelectFileChange
            )
        case .image:
            ImageMessageView(message: message, onOpen: onSelectImage)
        case .status:
            EmptyView() // 已在 statusRow 单独处理
        }
    }
    
    // MARK: - Pi 气泡内容（历史回放静态显示，实时消息打字动画）
    @ViewBuilder
    private var piBubbleContent: some View {
        if message.isStreaming {
            // 每个 delta 仅更新纯文本，不解析 Markdown、不做布局动画，避免闪烁和主线程抖动。
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(message.content)
                    .font(.body)
                    .lineSpacing(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                StreamingCursor()
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel(message.content.isEmpty ? "Pi 正在回复" : message.content)
        } else {
            // assistant.end 后一次性切换完整 Markdown；解析结果按稳定 message.id 缓存。
            MarkdownContent(messageID: message.id, markdown: message.content)
        }
    }
    
    // MARK: - Pi 标识头
    @ViewBuilder
    private var piHeader: some View {
        HStack(spacing: 6) {
            // Claude/Cursor 风格：圆形品牌色 icon
            ZStack {
                Circle()
                    .fill(PiDesignSystem.Color.piBrand.opacity(0.12))
                    .frame(width: 22, height: 22)
                Image(systemName: "brain.head.profile")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(PiDesignSystem.Color.piBrand)
            }
            Text("Pi Agent")
                .font(PiDesignSystem.Font.captionBold)
                .foregroundStyle(PiDesignSystem.Color.piBrand.opacity(0.8))
            Spacer()
            if message.isStreaming {
                HStack(spacing: 3) {
                    Circle()
                        .fill(PiDesignSystem.Color.streaming)
                        .frame(width: 5, height: 5)
                    Text("输入中")
                        .font(PiDesignSystem.Font.caption2)
                        .foregroundStyle(PiDesignSystem.Color.secondary)
                }
            } else if let trace = message.trace, trace.isComplete {
                Image(systemName: trace.events.contains(where: { $0.state == .failed }) ? "xmark.circle.fill" : "checkmark.circle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(trace.events.contains(where: { $0.state == .failed }) ? PiDesignSystem.Color.failed : PiDesignSystem.Color.completed)
            }
        }
    }
    
    // MARK: - 头像（仅正文消息显示）
    @ViewBuilder
    private var avatar: some View {
        if message.isUser {
            Image(systemName: "person.crop.circle.fill")
                .font(.system(size: 26))
                .foregroundStyle(LinearGradient(colors: [.blue, .indigo],
                                                startPoint: .top, endPoint: .bottom))
        } else if message.kind == .text || message.kind == .thinking || message.kind == .image {
            Image(systemName: "sparkles")
                .font(.system(size: 14))
                .foregroundStyle(.white)
                .padding(6)
                .background(Circle().fill(LinearGradient(colors: [.purple, .pink],
                                                        startPoint: .top, endPoint: .bottom)))
        }
    }
    
    // MARK: - 时间 + 送达状态
    private var metaRow: some View {
        HStack(spacing: 4) {
            if message.isUser {
                deliveryIcon
            }
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundColor(.secondary)
        }
    }
    
    /// Phase 3 NAT 穿透: 送达状态图标
    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.delivery {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundColor(.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundColor(.red)
        }
    }
}

// MARK: - 模型选择器 (Claude/Cursor 风格)

struct ModelPickerView: View {
    let models: [String]
    let currentModel: String?
    let isSwitching: Bool
    let onSelect: (String) -> Void
    let onDismiss: () -> Void
    
    @State private var searchText = ""
    @State private var pendingSelection: String? = nil
    
    var filteredModels: [String] {
        if searchText.isEmpty { return models }
        return models.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
    
    var body: some View {
        NavigationStack {
            List {
                // Current model section
                if let current = currentModel, !current.isEmpty {
                    Section {
                        HStack(spacing: 12) {
                            Image(systemName: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前模型")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Text(current)
                                    .font(.headline)
                            }
                            Spacer()
                            if isSwitching {
                                ProgressView()
                                    .scaleEffect(0.8)
                            }
                        }
                        .padding(.vertical, 4)
                    } header: {
                        Text("当前模型")
                    }
                } else {
                    Section {
                        HStack {
                            Image(systemName: "questionmark.circle")
                                .foregroundStyle(.secondary)
                            Text("暂未获取到当前模型")
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                
                // Available models
                Section {
                    if filteredModels.isEmpty {
                        Text("无匹配模型")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .center)
                            .padding(.vertical, 12)
                    } else {
                        ForEach(filteredModels, id: \.self) { model in
                            Button {
                                guard !isSwitching else { return }
                                pendingSelection = model
                                onSelect(model)
                            } label: {
                                HStack(spacing: 12) {
                                    Image(systemName: model == currentModel ? "largecircle.fill.circle" : "circle")
                                        .foregroundStyle(model == currentModel ? .blue : .secondary)
                                    Text(model)
                                        .foregroundColor(.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if isSwitching && pendingSelection == model {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else if model == currentModel {
                                        Image(systemName: "checkmark")
                                            .foregroundColor(.blue)
                                            .font(.caption.weight(.semibold))
                                    }
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(isSwitching)
                        }
                    }
                } header: {
                    Text("可用模型")
                }
            }
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "搜索模型")
            .navigationTitle("选择模型")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("取消") { onDismiss() }
                }
            }
        }
    }
}

// MARK: - 斜杠命令补全（输入 / 弹出命令建议）

/// 可用命令
struct SlashCommand: Identifiable {
    let id: String
    let description: String
    let icon: String
}

private let slashCommands: [SlashCommand] = [
    SlashCommand(id: "/model", description: "切换 AI 模型", icon: "cpu"),
    SlashCommand(id: "/ios-config", description: "查看中继配置", icon: "info.circle"),
    SlashCommand(id: "/new", description: "重置会话", icon: "arrow.counterclockwise"),
    SlashCommand(id: "/stop", description: "中断当前处理", icon: "stop.circle"),
    SlashCommand(id: "/queue", description: "查看排队状态", icon: "list.number"),
    SlashCommand(id: "/compact", description: "压缩上下文", icon: "square.compress"),
    SlashCommand(id: "/status", description: "查看 Pi 状态", icon: "gauge")
]

/// 命令补全弹窗（输入区上方）
struct SlashSuggestionsView: View {
    let input: String
    let onSelect: (SlashCommand) -> Void
    
    private var matches: [SlashCommand] {
        guard input.hasPrefix("/") else { return [] }
        let q = input.lowercased()
        return slashCommands.filter { $0.id.lowercased().contains(q) }
    }
    
    var body: some View {
        if matches.isEmpty {
            AnyView(EmptyView())
        } else {
            AnyView(
                VStack(spacing: 0) {
                    Divider()
                    ForEach(matches) { cmd in
                        Button {
                            onSelect(cmd)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: cmd.icon)
                                    .foregroundColor(.blue)
                                    .frame(width: 22)
                                Text(cmd.id)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.primary)
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if cmd.id != matches.last?.id {
                            Divider().padding(.leading, 46)
                        }
                    }
                }
                .background(Color(UIColor.secondarySystemBackground))
            )
        }
    }
}
