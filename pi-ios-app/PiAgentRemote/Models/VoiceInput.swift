import Foundation

enum VoiceState: Equatable {
    case idle
    case recording
    case recognizing
    case completed
    case failed
    
    var isActive: Bool {
        self == .recording || self == .recognizing
    }
}

enum VoiceRecognitionLanguage: String, CaseIterable, Identifiable, Hashable {
    case automatic
    case chinese
    case english
    
    var id: String { rawValue }
    
    var displayName: String {
        switch self {
        case .automatic: return "跟随系统"
        case .chinese: return "中文"
        case .english: return "English"
        }
    }
    
    var localeIdentifier: String {
        switch self {
        case .chinese:
            return "zh-CN"
        case .english:
            return "en-US"
        case .automatic:
            let preferred = Locale.preferredLanguages.first?.lowercased() ?? "zh"
            return preferred.hasPrefix("en") ? "en-US" : "zh-CN"
        }
    }
}
