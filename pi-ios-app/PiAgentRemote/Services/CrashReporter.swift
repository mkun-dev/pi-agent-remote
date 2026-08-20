import Foundation
import Darwin

/// 轻量崩溃采集器。
/// 捕获未处理异常（Swift 陷阱、ForEach 重复 id、数组越界、precondition 失败等都会抛 NSException）
/// 以及致命信号（SIGSEGV/SIGABRT 等），把原因与调用栈写入 Documents/crash_log.txt。
/// 这样即使在没有 Xcode 的真机上，下一次打开 App 也能看到“为什么崩”，便于精准定位。
final class CrashReporter {
    static let shared = CrashReporter()

    private let fileName = "crash_log.txt"

    private var fileURL: URL {
        let dir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return dir.appendingPathComponent(fileName)
    }

    /// 上一次崩溃的文本（若存在）。在 ContentView.init 中读取，用于决定只展示崩溃日志、避免二次崩溃。
    var lastCrash: String? {
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8),
              !text.isEmpty else { return nil }
        return text
    }

    func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }

    /// 尽早安装（在 AppDelegate.didFinishLaunchingWithOptions 最前面调用）。
    func install() {
        NSSetUncaughtExceptionHandler { exception in
            CrashReporter.shared.record(
                title: "未捕获异常: \(exception.name.rawValue)",
                detail: exception.reason ?? "（无 reason）",
                stack: exception.callStackSymbols as? [String] ?? []
            )
        }

        signal(SIGABRT, CrashReporter.handleSignal)
        signal(SIGILL, CrashReporter.handleSignal)
        signal(SIGSEGV, CrashReporter.handleSignal)
        signal(SIGFPE, CrashReporter.handleSignal)
        signal(SIGBUS, CrashReporter.handleSignal)
        signal(SIGTRAP, CrashReporter.handleSignal)
    }

    private static let handleSignal: @convention(c) (Int32) -> Void = { sig in
        var addresses = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        let frames = backtrace(&addresses, Int32(addresses.count))
        var symbols: [String] = []
        if frames > 0, let sym = backtrace_symbols(&addresses, frames) {
            for i in 0..<Int(frames) {
                if let cStr = sym[i], let s = String(validatingUTF8: cStr) {
                    symbols.append(s)
                }
            }
            free(sym)
        }
        CrashReporter.shared.record(
            title: "致命信号: \(sig)",
            detail: "signal \(sig)",
            stack: symbols
        )
        // 还原默认处理并重新触发，让系统也生成标准崩溃报告
        signal(sig, SIG_DFL)
        raise(sig)
    }

    /// 同步写文件（异常处理器返回后进程即终止，必须同步完成）。
    private func record(title: String, detail: String, stack: [String]) {
        let date = ISO8601DateFormatter().string(from: Date())
        var text = "🚨 \(title)\n时间: \(date)\n详情: \(detail)\n\n调用栈:\n" + stack.joined(separator: "\n")
        text += "\n\n（把以上内容发给我即可定位崩溃；点“清除”后可恢复正常启动）"
        try? text.write(to: fileURL, atomically: true, encoding: .utf8)
        NSLog("[CrashReporter] \(title) | \(detail)")
    }
}
