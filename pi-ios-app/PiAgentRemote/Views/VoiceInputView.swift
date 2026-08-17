import SwiftUI
import UIKit

/// 按住说话：0.25 秒后开始，松开发起最终识别，上滑 60pt 取消。
struct VoiceInputButton: View {
    let state: VoiceState
    @Binding var isCancelPending: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onCancel: () -> Void
    
    @State private var didStartHold = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        Image(systemName: systemImage)
            .font(.system(size: 19, weight: .semibold))
            .foregroundStyle(foregroundColor)
            .frame(width: 44, height: 44)
            .piFilledCircle(backgroundColor)
            .contentShape(Circle())
            .scaleEffect(state == .recording && !reduceMotion ? 1.04 : 1)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: state)
            .gesture(holdGesture)
            .accessibilityElement()
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityHint("按住说话并松开完成；录音时上滑可取消")
            .accessibilityAction {
                if state == .recording {
                    onStop()
                } else if state == .idle || state == .completed || state == .failed {
                    onStart()
                }
            }
            .accessibilityAction(named: Text("取消语音输入")) {
                if state.isActive { onCancel() }
            }
    }
    
    private var holdGesture: some Gesture {
        LongPressGesture(minimumDuration: 0.25, maximumDistance: 30)
            .sequenced(before: DragGesture(minimumDistance: 0))
            .onChanged { value in
                switch value {
                case .first(true):
                    beginHoldIfNeeded()
                case .second(true, let drag):
                    beginHoldIfNeeded()
                    let pending = (drag?.translation.height ?? 0) < -60
                    if pending != isCancelPending {
                        isCancelPending = pending
                        UISelectionFeedbackGenerator().selectionChanged()
                    }
                default:
                    break
                }
            }
            .onEnded { value in
                guard didStartHold else { return }
                var shouldCancel = isCancelPending
                if case .second(_, let drag) = value {
                    shouldCancel = shouldCancel || (drag?.translation.height ?? 0) < -60
                }
                if shouldCancel {
                    UINotificationFeedbackGenerator().notificationOccurred(.warning)
                    onCancel()
                } else {
                    onStop()
                }
                didStartHold = false
                isCancelPending = false
            }
    }
    
    private func beginHoldIfNeeded() {
        guard !didStartHold,
              state == .idle || state == .completed || state == .failed else { return }
        didStartHold = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        onStart()
    }
    
    private var systemImage: String {
        switch state {
        case .recording: return "mic.fill"
        case .recognizing: return "waveform"
        default: return "mic"
        }
    }
    
    private var foregroundColor: Color {
        switch state {
        case .recording: return .white
        case .recognizing: return PiDesignSystem.Color.thinking
        case .failed: return PiDesignSystem.Color.failed
        default: return PiDesignSystem.Color.accent
        }
    }
    
    private var backgroundColor: Color {
        state == .recording ? PiDesignSystem.Color.failed : PiDesignSystem.Color.panelElevated
    }
    
    private var accessibilityLabel: String {
        switch state {
        case .idle, .completed, .failed: return "语音输入"
        case .recording: return "正在录音"
        case .recognizing: return "正在识别语音"
        }
    }
}

struct VoiceRecordingBanner: View {
    let state: VoiceState
    let transcript: String
    let isCancelPending: Bool
    let onCancel: () -> Void
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isCancelPending ? "xmark.circle.fill" : iconName)
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isCancelPending ? PiDesignSystem.Color.failed : PiDesignSystem.Color.accent)
                .frame(width: 28, height: 28)
                .accessibilityHidden(true)
            
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(PiDesignSystem.Font.subheadline)
                    .foregroundStyle(isCancelPending ? PiDesignSystem.Color.failed : PiDesignSystem.Color.primary)
                Text(detail)
                    .font(transcript.isEmpty ? PiDesignSystem.Font.caption : PiDesignSystem.Font.body)
                    .foregroundStyle(PiDesignSystem.Color.secondary)
                    .lineLimit(2)
            }
            
            Spacer(minLength: 8)
            
            Button("取消", action: onCancel)
                .font(PiDesignSystem.Font.captionBold)
                .frame(minWidth: 44, minHeight: 44)
                .buttonStyle(.plain)
                .foregroundStyle(PiDesignSystem.Color.failed)
                .accessibilityHint("放弃本次语音识别并恢复原输入")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .piTintPanel(isCancelPending ? PiDesignSystem.Color.failed : PiDesignSystem.Color.accent)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.18), value: isCancelPending)
        .accessibilityElement(children: .contain)
    }
    
    private var iconName: String {
        state == .recording ? "mic.fill" : "waveform"
    }
    
    private var title: String {
        if isCancelPending { return "松开取消" }
        return state == .recording ? "正在录音" : "正在识别"
    }
    
    private var detail: String {
        if isCancelPending { return "松开后不会保留本次内容" }
        if !transcript.isEmpty { return transcript }
        return state == .recording ? "请说话… · 上滑取消" : "正在准备语音识别…"
    }
}
