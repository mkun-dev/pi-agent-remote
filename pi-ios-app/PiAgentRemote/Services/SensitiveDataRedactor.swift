import Foundation

/// 所有技术日志共用的敏感信息过滤器。
enum SensitiveDataRedactor {
    private static let rules: [(NSRegularExpression, String)] = [
        rule(#"(?i)(wss?://[^/@:\s"']+:)[^@\s"']+@"#, "$1••••@"),
        rule(#"(?i)(authorization\s*[:=]\s*bearer\s+)[^\s\"']+"#, "$1••••"),
        rule(#"(?i)([?&](?:token|auth_token|access_token)=)[^&\s\"']+"#, "$1••••"),
        rule(#"(?i)(--(?:token|auth-token|access-token|api-key|password)\s+)[^\s\"']+"#, "$1••••"),
        rule(#"(?i)([\"']?(?:relayToken|localToken|authToken|accessToken|refreshToken|relay_token|local_token|auth_token|access_token|refresh_token|api[_-]?key|secret|password|passwd)[\"']?\s*[:=]\s*)[\"']?[^\s,\"'}]+[\"']?"#, "$1••••")
    ]
    
    static func redact(_ value: String) -> String {
        rules.reduce(value) { result, item in
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            return item.0.stringByReplacingMatches(
                in: result,
                options: [],
                range: range,
                withTemplate: item.1
            )
        }
    }
    
    private static func rule(_ pattern: String, _ replacement: String) -> (NSRegularExpression, String) {
        let expression = (try? NSRegularExpression(pattern: pattern))
            ?? (try! NSRegularExpression(pattern: #"a\b\B"#))
        return (expression, replacement)
    }
}
