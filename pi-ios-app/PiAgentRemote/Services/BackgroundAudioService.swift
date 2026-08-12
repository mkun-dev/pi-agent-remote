import AVFoundation
import UIKit

/// 后台保活服务：播放静音音频保持 App 在后台不被挂起，维持 WebSocket 连接
final class BackgroundAudioService: NSObject {
    static let shared = BackgroundAudioService()
    
    private var player: AVAudioPlayer?
    private var isPlaying = false
    private var shouldKeepAlive = false
    
    private override init() {
        super.init()
        setup()
    }
    
    private func setup() {
        // 音频会话：Playback 类别（允许后台播放）
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        
        // 生成静音 WAV（仅首次创建，复用已有文件避免每次启动重写 ~9MB）
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent_keepalive.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            if let wavURL = createSilentWAV(durationSeconds: 600) {
                // createSilentWAV 已写入同一路径
            }
        }
        player = try? AVAudioPlayer(contentsOf: url)
        player?.numberOfLoops = -1  // 无限循环
        player?.volume = 0.0        // 静音
        player?.prepareToPlay()
        
        // 监听 App 生命周期
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appDidEnterBackground),
            name: UIApplication.didEnterBackgroundNotification,
            object: nil
        )
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(appWillEnterForeground),
            name: UIApplication.willEnterForegroundNotification,
            object: nil
        )
    }
    
    /// 生成静音 WAV 文件（不依赖外部资源）
    private func createSilentWAV(durationSeconds: Int) -> URL? {
        let sampleRate = 8000
        let numSamples = sampleRate * durationSeconds
        let dataSize = numSamples * 2  // 16-bit = 2 bytes per sample
        
        var wav = Data()
        // RIFF header
        wav.append("RIFF".data(using: .ascii)!)
        var fileSize = UInt32(36 + dataSize).littleEndian
        wav.append(Data(bytes: &fileSize, count: MemoryLayout<UInt32>.size))
        wav.append("WAVE".data(using: .ascii)!)
        
        // fmt chunk
        wav.append("fmt ".data(using: .ascii)!)
        var chunkSize = UInt32(16).littleEndian
        wav.append(Data(bytes: &chunkSize, count: MemoryLayout<UInt32>.size))
        var audioFormat = UInt16(1).littleEndian   // PCM
        wav.append(Data(bytes: &audioFormat, count: MemoryLayout<UInt16>.size))
        var channels = UInt16(1).littleEndian      // Mono
        wav.append(Data(bytes: &channels, count: MemoryLayout<UInt16>.size))
        var sr = UInt32(sampleRate).littleEndian
        wav.append(Data(bytes: &sr, count: MemoryLayout<UInt32>.size))
        var byteRate = UInt32(sampleRate * 2).littleEndian
        wav.append(Data(bytes: &byteRate, count: MemoryLayout<UInt32>.size))
        var blockAlign = UInt16(2).littleEndian
        wav.append(Data(bytes: &blockAlign, count: MemoryLayout<UInt16>.size))
        var bitsPerSample = UInt16(16).littleEndian
        wav.append(Data(bytes: &bitsPerSample, count: MemoryLayout<UInt16>.size))
        
        // data chunk (zeros = silence)
        wav.append("data".data(using: .ascii)!)
        var ds = UInt32(dataSize).littleEndian
        wav.append(Data(bytes: &ds, count: MemoryLayout<UInt32>.size))
        wav.append(Data(count: dataSize))
        
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("silent_keepalive.wav")
        try? wav.write(to: url)
        return url
    }
    
    func startKeepAlive() {
        shouldKeepAlive = true
        if UIApplication.shared.applicationState == .background {
            startPlayback()
        }
    }
    
    func stopKeepAlive() {
        shouldKeepAlive = false
        stopPlayback()
    }
    
    /// 语音输入开始前暂停静音播放器，避免占用 playback 音频会话。
    func suspendForVoiceRecording() {
        stopPlayback()
    }
    
    /// 语音输入结束后恢复原有后台保活音频配置。
    func restoreAfterVoiceRecording() {
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        if shouldKeepAlive && UIApplication.shared.applicationState == .background {
            startPlayback()
        }
    }
    
    @objc private func appDidEnterBackground() {
        guard shouldKeepAlive else { return }
        startPlayback()
    }
    
    @objc private func appWillEnterForeground() {
        stopPlayback()
    }
    
    private func startPlayback() {
        guard !isPlaying else { return }
        isPlaying = true
        player?.play()
    }
    
    private func stopPlayback() {
        isPlaying = false
        player?.stop()
    }
}
