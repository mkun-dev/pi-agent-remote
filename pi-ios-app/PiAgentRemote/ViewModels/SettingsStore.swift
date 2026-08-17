import Foundation
import Combine

// 持久化连接配置
class SettingsStore: ObservableObject {
    @Published var host: String {
        didSet { UserDefaults.standard.set(host, forKey: "pi_host") }
    }
    @Published var port: Int {
        didSet { UserDefaults.standard.set(port, forKey: "pi_port") }
    }
    // Phase 3 NAT 穿透: 中继鉴权 token（仅保存在 Keychain）。
    @Published var token: String {
        didSet {
            if token.isEmpty {
                KeychainStore.delete(KeychainStore.relayTokenAccount)
            } else {
                KeychainStore.set(token, for: KeychainStore.relayTokenAccount)
            }
            // 防止旧版本残留明文 Token。
            UserDefaults.standard.removeObject(forKey: "pi_token")
        }
    }
    /// 非敏感设备标识，用于 Relay 区分重连设备；认证仍以 Token 为准。
    let clientId: String
    // Apple Speech 识别语言偏好
    @Published var voiceLanguage: VoiceRecognitionLanguage {
        didSet { UserDefaults.standard.set(voiceLanguage.rawValue, forKey: "pi_voice_language") }
    }
    
    init() {
        // 默认不内置任何服务器地址（避免泄露个人主机）；用户需在设置页填写自己的地址
        let savedHost = UserDefaults.standard.string(forKey: "pi_host") ?? ""
        let savedPort = UserDefaults.standard.integer(forKey: "pi_port")
        self.host = savedHost
        self.port = savedPort > 0 ? savedPort : 3002
        
        // 一次性迁移旧版本 UserDefaults 中的明文 Token，然后立即删除旧值。
        let legacyToken = UserDefaults.standard.string(forKey: "pi_token") ?? ""
        let secureToken = KeychainStore.string(for: KeychainStore.relayTokenAccount)
        self.token = secureToken ?? legacyToken
        if secureToken == nil && !legacyToken.isEmpty {
            KeychainStore.set(legacyToken, for: KeychainStore.relayTokenAccount)
        }
        UserDefaults.standard.removeObject(forKey: "pi_token")
        
        let storedClientId = UserDefaults.standard.string(forKey: "pi_client_id")
        let resolvedClientId: String
        if let storedClientId, !storedClientId.isEmpty {
            resolvedClientId = storedClientId
        } else {
            resolvedClientId = UUID().uuidString.lowercased()
        }
        self.clientId = resolvedClientId
        UserDefaults.standard.set(resolvedClientId, forKey: "pi_client_id")
        
        let voiceLanguageRaw = UserDefaults.standard.string(forKey: "pi_voice_language") ?? VoiceRecognitionLanguage.automatic.rawValue
        self.voiceLanguage = VoiceRecognitionLanguage(rawValue: voiceLanguageRaw) ?? .automatic
    }
    
    var wsURL: String {
        let value = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("ws://") || value.lowercased().hasPrefix("wss://") {
            guard var components = URLComponents(string: value) else { return value }
            if components.port == nil { components.port = port }
            return components.url?.absoluteString ?? value
        }
        return "ws://\(value):\(port)"
    }
}