import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public struct APIError: Error, LocalizedError, Sendable {
    public let status: Int
    public let code: String
    public let message: String

    public var errorDescription: String? { message }

    public static let network = APIError(status: 0, code: "network", message: "网络不太好，请稍后再试")
}

/// 保存登录令牌。App 里用钥匙串实现，测试里用内存。
public protocol TokenStore: AnyObject, Sendable {
    func load() -> TokenPair?
    func save(_ tokens: TokenPair?)
}

public final class MemoryTokenStore: TokenStore, @unchecked Sendable {
    private var tokens: TokenPair?
    private let lock = NSLock()
    public init(_ tokens: TokenPair? = nil) { self.tokens = tokens }
    public func load() -> TokenPair? { lock.lock(); defer { lock.unlock() }; return tokens }
    public func save(_ tokens: TokenPair?) { lock.lock(); self.tokens = tokens; lock.unlock() }
}

/// 发请求的那一层抽出来，测试里可以替换。
public protocol HTTPTransport: Sendable {
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse)
}

public struct URLSessionTransport: HTTPTransport {
    let session: URLSession
    public init(session: URLSession = .shared) { self.session = session }
    public func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, resp) = try await session.data(for: request)
        guard let http = resp as? HTTPURLResponse else { throw APIError.network }
        return (data, http)
    }
}

public enum JSON {
    public static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .custom { dec in
            let s = try dec.singleValueContainer().decode(String.self)
            if let date = parseDate(s) { return date }
            throw DecodingError.dataCorrupted(.init(codingPath: dec.codingPath, debugDescription: "bad date \(s)"))
        }
        return d
    }()

    public static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .custom { date, enc in
            var c = enc.singleValueContainer()
            try c.encode(formatDate(date))
        }
        return e
    }()

    public static func parseDate(_ s: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFraction.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    public static func formatDate(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }
}

/// 安全回家后端客户端。访问令牌过期时自动用刷新令牌换一次。
public final class APIClient: @unchecked Sendable {
    public let baseURL: URL
    public let tokens: TokenStore
    let transport: HTTPTransport
    public var device: DeviceInfo
    /// 刷新令牌也失效时回调（App 退回登录页）
    public var onSignedOut: (@Sendable () -> Void)?

    public init(baseURL: URL, tokens: TokenStore, device: DeviceInfo, transport: HTTPTransport = URLSessionTransport()) {
        self.baseURL = baseURL
        self.tokens = tokens
        self.device = device
        self.transport = transport
    }

    public var isSignedIn: Bool { tokens.load() != nil }

    // MARK: 底层

    struct Empty: Encodable {}

    func request<T: Decodable>(_ method: String, _ path: String, body: (any Encodable)? = nil, auth: Bool = true, retry: Bool = true) async throws -> T {
        guard let url = URL(string: path, relativeTo: baseURL) else { throw APIError(status: 0, code: "bad_url", message: "地址不对") }
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 20
        req.setValue("application/json", forHTTPHeaderField: "accept")
        if let body {
            req.setValue("application/json", forHTTPHeaderField: "content-type")
            req.httpBody = try JSON.encoder.encode(AnyEncodable(body))
        }
        if auth, let t = tokens.load() {
            req.setValue("Bearer \(t.accessToken)", forHTTPHeaderField: "authorization")
        }
        let data: Data
        let resp: HTTPURLResponse
        do {
            (data, resp) = try await transport.send(req)
        } catch let e as APIError {
            throw e
        } catch {
            throw APIError.network
        }
        if resp.statusCode == 401 && auth && retry, try await refresh() {
            return try await request(method, path, body: body, auth: auth, retry: false)
        }
        guard (200..<300).contains(resp.statusCode) else {
            throw Self.decodeError(data, status: resp.statusCode)
        }
        if T.self == OK.self && data.isEmpty { return OK(ok: true) as! T }
        do {
            return try JSON.decoder.decode(T.self, from: data)
        } catch {
            throw APIError(status: resp.statusCode, code: "decode", message: "数据格式不对：\(error)")
        }
    }

