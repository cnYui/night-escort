import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(ActivityKit) && os(iOS)
import ActivityKit
#endif

/// 手机、手表、小组件共用的常量。
public enum AppConstants {
    /// App Group：手机 App 和小组件共享数据
    public static let appGroup = "group.app.nightescort"
    /// 钥匙串访问组前缀以外的部分（手机和手表各自保存）
    public static let keychainService = "app.nightescort.tokens"
    /// 通知按钮组，和后端 notifier.ts 里的 category 一致
    public enum Category {
        public static let checkin = "CHECKIN"
        public static let incident = "INCIDENT"
        public static let pauseMorning = "PAUSE_MORNING"
        public static let cap = "CAP"
        public static let home = "HOME"
    }
    public enum Action {
        public static let ok = "CHECKIN_OK"
        public static let arrived = "CHECKIN_ARRIVED"
        public static let elsewhere = "CHECKIN_ELSEWHERE"
        public static let snooze = "INCIDENT_SNOOZE"
        public static let open = "INCIDENT_OPEN"
        public static let endEscort = "END_ESCORT"
        public static let homeYes = "HOME_YES"
        public static let homeNo = "HOME_NO"
    }
}

/// 手机 ↔ 手表 WatchConnectivity 消息
public enum WatchMessage: Codable, Equatable, Sendable {
    /// 手机把手表专用的登录令牌交给手表（手表不输密码）
    case tokens(TokenPair, baseURL: String)
    /// 我的家（只存本机，同步给手表做到家判断）
    case homePlaces([HomePlace])
    /// 护航状态变了，手表刷新
    case escortChanged
    case signedOut

    public func encoded() throws -> [String: Any] {
        ["m": try JSON.encoder.encode(self)]
    }

    public static func decode(_ dict: [String: Any]) -> WatchMessage? {
        guard let data = dict["m"] as? Data else { return nil }
        return try? JSON.decoder.decode(WatchMessage.self, from: data)
    }
}

#if canImport(Security)
/// 登录令牌存钥匙串。
public final class KeychainTokenStore: TokenStore, @unchecked Sendable {
    private let account: String
    private let accessGroup: String?
    private var cache: TokenPair?
    private let lock = NSLock()

    public init(account: String = "default", accessGroup: String? = nil) {
        self.account = account
        self.accessGroup = accessGroup
    }

    private var query: [String: Any] {
        var q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        if let g = accessGroup { q[kSecAttrAccessGroup as String] = g }
        return q
    }

    public func load() -> TokenPair? {
        lock.lock(); defer { lock.unlock() }
        if let c = cache { return c }
        var q = query
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        cache = try? JSON.decoder.decode(TokenPair.self, from: data)
        return cache
    }

    public func save(_ tokens: TokenPair?) {
        lock.lock(); defer { lock.unlock() }
        cache = tokens
        SecItemDelete(query as CFDictionary)
        guard let tokens, let data = try? JSON.encoder.encode(tokens) else { return }
        var q = query
        q[kSecValueData as String] = data
        // 锁屏后台也要能用（通知按钮“我没事”在后台发请求）
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            // 常见是 -34018（没签名、缺钥匙串权限），这时下次启动就读不到登录状态
            NSLog("KeychainTokenStore: 保存登录令牌失败 OSStatus=%d", status)
        }
    }
}

/// “我的家”存钥匙串，不上传。
public enum HomePlaceStore {
    private static let account = "home-places"

    public static func load() -> [HomePlace] {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var out: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return [] }
        return (try? JSONDecoder().decode([HomePlace].self, from: data)) ?? []
    }

    public static func save(_ places: [HomePlace]) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: AppConstants.keychainService,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(base as CFDictionary)
        guard let data = try? JSONEncoder().encode(Array(places.prefix(HomePlace.maxCount))) else { return }
        var q = base
        q[kSecValueData as String] = data
        q[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = SecItemAdd(q as CFDictionary, nil)
        if status != errSecSuccess {
            // 常见是 -34018（没签名、缺钥匙串权限），这时下次启动就读不到登录状态
            NSLog("KeychainTokenStore: 保存登录令牌失败 OSStatus=%d", status)
        }
    }
}
#endif

#if canImport(ActivityKit) && os(iOS)
/// 灵动岛和锁屏实时活动（服务端通过 ActivityKit 推送更新 content-state）
public struct EscortActivityAttributes: ActivityAttributes {
    /// 服务端推送时用 Unix 秒传时间（ActivityKit 用默认解码器，不认 ISO 字符串）
    public struct ContentState: Codable, Hashable {
        public var status: String
        public var nextDueAtEpoch: Double?
        public var guardianCount: Int
        public var contactingName: String?

        public var nextDueAt: Date? { nextDueAtEpoch.map { Date(timeIntervalSince1970: $0) } }

        public init(status: String, nextDueAt: Date?, guardianCount: Int, contactingName: String? = nil) {
            self.status = status
            self.nextDueAtEpoch = nextDueAt?.timeIntervalSince1970
            self.guardianCount = guardianCount
            self.contactingName = contactingName
        }
    }

    public var escortId: String
    public init(escortId: String) { self.escortId = escortId }
}
#endif
