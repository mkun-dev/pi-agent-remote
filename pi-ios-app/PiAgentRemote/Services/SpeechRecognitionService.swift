import AVFoundation
import Combine
import Foundation
import Speech

/// Apple Speech 语音转文字服务。只更新本地文本，不接触 WebSocket 或 Agent 协议。
@MainActor
final class SpeechRecognitionService: ObservableObject {
    @Published private(set) var state: VoiceState = .idle
    @Published private(set) var transcript: String = ""
    @Published private(set) var errorMessage: String?
    
    private let audioEngine = AVAudioEngine()
    private var speechRecognizer: SFSpeechRecognizer?
    private var recognitionRequest: SFSpeechAudioBufferRecognitionRequest?
    private var recognitionTask: SFSpeechRecognitionTask?
    private var finalizationWorkItem: DispatchWorkItem?
    private var activeRecognitionID = UUID()
    private var didInstallTap = false
    private var didConfigureAudioSession = false
    private var isPreparing = false
    private var stopRequested = false
    
    func startRecording(language: VoiceRecognitionLanguage) {
        guard !state.isActive else { return }
        let recognitionID = UUID()
        let requiresPermissionPrompt = Self.authorizationRequiresPrompt()
        activeRecognitionID = recognitionID
        transcript = ""
        errorMessage = nil
        stopRequested = false
        isPreparing = true
        state = .recognizing
        
        Task { [weak self] in
            let speechAuthorized = await Self.requestSpeechAuthorization()
            guard let self, self.activeRecognitionID == recognitionID else { return }
            guard speechAuthorized else {
                self.isPreparing = false
                self.fail("未获得语音识别权限，请在系统设置中开启。")
                return
            }
            let microphoneAuthorized = await Self.requestMicrophoneAuthorization()
            guard self.activeRecognitionID == recognitionID else { return }
            self.isPreparing = false
            guard microphoneAuthorized else {
                self.fail("未获得麦克风权限，请在系统设置中开启。")
                return
            }
            // 系统权限弹窗会中断按住手势；首次授权后不自动启动麦克风，避免意外持续录音。
            guard !requiresPermissionPrompt, !self.stopRequested else {
                self.state = .idle
                return
            }
            do {
                try self.beginRecognition(
                    localeIdentifier: language.localeIdentifier,
                    recognitionID: recognitionID
                )
            } catch {
                self.fail(self.readableError(error))
            }
        }
    }
    
    /// 松开按键：停止采集，等待 Apple Speech 返回最终文本。
    func stopRecording() {
        if isPreparing {
            stopRequested = true
            state = .idle
            return
        }
        guard state == .recording else { return }
        stopAudioInput()
        state = .recognizing
        scheduleFinalizationFallback(for: activeRecognitionID)
    }
    
    func cancelRecording() {
        activeRecognitionID = UUID() // 令异步权限/识别回调失效
        stopRequested = true
        isPreparing = false
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        cleanupRecognition(cancelTask: true)
        state = .idle
        transcript = ""
        errorMessage = nil
    }
    
    func reset() {
        guard !state.isActive else { return }
        state = .idle
        transcript = ""
        errorMessage = nil
    }
    
    private func beginRecognition(localeIdentifier: String, recognitionID: UUID) throws {
        guard let recognizer = SFSpeechRecognizer(locale: Locale(identifier: localeIdentifier)) else {
            throw VoiceRecognitionError.unsupportedLanguage
        }
        guard recognizer.isAvailable else {
            throw VoiceRecognitionError.recognizerUnavailable
        }
        
        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        request.taskHint = .dictation
        if recognizer.supportsOnDeviceRecognition {
            request.requiresOnDeviceRecognition = true
        }
        if #available(iOS 16.0, *) {
            request.addsPunctuation = true
        }
        speechRecognizer = recognizer
        recognitionRequest = request
        