    static func decodeError(_ data: Data, status: Int) -> APIError {
        struct Body: Decodable { struct E: Decodable { let code: String; let message: String }; let error: E }
        if let b = try? JSON.decoder.decode(Body.self, from: data) {
            return APIError(status: status, code: b.error.code, message: b.error.message)
        }
        return APIError(status: status, code: "http_\(status)", message: "服务出了点问题（\(status)）")
    }

    private func refresh() async throws -> Bool {
        guard let t = tokens.load() else { return false }
        struct Body: Encodable { let refreshToken: String }
        do {
            let pair: TokenPair = try await request("POST", "/v1/auth/refresh", body: Body(refreshToken: t.refreshToken), auth: false, retry: false)
            tokens.save(pair)
            return true
        } catch let e as APIError where e.status == 401 {
            tokens.save(nil)
            onSignedOut?()
            return false
        }
    }

    private func handleLogin(_ o: LoginOutcome) -> LoginOutcome {
        if o.status == .ok, let t = o.tokens { tokens.save(t) }
        return o
    }

    // MARK: 登录（设计文档第 9 节）

    public enum SmsPurpose: String, Encodable, Sendable { case login, bind, reset, changePhone = "change_phone" }

    public func sendSmsCode(phone: String, purpose: SmsPurpose = .login) async throws {
        struct B: Encodable { let phone: String; let purpose: SmsPurpose }
        let _: OK = try await request("POST", "/v1/auth/sms/send", body: B(phone: phone, purpose: purpose), auth: false)
    }

