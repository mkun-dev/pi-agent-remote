import SwiftUI

/// Pi 最终回复的打字动画：逐字 reveal，速度随文本长度自适应（约 6 秒播完），完成后光标消失。
/// 已播放完成的消息（按 animationKey 缓存）重新出现时直接显示全文，不重播。
struct TypewriterText: View {
    let markdown: String
    var animationKey: String? = nil

    /// 已完成播放的消息 key 缓存（避免 LazyVStack 滚动离屏再回来时重播）
    private static var finishedKeys: Set<String> = []

    private let tickInterval: TimeInterval = 0.016
    @State private var full: AttributedString = AttributedString()
    @State private var count = 0
    @State private var chunkSize = 2
    @State private var timerEnabled = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if isPlayedFully {
                Text(full).textSelection(.enabled)
            } else {
                // 打字动画：纯文本逐字 + 闪烁光标（Text + 运算符要求两侧都是 Text）
                let content: Text = Text(String(full.characters.prefix(count)))
                    + Text("▍").foregroundColor(PiDesignSystem.Color.thinking)
                if timerEnabled {
                    content
                        .onReceive(Timer.publish(every: tickInterval, on: .main, in: .common).autoconnect()) { _ in
                            guard !isPlayedFully, count < full.characters.count else {
                                markFinished()
                                timerEnabled = false
                                return
                            }
                            count = min(count + chunkSize, full.characters.count)
                            if count >= full.characters.count {
                                markFinished()
                                timerEnabled = false
                            }
                        }
                } else {
                    content
                }
            }
        }
        .onAppear { prepare() }
        .onChange(of: markdown) { _ in
            timerEnabled = true
            prepare()
        }
    }

    /// 该消息是否已完整播放过（缓存命中 → 直接显示全文）
    private var isPlayedFully: Bool {
        guard let key = animationKey else { return false }
        return Self.finishedKeys.contains(key)
    }

    private func prepare() {
        full = parseInlineMarkdown(markdown)
        if isPlayedFully {
            count = full.characters.count
            return
        }
        count = 0
        let total = full.characters.count
        if total > 0 {
            // 目标时长约 6 秒：每秒约 62.5 tick
            chunkSize = max(2, Int(Double(total) / 6.0 * 62.5))
        }
    }

    private func markFinished() {
        guard let key = animationKey else { return }
        Self.finishedKeys.insert(key)
    }
}

/// Assistant / thinking 流式消息末尾的闪烁光标。
struct StreamingCursor: View {
    @State private var visible = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Text("▍")
            .foregroundStyle(PiDesignSystem.Color.thinking)
            .opacity(reduceMotion ? 1 : (visible ? 1 : 0))
            .accessibilityHidden(true)
            .onReceive(Timer.publish(every: 0.5, on: .main, in: .common).autoconnect()) { _ in
                if !reduceMotion { visible.toggle() }
            }
    }
}

/// 保留原有名称，供思考过程复用同一光标表现。
struct ThinkingCursor: View {
    var body: some View {
        StreamingCursor()
    }
}