        recognitionTask = recognizer.recognitionTask(with: request) { [weak self] result, error in
            Task { @MainActor [weak self] in
                guard let self, self.activeRecognitionID == recognitionID else { return }
                if let result {
                    self.transcript = result.bestTranscription.formattedString
                    if result.isFinal {
                        self.finishSuccessfully()
                        return
                    }
                }
                if error != nil {
                    if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        self.fail("语音识别失败，请重试。")
                    } else {
                        self.finishSuccessfully()
                    }
                }
            }
        }
        
        BackgroundAudioService.shared.suspendForVoiceRecording()
        didConfigureAudioSession = true
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: [.duckOthers])
        try session.setActive(true)
        
        let inputNode = audioEngine.inputNode
        let format = inputNode.outputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw VoiceRecognitionError.invalidAudioInput
        }
        inputNode.installTap(onBus: 0, bufferSize: 1_024, format: format) { [weak request] buffer, _ in
            request?.append(buffer)
        }
        didInstallTap = true
        audioEngine.prepare()
        try audioEngine.start()
        state = .recording
    }
    
    private func stopAudioInput() {
        if audioEngine.isRunning { audioEngine.stop() }
        if didInstallTap {
            audioEngine.inputNode.removeTap(onBus: 0)
            didInstallTap = false
        }
        recognitionRequest?.endAudio()
        deactivateRecordingSession()
    }
    
    private func finishSuccessfully() {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        activeRecognitionID = UUID()
        cleanupRecognition(cancelTask: true)
        let value = transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            fail("没有识别到语音，请重试。")
            return
        }
        transcript = value
        state = .completed
    }
    
    private func fail(_ message: String) {
        finalizationWorkItem?.cancel()
        finalizationWorkItem = nil
        activeRecognitionID = UUID()
        cleanupRecognition(cancelTask: true)
        errorMessage = message
        state = .failed
    }
    
    private func cleanupRecognition(cancelTask: Bool) {
        if audioEngine.isRunning || didInstallTap {
            stopAudioInput()
        } else if didConfigureAudioSession {
            deactivateRecordingSession()
        }
        recognitionRequest?.endAudio()
        recognitionRequest = nil
        let task = recognitionTask
        recognitionTask = nil
        if cancelTask { task?.cancel() }
        speechRecognizer = nil
    }
    
    private func deactivateRecordingSession() {
        guard didConfigureAudioSession else { return }
        didConfigureAudioSession = false
        let session = AVAudioSession.sharedInstance()
        try? session.setActive(false, options: [.notifyOthersOnDeactivation])
        BackgroundAudioService.shared.restoreAfterVoiceRecording()
    }
    
    private func scheduleFinalizationFallback(for recognitionID: UUID) {
        finalizationWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.activeRecognitionID == recognitionID, self.state == .recognizing else { return }
            if self.transcript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                self.fail("没有识别到语音，请重试。")
            } else {
                self.finishSuccessfully()
            }
        }
        finalizationWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: workItem)
    }
    
    private func readableError(_ error: Error) -> String {
        if let error = error as? VoiceRecognitionError {
            return error.message
        }
        return "无法开始录音，请检查麦克风后重试。"
    }
    
    nonisolated private static func authorizationRequiresPrompt() -> Bool {
        SFSpeechRecognizer.authorizationStatus() == .notDetermined ||
        AVAudioSession.sharedInstance().recordPermission == .undetermined
    }
    
    nonisolated private static func requestSpeechAuthorization() async -> Bool {
        await withCheckedContinuation { continuation in
            SFSpeechRecognizer.requestAuthorization { status in
                continuation.resume(returning: status == .authorized)
            }
        }
    }
    
    nonisolated private static func requestMicrophoneAuthorization() async -> Bool {
        let session = AVAudioSession.sharedInstance()
        switch session.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await withCheckedContinuation { continuation in
                session.requestRecordPermission { granted in
                    continuation.resume(returning: granted)
                }
            }
        @unknown default:
            return false
        }
    }
}

private enum VoiceRecognitionError: Error {
    case unsupportedLanguage
    case recognizerUnavailable
    case invalidAudioInput
    
    var message: String {
        switch self {
        case .unsupportedLanguage:
            return "当前设备不支持所选语音识别语言。"
        case .recognizerUnavailable:
            return "语音识别服务暂时不可用，请稍后重试。"
        case .invalidAudioInput:
            return "无法读取麦克风音频，请检查设备后重试。"
        }
    }
}
