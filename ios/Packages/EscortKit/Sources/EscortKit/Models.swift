import Foundation

// 与后端 /v1 接口一一对应。JSON 用 snake_case，解码时自动转成 camelCase。

public struct Person: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarUrl: String?

    public init(id: String, displayName: String, avatarUrl: String? = nil) {
        self.id = id
        self.displayName = displayName
        self.avatarUrl = avatarUrl
    }

    /** 头像占位：名字第一个字 */
    public var initial: String { String(displayName.prefix(1)) }
}

public struct PublicUser: Codable, Hashable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarUrl: String?
    public let phoneMasked: String
    public let timeZone: String
    public let hasWechat: Bool
    public let hasApple: Bool
}

public struct TokenPair: Codable, Hashable, Sendable {
    public let accessToken: String
    public let refreshToken: String
    public let accessExpiresIn: Int
    public let deviceId: String
}

public enum LoginStatus: String, Codable, Sendable {
    case ok
    case needsSignup = "needs_signup"
    case needsPhone = "needs_phone"
}

public struct LoginOutcome: Codable, Sendable {
    public let status: LoginStatus
    public let user: PublicUser?
    public let tokens: TokenPair?
    public let signupTicket: String?
    public let bindTicket: String?
    public let suggestedName: String?
}

public struct DeviceInfo: Codable, Sendable {
    public enum Kind: String, Codable, Sendable { case iphone, watch }
    public let kind: Kind
    public let appVersion: String?
    public init(kind: Kind, appVersion: String? = nil) {
        self.kind = kind
        self.appVersion = appVersion
    }
}

// MARK: - 授权

public enum Tier: String, Codable, Sendable { case standing, temporary }
public enum LocationScope: String, Codable, Sendable { case live, alertOnly = "alert_only" }
public enum OnExpire: String, Codable, Sendable { case remove, keep }

/// 临时担保人的失效点：这次护航结束时 / 明早 6:00 / 7 天内
public enum TempExpiry: String, Codable, CaseIterable, Sendable {
    case escort, tonight, sevenDays = "7d"

    public var label: String {
        switch self {
        case .escort: return "这次护航结束时"
        case .tonight: return "明天早上 6:00"
        case .sevenDays: return "7 天内"
        }
    }
}

public struct TemporaryTemplate: Codable, Hashable, Sendable {
    public var expires: TempExpiry
    public var locationScope: LocationScope
    public var onExpire: OnExpire

    /// 设计文档 3.3：每个默认值都偏保守
    public static let `default` = TemporaryTemplate(expires: .escort, locationScope: .alertOnly, onExpire: .remove)

    public init(expires: TempExpiry, locationScope: LocationScope, onExpire: OnExpire) {
        self.expires = expires
        self.locationScope = locationScope
        self.onExpire = onExpire
    }
}

public struct GuardsMe: Codable, Hashable, Sendable {
    public let grantId: String
    public let tier: Tier
    public let canSee: String
    public let validUntil: Date?
    public let bindToEscort: Bool
}

public struct IGuard: Codable, Hashable, Sendable {
    public let grantId: String
    public let tier: Tier
}

public struct Connection: Codable, Hashable, Identifiable, Sendable {
    public let peer: Person
    public let relation: String?
    public let nickname: String?
    public let connectedAt: Date
    public let lastTogetherAt: Date?
    /// 她守护我：决定开始护航时能不能选她
    public let guardsMe: GuardsMe?
    /// 我守护她
    public let iGuard: IGuard?

    public var id: String { peer.id }
    public var shownName: String { nickname ?? peer.displayName }
}

public struct OutgoingGrant: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let guardian: Person
    public let tier: Tier
    public let locationScope: LocationScope
    public let canSee: String
    public let notifyStartEnd: Bool
    public let validUntil: Date?
    public let bindToEscort: Bool
    public let onExpire: OnExpire
    public let effective: Bool
    public let extended: Bool
    public let expiryText: String
    public let lastViewedAt: Date?
    public let createdAt: Date
}

public struct WhoCanSeeMe: Codable, Sendable {
    public let headline: String
    public let watchingNow: [String]
    public let grants: [OutgoingGrant]
}

public struct GrantToMe: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let owner: Person
    public let tier: Tier
    public let canSee: String
    public let expiryText: String
}

// MARK: - 邀请

public enum InviteKind: String, Codable, Sendable { case standing, temporary }

public struct Invite: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let kind: InviteKind
    public let token: String
    public let url: String
    public let expiresAt: Date
    public let template: TemporaryTemplate?
    /// 只有轮询状态时才有
    public let state: String?
    public let scannedByName: String?
    public let acceptedByName: String?
}

public struct InvitePreview: Codable, Sendable {
    public struct Inviter: Codable, Hashable, Sendable {
        public let displayName: String
        public let avatarUrl: String?
    }
    /// valid / expired / consumed / revoked / own / already_friends / not_found
    public let state: String
    public let kind: InviteKind?
    public let inviter: Inviter?
    public let expiresAt: Date?
    public let headline: String?
    public let explain: String?
    public let offerReverse: Bool?
    public let template: TemporaryTemplate?

    public var problem: String? {
        switch state {
        case "valid": return nil
        case "expired": return "这个邀请已过期，请让对方重新发一个"
        case "consumed", "revoked": return "这个邀请已经用过了"
        case "own": return "这是你自己发出的邀请"
        case "already_friends", "already_guardian": return "你们已经互相守护了"
        default: return "这个邀请链接不对"
        }
    }
}

public struct AcceptResult: Codable, Sendable {
    public let inviterId: String
    public let grantId: String
    public let reverseGrantId: String?
}

// MARK: - 护航

