import Foundation

/// 一个邀请就是一条链接 `https://<域名>/i/<token>`，二维码就是这条链接（2026-11-09 起不再有 6 位邀请码）
public struct InviteRef: Equatable, Hashable, Sendable {
    public let token: String
    public init(token: String) { self.token = token }
    public static func token(_ t: String) -> InviteRef { InviteRef(token: t) }
}

public enum InviteLink {
    /// App 的自定义 scheme：落地页上“打开「安全回家」”按钮用 `anquanhuijia://i/<token>`
    public static let appScheme = "anquanhuijia"

    /**
     解析扫到的二维码、打开的通用链接或自定义 scheme。只认本 App 的域名，其他二维码一律不跳转、不打开。
     - `https://<域名>/i/<token>` → token
     - `anquanhuijia://i/<token>` → token
     */
    public static func parse(_ raw: String, allowedHosts: Set<String>) -> InviteRef? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased() else { return nil }
        let parts: [String]
        if scheme == appScheme {
            // anquanhuijia://i/<token>：host 是 "i"，路径是 /<token>
            guard url.host?.lowercased() == "i" else { return nil }
            parts = ["i"] + url.path.split(separator: "/").map(String.init)
        } else {
            guard scheme == "https" || scheme == "http", let host = url.host?.lowercased(), allowedHosts.contains(host) else { return nil }
            parts = url.path.split(separator: "/").map(String.init)
        }
        guard parts.count == 2, parts[0] == "i" else { return nil }
        let token = parts[1]
        guard (8...64).contains(token.count), token.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { return nil }
        return .token(token)
    }

    /**
     从一段文字里找邀请链接：微信里复制的可能是整段分享文字
     “小林邀请你成为她的担保人…… https://ye.example.com/i/xxxx”，链接前后可能紧挨着中文或标点。
     */
    public static func find(in text: String, allowedHosts: Set<String>) -> InviteRef? {
        if let ref = parse(text, allowedHosts: allowedHosts) { return ref }
        let lower = text.lowercased()
        for prefix in ["https://", "http://", "\(appScheme)://"] {
            var searchFrom = lower.startIndex
            while let r = lower.range(of: prefix, range: searchFrom..<lower.endIndex) {
                // 链接只由 ASCII 可见字符组成，遇到中文、空白就停
                var end = r.upperBound
                while end < lower.endIndex, let a = lower[end].asciiValue, a > 32, a < 127, !"\"'<>，。".contains(lower[end]) {
                    end = lower.index(after: end)
                }
                var candidate = String(text[r.lowerBound..<end])
                while let last = candidate.last, ".,;:!?)]}".contains(last) { candidate.removeLast() }
                if let ref = parse(candidate, allowedHosts: allowedHosts) { return ref }
                searchFrom = r.upperBound
            }
        }
        return nil
    }

    /// 发到微信里的那段文字：一句说明加链接，朋友点链接或复制整段打开 App 都能接上
    public static func shareText(inviterName: String, kind: InviteKind = .standing, url: String) -> String {
        let what = kind == .standing ? "以后回家时可以互相守护" : "今晚回家时临时互相守护"
        return "\(inviterName)邀请你在「安全回家」加好友，\(what)。点开链接，或复制这段话后打开「安全回家」：\(url)"
    }
}