    public func loginWithSms(phone: String, code: String) async throws -> LoginOutcome {
        struct B: Encodable { let phone: String; let code: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/sms/login", body: B(phone: phone, code: code, device: device), auth: false))
    }

    public func loginWithPassword(phone: String, password: String) async throws -> LoginOutcome {
        struct B: Encodable { let phone: String; let password: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/password/login", body: B(phone: phone, password: password, device: device), auth: false))
    }

    public func signup(ticket: String, password: String, displayName: String, timeZone: String = TimeZone.current.identifier) async throws -> LoginOutcome {
        struct B: Encodable { let signupTicket: String; let password: String; let displayName: String; let timeZone: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/signup", body: B(signupTicket: ticket, password: password, displayName: displayName, timeZone: timeZone, device: device), auth: false))
    }

    public func loginWithWeChat(code: String) async throws -> LoginOutcome {
        struct B: Encodable { let code: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/wechat", body: B(code: code, device: device), auth: false))
    }

    public func loginWithApple(identityToken: String) async throws -> LoginOutcome {
        struct B: Encodable { let identityToken: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/apple", body: B(identityToken: identityToken, device: device), auth: false))
    }

    public func bindPhone(ticket: String, phone: String, code: String) async throws -> LoginOutcome {
        struct B: Encodable { let bindTicket: String; let phone: String; let code: String; let device: DeviceInfo }
        return handleLogin(try await request("POST", "/v1/auth/bind-phone", body: B(bindTicket: ticket, phone: phone, code: code, device: device), auth: false))
    }

    public func resetPassword(phone: String, code: String, newPassword: String) async throws {
        struct B: Encodable { let phone: String; let code: String; let newPassword: String }
        let _: OK = try await request("POST", "/v1/auth/password/reset", body: B(phone: phone, code: code, newPassword: newPassword), auth: false)
    }

    /// 手表通过手机授权登录：手机调用后把结果经 WatchConnectivity 交给手表
    public func watchTokens() async throws -> TokenPair {
        try await request("POST", "/v1/auth/watch-token", body: Empty())
    }

    public func logout() async {
        _ = try? await (request("POST", "/v1/auth/logout", body: Empty()) as OK)
        tokens.save(nil)
    }

    public func me() async throws -> PublicUser { try await request("GET", "/v1/me") }

    public func updateProfile(displayName: String? = nil, timeZone: String? = nil) async throws -> PublicUser {
        struct B: Encodable { let displayName: String?; let timeZone: String? }
        return try await request("PATCH", "/v1/me", body: B(displayName: displayName, timeZone: timeZone))
    }

    public func deleteAccount() async throws {
        let _: OK = try await request("DELETE", "/v1/me")
        tokens.save(nil)
    }

    public struct DeviceUpdate: Encodable, Sendable {
        public var apnsToken: String?
        public var apnsEnv: String?
        public var liveActivityToken: String?
        public var appVersion: String?
        public var notifAllowed: Bool?
        public var criticalAllowed: Bool?
        public var opened: Bool?
        public init(apnsToken: String? = nil, apnsEnv: String? = nil, liveActivityToken: String? = nil, appVersion: String? = nil, notifAllowed: Bool? = nil, criticalAllowed: Bool? = nil, opened: Bool? = nil) {
            self.apnsToken = apnsToken
            self.apnsEnv = apnsEnv
            self.liveActivityToken = liveActivityToken
            self.appVersion = appVersion
            self.notifAllowed = notifAllowed
            self.criticalAllowed = criticalAllowed
            self.opened = opened
        }
    }

    /// App 每次打开都上报通知权限和最近打开时间（担保人就绪检查）
    public func updateDevice(_ u: DeviceUpdate) async throws {
        let _: OK = try await request("PUT", "/v1/devices/current", body: u)
    }

    // MARK: 邀请

    public func createInvite(kind: InviteKind, template: TemporaryTemplate? = nil) async throws -> Invite {
        struct B: Encodable { let kind: InviteKind; let template: TemporaryTemplate? }
        return try await request("POST", "/v1/invites", body: B(kind: kind, template: template))
    }

    public func inviteStatus(id: String) async throws -> Invite { try await request("GET", "/v1/invites/\(id)") }
    public func refreshInvite(id: String) async throws -> Invite { try await request("POST", "/v1/invites/\(id)/refresh", body: Empty()) }

    public func previewInvite(_ ref: InviteRef) async throws -> InvitePreview {
        try await request("GET", "/v1/invites/preview?token=\(ref.token.urlQueryEscaped)")
    }

    public func acceptInvite(_ ref: InviteRef, relation: String?, alsoGuardMe: Bool) async throws -> AcceptResult {
        struct B: Encodable { let token: String; let relation: String?; let alsoGuardMe: Bool }
        return try await request("POST", "/v1/invites/accept", body: B(token: ref.token, relation: relation, alsoGuardMe: alsoGuardMe))
    }

    // MARK: 连接与授权

    public func connections() async throws -> [Connection] { try await request("GET", "/v1/connections") }

    public func removeConnection(peerId: String) async throws {
        let _: OK = try await request("DELETE", "/v1/connections/\(peerId)")
    }

    public func setLabel(peerId: String, relation: String?, nickname: String?) async throws {
        struct B: Encodable { let relation: String?; let nickname: String? }
        let _: OK = try await request("PATCH", "/v1/connections/\(peerId)/label", body: B(relation: relation, nickname: nickname))
    }

    public func whoCanSeeMe() async throws -> WhoCanSeeMe { try await request("GET", "/v1/grants/who-can-see-me") }
    public func grantsToMe() async throws -> [GrantToMe] { try await request("GET", "/v1/grants/to-me") }

    /// “让她守护我”
    public func createGrant(guardianId: String, tier: Tier, template: TemporaryTemplate? = nil) async throws -> OutgoingGrant {
        struct B: Encodable { let guardianId: String; let tier: Tier; let locationScope: LocationScope?; let expires: TempExpiry?; let onExpire: OnExpire? }
        return try await request("POST", "/v1/grants", body: B(guardianId: guardianId, tier: tier, locationScope: template?.locationScope, expires: template?.expires, onExpire: template?.onExpire))
    }

    /// 改为临时 / 改为常驻（改为临时时要重新选失效时间）
    public func changeTier(grantId: String, to tier: Tier, template: TemporaryTemplate? = nil) async throws -> OutgoingGrant {
        struct B: Encodable { let tier: Tier; let locationScope: LocationScope?; let expires: TempExpiry?; let onExpire: OnExpire? }
        return try await request("PATCH", "/v1/grants/\(grantId)", body: B(tier: tier, locationScope: template?.locationScope, expires: template?.expires, onExpire: template?.onExpire))
    }

    /// 移出担保人（出行者）或 不再守护她（担保人）
    public func revokeGrant(id: String) async throws {
        let _: OK = try await request("DELETE", "/v1/grants/\(id)")
    }

    public func revokeAllTemporary() async throws {
        struct R: Decodable { let revoked: Int }
        let _: R = try await request("POST", "/v1/grants/revoke-temporary", body: Empty())
    }

    // MARK: 护航

    public func startOptions() async throws -> StartOptions { try await request("GET", "/v1/escorts/start-options") }

    public func startEscort(guardianIds: [String], intervalMin: Int, from: String, destinationLabel: String? = nil) async throws -> Escort {
        struct B: Encodable { let guardianIds: [String]; let intervalMin: Int; let startedFrom: String; let destinationLabel: String? }
        return try await request("POST", "/v1/escorts", body: B(guardianIds: guardianIds, intervalMin: intervalMin, startedFrom: from, destinationLabel: destinationLabel))
    }

    public func currentEscort() async throws -> Escort? {
        let r: CurrentEscort = try await request("GET", "/v1/escorts/current")
        return r.escort
    }

    public func checkin(escortId: String, action: CheckinAction = .ok, channel: CheckinChannel) async throws -> Escort {
        struct B: Encodable { let action: CheckinAction; let channel: CheckinChannel }
        return try await request("POST", "/v1/escorts/\(escortId)/checkin", body: B(action: action, channel: channel))
    }

    /// 一键求救：正在护航就立刻升级；没在护航就用全部担保人开一次护航并立刻响铃
    public func sos(from: String) async throws -> Escort {
        struct B: Encodable { let from: String }
        return try await request("POST", "/v1/sos", body: B(from: from))
    }

    public func endEscort(escortId: String, reason: String = "manual") async throws -> Escort {
        struct B: Encodable { let reason: String }
        return try await request("POST", "/v1/escorts/\(escortId)/end", body: B(reason: reason))
    }

    public func reportNearHome(escortId: String) async throws {
        let _: OK = try await request("POST", "/v1/escorts/\(escortId)/near-home", body: Empty())
    }

    public func addGuardian(escortId: String, guardianId: String) async throws -> Escort {
        struct B: Encodable { let guardianId: String }
        return try await request("POST", "/v1/escorts/\(escortId)/guardians", body: B(guardianId: guardianId))
    }

    public func removeGuardian(escortId: String, guardianId: String) async throws -> Escort {
        try await request("DELETE", "/v1/escorts/\(escortId)/guardians/\(guardianId)")
    }

    public func uploadPoints(escortId: String, batch: PointBatch) async throws -> PointsResult {
        try await request("POST", "/v1/escorts/\(escortId)/points", body: batch)
    }

    // MARK: 守护

    public func guarding() async throws -> [GuardCard] {
        let r: GuardingResponse = try await request("GET", "/v1/guarding")
        return r.cards
    }

    public func latestLocation(of ownerId: String) async throws -> LatestLocation {
        try await request("GET", "/v1/people/\(ownerId)/location")
    }

    public func incident(id: String) async throws -> IncidentView { try await request("GET", "/v1/incidents/\(id)") }
    public func markSeen(incidentId: String) async throws -> IncidentView { try await request("POST", "/v1/incidents/\(incidentId)/seen", body: Empty()) }
    public func snooze(incidentId: String) async throws -> SnoozeResult { try await request("POST", "/v1/incidents/\(incidentId)/snooze", body: Empty()) }
    /// 担保人点了“打电话给她”：后端记一笔
    public func markCalled(incidentId: String) async throws {
        struct R: Decodable { let ok: Bool }
        let _: R = try await request("POST", "/v1/incidents/\(incidentId)/called", body: Empty())
    }
    public func markUnreachable(incidentId: String) async throws -> IncidentView { try await request("POST", "/v1/incidents/\(incidentId)/unreachable", body: Empty()) }

    public func confirmSafe(incidentId: String, via: ConfirmVia, followup: ConfirmFollowup) async throws -> ConfirmResult {
        struct B: Encodable { let via: ConfirmVia; let followup: ConfirmFollowup }
        return try await request("POST", "/v1/incidents/\(incidentId)/confirm-safe", body: B(via: via, followup: followup))
    }
}

/// 把任意 Encodable 包一层，方便 request() 接受 `any Encodable`
struct AnyEncodable: Encodable {
    let value: any Encodable
    init(_ value: any Encodable) { self.value = value }
    func encode(to encoder: Encoder) throws { try value.encode(to: encoder) }
}

extension String {
    var urlQueryEscaped: String {
        addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+?"))) ?? self
    }
}
