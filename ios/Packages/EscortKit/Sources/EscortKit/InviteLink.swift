import Foundation

/// 二维码、6 位邀请码和链接是同一个东西（设计文档 8 节）
public enum InviteRef: Equatable, Hashable, Sendable {
    case token(String)
    case code(String)
}

public enum InviteLink {
    /**
     解析扫到的内容或打开的通用链接。只认本 App 的域名，其他二维码一律不跳转、不打开。
     - `https://<域名>/i/<token>` → .token
     - 6 位数字 → .code
     */
    public static func parse(_ raw: String, allowedHosts: Set<String>) -> InviteRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.count == 6, s.allSatisfy({ $0.isASCII && $0.isNumber }) { return .code(s) }
        guard let url = URL(string: s), let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
        guard url.scheme == "https" || url.scheme == "http" else { return nil }
        let parts = url.path.split(separator: "/").map(String.init)
        guard parts.count == 2, parts[0] == "i" else { return nil }
        let token = parts[1]
        guard (8...64).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return .token(token)
    }

    /// 从剪贴板文字里找 6 位邀请码（“粘贴邀请码”按钮用）
    public static func findCode(in text: String) -> String? {
        var run = ""
        for ch in text {
            if ch.isASCII && ch.isNumber {
                run.append(ch)
            } else {
                if run.count == 6 { return run }
                run = ""
            }
        }
        return run.count == 6 ? run : nil
    }
}
