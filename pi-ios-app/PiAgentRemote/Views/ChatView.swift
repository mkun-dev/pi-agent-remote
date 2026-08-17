import SwiftUI
import UIKit
import PhotosUI

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
    @State private var showQuickCommandPanel = false
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
    
    private func insertComposerText(_ value: String) {
        if viewModel.inputText.isEmpty {
            viewModel.inputText = value
        } else if viewModel.inputText.hasSuffix(" ") || value.count == 1 {
            viewModel.inputText += value
        } else {
            viewModel.inputText += " " + value
        }
        inputFocused = true
    }

    /// P3：Steer 按钮——中断当前 turn 并把草稿作为新 turn 发送。
    private func handleSteerTapped() {
        scrollController.noteUserMessageSent()
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        viewModel.send(steer: true)
    }

    /// P3：停止按钮——中断当前 turn（不发新消息）。
    private func handleStopTapped() {
        UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
        viewModel.stop()
    }
    
    var body: some View {
        ZStack {
            PiDesignSystem.Color.background
                .ignoresSafeArea()
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
                    let windowed = scrollController.windowedMessages(visibleMessages)
                    let msgs = windowed.visible
                    let hiddenCount = windowed.hiddenCount
                    let messageIDs = msgs.map(\.id)
                    ZStack(alignment: .bottomTrailing) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: PiDesignSystem.Spacing.md) {
                                if hiddenCount > 0 {
                                    Button {
                                        scrollController.revealAll()
                                    } label: {
                                        HStack(spacing: 6) {
                                            Image(systemName: "chevron.up")
                                                .font(.caption.weight(.semibold))
                                            Text("还有 \(hiddenCount) 条更早的消息")
                                            Text("展开")
                                                .font(.caption.weight(.semibold))
                                        }
                                        .font(PiDesignSystem.Font.caption)
                                        .foregroundStyle(PiDesignSystem.Color.secondary)
                                        .frame(maxWidth: .infinity)
                                        .padding(.vertical, 10)
                                        .piTintPanel(PiDesignSystem.Color.secondary, opacity: 0.08, borderOpacity: 0, radius: PiDesignSystem.Radius.md)
                                    }
                                    .buttonStyle(.plain)
                                    .transition(.opacity.combined(with: .move(edge: .top)))
                                }
                                ForEach(msgs) { msg in
                                    MessageRow(
                                        message: msg,
                                        store: store,
                                        onToggleToolGroup: { viewModel.toggleToolGroup(messageId: msg.id) },
                                        onToggleFileChanges: { viewModel.toggleFileChanges(messageId: msg.id) },
                                        onToggleTrace: { viewModel.toggleAgentTrace(messageId: msg.id) },
                                        onSelectFileChange: { selectedFileChange = $0 },
                                        onSelectImage: { selectedImagePreview = $0 },
                                        onEditUserMessage: { viewModel.rewindToUserMessage(messageID: msg.id) }
                                    )
                                    .id(msg.id)
                                    .transition(.asymmetric(
                                        insertion: .opacity.combined(with: .offset(y: 8)),
                                        removal: .opacity
                                    ))
                                }
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
                        .coordinateSpace(name: "chat-scroll")
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
                        
                        if scrollController.shouldShowJumpButton && !msgs.isEmpty {
                            Button {
                                scrollController.requestReturnToBottom(animated: true)
                            } label: {
                                Label("跳到底部", systemImage: "arrow.down")
                                    .font(.subheadline.weight(.semibold))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 9)
                                    .piCapsuleSurface(tint: PiDesignSystem.Color.panelElevated.opacity(0.96))
                                    .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(PiDesignSystem.Color.primary)
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
                .overlay(PiDesignSystem.Color.divider)
            
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
            
            ComposerSurface(
                inputText: $viewModel.inputText,
                isVoiceActive: isVoiceActive,
                speechState: speechService.state,
                isCancelPending: $isVoiceCancelPending,
                isWorking: store.agentState.isWorking,
                onShowAttachments: { showPhotoPicker = true },
                onShowQuickCommands: { showQuickCommandPanel = true },
                onStartVoice: startVoiceInput,
                onStopVoice: stopVoiceInput,
                onCancelVoice: cancelVoiceInput,
                onStopAgent: handleStopTapped,
                onSteer: handleSteerTapped,
                onSend: handleSendTapped
            )
            .focused($inputFocused)
            .padding(.horizontal, 12)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(PiDesignSystem.Color.background)

            QuickCommandDockView { snippet in
                insertComposerText(snippet)
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 8)
            }
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
        .preferredColorScheme(.dark)
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
        .sheet(isPresented: $showQuickCommandPanel) {
            QuickCommandPanelView { snippet in
                insertComposerText(snippet)
                showQuickCommandPanel = false
            }
            .presentationDetents([.fraction(0.34), .medium, .large])
            .presentationDragIndicator(.visible)
            .presentationCornerRadius(20)
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

struct MessageRow: View {
    let message: Message
    let store: ConversationStore
    let onToggleToolGroup: () -> Void
    let onToggleFileChanges: () -> Void
    let onToggleTrace: () -> Void
    let onSelectFileChange: (FileChange) -> Void
    let onSelectImage: (ImagePreviewItem) -> Void
    let onEditUserMessage: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
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
        HStack(spacing: 8) {
            Capsule()
                .fill(PiDesignSystem.Color.secondary)
                .frame(width: 10, height: 4)
            Text(message.content)
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
            Capsule()
                .fill(PiDesignSystem.Color.secondary)
                .frame(height: 1)
                .opacity(0.35)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
    }
    
    // MARK: - 常规消息行（气泡布局）
    private var normalRow: some View {
        HStack(alignment: .top, spacing: 10) {
            if !message.isUser { avatar }
            if message.isUser { Spacer(minLength: 52) }
            
            VStack(alignment: message.isUser ? .trailing : .leading, spacing: 4) {
                contentBody
                if message.kind != .tool && message.kind != .fileChanges {
                    metaRow
                }
            }
            .frame(
                maxWidth: message.kind == .text && !message.isUser ? .infinity : 308,
                alignment: message.isUser ? .trailing : .leading
            )
            
            if message.isUser { avatar }
            if !message.isUser && message.kind != .text {
                Spacer(minLength: 52)
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
                // 用户：蓝色渐变气泡
                VStack(alignment: .leading, spacing: 6) {
                    Text("命令")
                        .font(PiDesignSystem.Font.caption2)
                        .foregroundStyle(.white.opacity(0.75))
                    Text(message.content)
                        .font(PiDesignSystem.Font.monoSpan)
                        .foregroundStyle(.white)
                        .textSelection(.enabled)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .background(
                    LinearGradient(
                        colors: [PiDesignSystem.Color.userBubbleStart, PiDesignSystem.Color.userBubbleEnd],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    )
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PiDesignSystem.Radius.bubble, style: .continuous)
                        .stroke(PiDesignSystem.Color.accent.opacity(0.18), lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: PiDesignSystem.Radius.bubble, style: .continuous))
                .shadow(color: PiDesignSystem.Color.accent.opacity(0.18), radius: 10, x: 0, y: 4)
            } else {
                // Pi：最终 Markdown 正文 + 轻量 Agent Trace + 左侧 accent 条
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(message.isStreaming ? PiDesignSystem.Color.streaming : PiDesignSystem.Color.accent.opacity(0.55))
                        .frame(width: 3)
                        .padding(.vertical, 6)
                    
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
                .overlay(
                    RoundedRectangle(cornerRadius: PiDesignSystem.Radius.bubble, style: .continuous)
                        .stroke(PiDesignSystem.Color.border, lineWidth: 1)
                )
                .clipShape(RoundedRectangle(cornerRadius: PiDesignSystem.Radius.bubble, style: .continuous))
            }
        case .thinking:
            // 思考：半透明橙气泡 + 闪烁光标
            HStack(alignment: .lastTextBaseline, spacing: 3) {
                Text(message.content)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                ThinkingCursor()
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(PiDesignSystem.Color.thinking.opacity(0.12))
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
                    .font(PiDesignSystem.Font.monoSpan)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                    .lineSpacing(4)
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
            Image(systemName: "terminal.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(PiDesignSystem.Color.background)
                .padding(8)
                .background(Circle().fill(PiDesignSystem.Color.accent))
        } else if message.kind == .text || message.kind == .thinking || message.kind == .image {
            Image(systemName: "chevron.left.forwardslash.chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(PiDesignSystem.Color.background)
                .padding(7)
                .background(Circle().fill(PiDesignSystem.Color.panelElevated))
                .overlay(Circle().stroke(PiDesignSystem.Color.border, lineWidth: 1))
        }
    }
    
    // MARK: - 时间 + 送达状态
    private var metaRow: some View {
        HStack(spacing: 6) {
            if message.isUser && message.kind == .text && message.delivery == .sent {
                Button {
                    onEditUserMessage()
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundStyle(store.agentState.isWorking ? PiDesignSystem.Color.tertiary : PiDesignSystem.Color.secondary)
                }
                .buttonStyle(.plain)
                .disabled(store.agentState.isWorking)
                .accessibilityLabel("编辑这条用户消息")
            }
            if message.isUser {
                deliveryIcon
            }
            Text(message.timestamp, style: .time)
                .font(.caption2)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        }
    }
    
    /// Phase 3 NAT 穿透: 送达状态图标
    @ViewBuilder
    private var deliveryIcon: some View {
        switch message.delivery {
        case .sending:
            Image(systemName: "clock")
                .font(.caption2)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        case .sent:
            Image(systemName: "checkmark")
                .font(.caption2)
                .foregroundStyle(PiDesignSystem.Color.secondary)
        case .failed:
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(PiDesignSystem.Color.failed)
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
                                .foregroundStyle(PiDesignSystem.Color.completed)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("当前模型")
                                    .font(PiDesignSystem.Font.caption)
                                    .foregroundStyle(PiDesignSystem.Color.secondary)
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
                                .foregroundStyle(PiDesignSystem.Color.secondary)
                            Text("暂未获取到当前模型")
                                .foregroundStyle(PiDesignSystem.Color.secondary)
                        }
                    }
                }
                
                // Available models
                Section {
                    if filteredModels.isEmpty {
                        Text("无匹配模型")
                            .foregroundStyle(PiDesignSystem.Color.secondary)
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
                                        .foregroundStyle(model == currentModel ? PiDesignSystem.Color.accent : PiDesignSystem.Color.secondary)
                                    Text(model)
                                        .foregroundStyle(PiDesignSystem.Color.primary)
                                        .lineLimit(1)
                                    Spacer()
                                    if isSwitching && pendingSelection == model {
                                        ProgressView()
                                            .scaleEffect(0.7)
                                    } else if model == currentModel {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(PiDesignSystem.Color.accent)
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
                    Divider().overlay(PiDesignSystem.Color.divider)
                    ForEach(matches) { cmd in
                        Button {
                            onSelect(cmd)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: cmd.icon)
                                    .foregroundStyle(PiDesignSystem.Color.accent)
                                    .frame(width: 22)
                                Text(cmd.id)
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundStyle(PiDesignSystem.Color.primary)
                                Text(cmd.description)
                                    .font(.caption)
                                    .foregroundStyle(PiDesignSystem.Color.secondary)
                                Spacer()
                            }
                            .padding(.horizontal, 14)
                            .padding(.vertical, 10)
                        }
                        .buttonStyle(.plain)
                        if cmd.id != matches.last?.id {
                            Divider().padding(.leading, 46).overlay(PiDesignSystem.Color.divider)
                        }
                    }
                }
                .piCard(color: PiDesignSystem.Color.surface, radius: 16)
                .padding(.horizontal, 12)
            )
        }
    }
}

struct ComposerSurface: View {
    @Binding var inputText: String
    let isVoiceActive: Bool
    let speechState: VoiceState
    @Binding var isCancelPending: Bool
    let isWorking: Bool
    let onShowAttachments: () -> Void
    let onShowQuickCommands: () -> Void
    let onStartVoice: () -> Void
    let onStopVoice: () -> Void
    let onCancelVoice: () -> Void
    let onStopAgent: () -> Void
    let onSteer: () -> Void
    let onSend: () -> Void

    var body: some View {
        PiGlassComposer {
            HStack(alignment: .bottom, spacing: 10) {
                VStack(spacing: 8) {
                    composerIconButton(systemName: "plus", tint: PiDesignSystem.Color.accent, action: onShowQuickCommands)
                    composerIconButton(systemName: "photo", tint: PiDesignSystem.Color.secondary, action: onShowAttachments)
                }
                .padding(.bottom, 2)

                TextField("输入命令或消息…", text: $inputText, axis: .vertical)
                    .font(PiDesignSystem.Font.body)
                    .foregroundStyle(PiDesignSystem.Color.primary)
                    .lineLimit(1...5)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 12)
                    .piInputSurface(radius: 18)
                    .disabled(isVoiceActive)

                VoiceInputButton(
                    state: speechState,
                    isCancelPending: $isCancelPending,
                    onStart: onStartVoice,
                    onStop: onStopVoice,
                    onCancel: onCancelVoice
                )
                .frame(width: 44, height: 44)

                if isWorking {
                    if inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        composerIconButton(systemName: "stop.fill", tint: PiDesignSystem.Color.failed, filled: true, action: onStopAgent)
                    } else {
                        composerIconButton(systemName: "arrow.uturn.backward", tint: PiDesignSystem.Color.warning, filled: false, action: onSteer)
                        composerIconButton(systemName: "paperplane.fill", tint: PiDesignSystem.Color.accent, filled: true, action: onSend)
                            .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    }
                } else {
                    composerIconButton(systemName: "paperplane.fill", tint: PiDesignSystem.Color.accent, filled: true, action: onSend)
                        .disabled(inputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }

    private func composerIconButton(systemName: String, tint: SwiftUI.Color, filled: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(filled ? SwiftUI.Color.white : tint)
                .frame(width: 44, height: 44)
                .background((filled ? tint : PiDesignSystem.Color.panelElevated), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(filled ? tint.opacity(0.2) : PiDesignSystem.Color.border, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .disabled(isVoiceActive && (systemName == "paperplane.fill" || systemName == "arrow.uturn.backward" || systemName == "stop.fill"))
    }
}

struct PiGlassComposer<Content: View>: View {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    var body: some View {
        content
            .padding(12)
            .piGlassCard(radius: 22)
    }
}

struct QuickCommandDockView: View {
    let snippets = ["Esc", "Tab", "Ctrl", "↑", "↓", "←", "→", "ls -la", "htop"]
    let onInsert: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(snippets, id: \.self) { snippet in
                    Button { onInsert(mapSnippet(snippet)) } label: {
                        Text(snippet)
                            .font(snippet.count <= 4 ? PiDesignSystem.Font.captionBold : PiDesignSystem.Font.caption)
                            .foregroundStyle(PiDesignSystem.Color.primary)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 9)
                            .piCapsuleSurface()
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func mapSnippet(_ value: String) -> String {
        switch value {
        case "Esc": return "\u{1B}"
        case "Tab": return "\t"
        default: return value
        }
    }
}

struct QuickCommandPanelView: View {
    let systems = ["Esc", "Tab", "Ctrl", "Alt"]
    let navigation = ["↑", "↓", "←", "→", "Home", "End", "PgUp", "PgDn"]
    let symbols = ["/", "|", "~", "-", "."]
    let snippets = ["ls -la", "htop", "tail -f", "sudo journalctl -u"]
    let onInsert: (String) -> Void

    var body: some View {
        ZStack {
            PiDesignSystem.Color.background.ignoresSafeArea()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Quick Keys")
                        .font(PiDesignSystem.Font.headline)
                        .foregroundStyle(PiDesignSystem.Color.primary)
                    quickSection("系统键", items: systems)
                    quickSection("导航键", items: navigation)
                    quickSection("终端符号", items: symbols)
                    quickSection("历史片段", items: snippets, adaptive: 130)
                }
                .padding(20)
            }
        }
    }

    @ViewBuilder
    private func quickSection(_ title: String, items: [String], adaptive: CGFloat = 72) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(PiDesignSystem.Font.caption)
                .foregroundStyle(PiDesignSystem.Color.secondary)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: adaptive), spacing: 10)], spacing: 10) {
                ForEach(items, id: \.self) { item in
                    Button { onInsert(item) } label: {
                        Text(item)
                            .font(item.count <= 4 ? PiDesignSystem.Font.captionBold : PiDesignSystem.Font.body)
                            .foregroundStyle(PiDesignSystem.Color.primary)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .piSecondaryButton()
                }
            }
        }
    }
}
