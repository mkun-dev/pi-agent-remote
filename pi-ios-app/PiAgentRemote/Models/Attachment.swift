import Foundation

enum AttachmentType: Equatable {
    case image
}

enum AttachmentStatus: Equatable {
    case uploading
    case processing
    case completed
    case failed
}

struct Attachment: Identifiable, Equatable {
    let id: String
    let type: AttachmentType
    let fileName: String
    var url: String? = nil
    var localPath: String? = nil
    let cacheKey: String
    var status: AttachmentStatus
    var errorMessage: String? = nil
}

/// 相册选择器完成压缩后的纯 iOS 上传对象，不进入 WebSocket 协议模型。
struct PreparedImageUpload: Identifiable {
    let id: String
    let fileName: String
    let data: Data
    let base64: String
    let cacheKey: String
}