public enum EscortStatus: String, Codable, Sendable { case active, alerting, paused, ended }
public enum Stage: String, Codable, Sendable { case waiting, due, reminded, escalated }

public struct Readiness: Codable, Hashable, Sendable {
    public let ready: Bool
    public let notificationsOn: Bool
    public let criticalAlertsOn: Bool
    public let openedRecently: Bool
    public let warning: String?
}

public struct StartCandidate: Codable, Hashable, Identifiable, Sendable {
    public let guardian: Person
    public let grantId: String
    public let tier: Tier
    public let canSee: String
    public let defaultChecked: Bool
    public let readiness: Readiness?
    public var id: String { guardian.id }
}

public struct StartOptions: Codable, Sendable {
    public let candidates: [StartCandidate]
    public let intervals: [Int]
    public let defaultInterval: Int
    public let maxGuardians: Int
}

public struct EscortGuardian: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let displayName: String
    public let avatarUrl: String?
    public let tier: Tier
    public let canSee: String
    public let lastViewedAt: Date?
}

/// 事件类型：漏签到（missed）或她主动求救（sos）
public enum IncidentKind: String, Codable, Hashable, Sendable {
    case missed, sos
}

public struct EscortIncident: Codable, Hashable, Sendable {
    public let id: String
    public let openedAt: Date
    public let contactingBy: String?
    public let contactingSince: Date?
    public let kind: IncidentKind?

    public var isSOS: Bool { kind == .sos }
}

public struct Intervention: Codable, Hashable, Sendable {
    public let by: String
    public let action: String
    public let via: String?
    public let at: Date
    public let text: String
}

public struct Escort: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let status: EscortStatus
    public let stage: Stage
    public let intervalMin: Int
    public let startedAt: Date
    public let startedFrom: String
    public let destinationLabel: String?
    public let nextDueAt: Date?
    public let pausedUntil: Date?
    public let nearHomeAt: Date?
    public let endedAt: Date?
    public let endReason: String?
    public let guardians: [EscortGuardian]
    public let incident: EscortIncident?
    public let intervention: Intervention?

    public var isOpen: Bool { status != .ended }
}

public struct CurrentEscort: Codable, Sendable {
    public let escort: Escort?
}

public enum CheckinAction: String, Codable, Sendable { case ok, arrived, elsewhere }
public enum CheckinChannel: String, Codable, Sendable { case watch, phone, notification, app }

// MARK: - 守护

public struct CardIncident: Codable, Hashable, Sendable {
    public let id: String
    public let kind: IncidentKind?
    public let contactingName: String?
    public let contactingByMe: Bool

    public var isSOS: Bool { kind == .sos }
}

public struct GuardCard: Codable, Hashable, Identifiable, Sendable {
    public let escortId: String
    public let owner: Person
    public let status: EscortStatus
    public let myTier: Tier
    public let nextDueAt: Date?
    public let startedAt: Date
    public let endedAt: Date?
    public let endReason: String?
    public let pausedUntil: Date?
    public let nearHomeAt: Date?
    public let canViewLocation: Bool
    public let incident: CardIncident?
    public var id: String { escortId }
}

public struct GuardingResponse: Codable, Sendable {
    public let cards: [GuardCard]
}

public struct LocationPoint: Codable, Hashable, Sendable {
    public let lat: Double
    public let lng: Double
    public let hAccM: Double
    public let recordedAt: Date
    public let batteryPct: Int?
    public let source: String?
}

public struct LatestLocation: Codable, Sendable {
    public let escortId: String?
    public let point: LocationPoint?
}

public struct Trail: Codable, Sendable {
    public let escortId: String
    public let points: [LocationPoint]
}

public struct IncidentView: Codable, Hashable, Identifiable, Sendable {
    public let id: String
    public let escortId: String
    public let owner: Person
    public let openedAt: Date
    public let closedAt: Date?
    public let resolution: String?
    public let contactingByMe: Bool
    public let contactingName: String?
    public let lastUnreachableBy: String?
    public let nearHomeAt: Date?
    public let lastLocation: LocationPoint?
    public let myTier: Tier
    public let canPauseOrEnd: Bool
    public let snoozedUntil: Date?
    public let kind: IncidentKind?
    /// 只在事件没结束时有值：给担保人直接打电话用
    public let ownerPhone: String?

    public var isOpen: Bool { closedAt == nil }
    public var isSOS: Bool { kind == .sos }

    /// 拨号链接（去掉空格和 +86 以外的符号）
    public var callURL: URL? {
        guard let p = ownerPhone else { return nil }
        let digits = p.filter { $0.isNumber || $0 == "+" }
        return digits.isEmpty ? nil : URL(string: "tel://\(digits)")
    }
}

/// 担保人怎么确认她安全的
public enum ConfirmVia: String, Codable, CaseIterable, Sendable {
    case wechat, phone, inPerson = "in_person", friend

    public var label: String {
        switch self {
        case .wechat: return "微信"
        case .phone: return "电话"
        case .inPerson: return "当面"
        case .friend: return "她身边的朋友告诉我"
        }
    }
}

/// 确认安全后的选择：继续护航 / 她在别处过夜暂停到明早 8:00 / 帮她结束
public enum ConfirmFollowup: String, Codable, Sendable { case `continue`, pause, end }

public struct ConfirmResult: Codable, Sendable {
    public let ok: Bool
    public let followup: ConfirmFollowup
    public let pausedUntil: Date?
}

public struct SnoozeResult: Codable, Sendable {
    public let snoozedUntil: Date
}

public struct PointsResult: Codable, Sendable {
    public let accepted: Int
    public let duplicate: Bool
    public let dropped: Int
}

public struct OK: Codable, Sendable {
    public let ok: Bool?
}
