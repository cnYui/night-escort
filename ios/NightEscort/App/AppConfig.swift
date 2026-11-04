import Foundation

enum AppConfig {
    /// 后端地址，来自 Info.plist 的 NEApiBaseURL（project.yml 里的 API_BASE_URL 构建设置）
    static var apiBaseURL: URL {
        let s = Bundle.main.object(forInfoDictionaryKey: "NEApiBaseURL") as? String ?? "https://api.example.com"
        return URL(string: s) ?? URL(string: "https://api.example.com")!
    }

    /// 邀请链接的域名（https://<域名>/i/<token>），扫码时只认这些
    static var inviteHosts: Set<String> {
        let s = Bundle.main.object(forInfoDictionaryKey: "NEInviteHost") as? String ?? "ye.example.com"
        return Set(s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() })
    }

    static var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// 调试包推送走 sandbox 环境
    static var apnsEnv: String {
        #if DEBUG
        return "sandbox"
        #else
        return "production"
        #endif
    }
}
