import CryptoKit
import Foundation
import UIKit

/// 图片内存 + 磁盘缓存。协议仍传 base64；缓存用于避免重复解码并保留本地预览。
final class ImageCache {
    static let shared = ImageCache()
    
    private let memory = NSCache<NSString, UIImage>()
    private let ioQueue = DispatchQueue(label: "com.piagent.remote.image-cache", qos: .utility)
    private let directory: URL
    private let maxDiskBytes = 200 * 1024 * 1024
    
    private init() {
        let root = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        directory = root.appendingPathComponent("PiAgentRemoteImages", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        memory.totalCostLimit = 80 * 1024 * 1024
        memory.countLimit = 120
        ioQueue.async { [weak self] in self?.pruneDiskCacheIfNeeded() }
    }
    
    static func cacheKey(for data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    
    /// 立即写入内存，磁盘写入放到 utility queue；返回可持久化 localPath。
    @discardableResult
    func store(_ data: Data, key: String) -> String {
        if let image = UIImage(data: data) {
            memory.setObject(image, forKey: key as NSString, cost: data.count)
        }
        let url = diskURL(for: key)
        ioQueue.async {
            if !FileManager.default.fileExists(atPath: url.path) {
                try? data.write(to: url, options: .atomic)
            }
        }
        return url.path
    }
    
    func memoryImage(for key: String) -> UIImage? {
        memory.object(forKey: key as NSString)
    }
    
    func image(
        for key: String,
        localPath: String? = nil,
        fallbackData: Data? = nil
    ) async -> UIImage? {
        if let cached = memoryImage(for: key) { return cached }
        let defaultURL = diskURL(for: key)
        return await withCheckedContinuation { continuation in
            ioQueue.async { [weak self] in
                guard let self else {
                    continuation.resume(returning: nil)
                    return
                }
                let preferredURL = localPath.map { URL(fileURLWithPath: $0) } ?? defaultURL
                var data = try? Data(contentsOf: preferredURL, options: [.mappedIfSafe])
                if data == nil, preferredURL != defaultURL {
                    data = try? Data(contentsOf: defaultURL, options: [.mappedIfSafe])
                }
                if data == nil, let fallbackData {
                    data = fallbackData
                    try? fallbackData.write(to: defaultURL, options: .atomic)
                }
                guard let data, let image = UIImage(data: data) else {
                    continuation.resume(returning: nil)
                    return
                }
                self.memory.setObject(image, forKey: key as NSString, cost: data.count)
                continuation.resume(returning: image)
            }
        }
    }
    
    private func diskURL(for key: String) -> URL {
        let safeKey = key.filter { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }
        return directory.appendingPathComponent(safeKey + ".image")
    }
    
    private func pruneDiskCacheIfNeeded() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard var files = try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        ) else { return }
        var total = files.reduce(0) { partial, url in
            partial + ((try? url.resourceValues(forKeys: keys).fileSize) ?? 0)
        }
        guard total > maxDiskBytes else { return }
        files.sort {
            let lhs = (try? $0.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            let rhs = (try? $1.resourceValues(forKeys: keys).contentModificationDate) ?? .distantPast
            return lhs < rhs
        }
        for file in files where total > maxDiskBytes {
            let size = (try? file.resourceValues(forKeys: keys).fileSize) ?? 0
            try? FileManager.default.removeItem(at: file)
            total -= size
        }
    }
}
