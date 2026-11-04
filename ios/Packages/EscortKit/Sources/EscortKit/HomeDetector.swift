import Foundation

/// 设置里“我的家”：最多两处，只存在这台 iPhone 和手表上，不上传（设计文档 6.5）。
public struct HomePlace: Codable, Hashable, Identifiable, Sendable {
    public var id: UUID
    public var name: String
    public var lat: Double
    public var lng: Double
    /// 100 / 150 / 300 米三档，默认 150
    public var radiusM: Double

    public static let radiusOptions: [Double] = [100, 150, 300]
    public static let maxCount = 2

    public init(id: UUID = UUID(), name: String, lat: Double, lng: Double, radiusM: Double = 150) {
        self.id = id
        self.name = name
        self.lat = lat
        self.lng = lng
        self.radiusM = radiusM
    }
}

public enum Geo {
    /// 两点间大圆距离（米）
    public static func distance(lat1: Double, lng1: Double, lat2: Double, lng2: Double) -> Double {
        let r = 6_371_000.0
        let p1 = lat1 * .pi / 180, p2 = lat2 * .pi / 180
        let dp = (lat2 - lat1) * .pi / 180, dl = (lng2 - lng1) * .pi / 180
        let a = sin(dp / 2) * sin(dp / 2) + cos(p1) * cos(p2) * sin(dl / 2) * sin(dl / 2)
        return 2 * r * atan2(sqrt(a), sqrt(1 - a))
    }
}

public struct Fix: Sendable, Hashable {
    public let lat: Double
    public let lng: Double
    public let accuracyM: Double
    public let at: Date
    public init(lat: Double, lng: Double, accuracyM: Double, at: Date) {
        self.lat = lat
        self.lng = lng
        self.accuracyM = accuracyM
        self.at = at
    }
}

/**
 到家判断，全在本机算，不用系统地理围栏（那需要“始终允许”定位）。

 - 连续两个点都在范围内，且定位精度比半径小，才算到家；
 - 弹“安全到家了吗”：点“还没”20 分钟内不再问；离开范围再回来会再问；
 - 什么都没点：5 分钟后再问一次；还是不点就不再问，照常签到（不自动结束）。
 */
public struct HomeDetector: Sendable {
    public enum Decision: Equatable, Sendable {
        case none
        /// 弹出“检测到你已经到家，安全到家了吗？”
        case ask(place: String)
    }

    public static let requiredConsecutive = 2
    public static let snoozeAfterNo: TimeInterval = 20 * 60
    public static let repeatIfIgnored: TimeInterval = 5 * 60
    public static let maxAsksPerVisit = 2

    public var places: [HomePlace]
    /// 今晚回哪：开始护航时可以选一个临时地点（只本次有效、只存本机）
    public var tonight: HomePlace?

    private var insideStreak = 0
    private var currentPlace: UUID?
    private var lastAskAt: Date?
    private var asksThisVisit = 0
    private var quietUntil: Date?
    private var answered = false

    public init(places: [HomePlace], tonight: HomePlace? = nil) {
        self.places = places
        self.tonight = tonight
    }

    private var targets: [HomePlace] { (tonight.map { [$0] } ?? []) + places }

    /// 每收到一个位置调用一次
    public mutating func feed(_ fix: Fix) -> Decision {
        let hit = targets.first { p in
            fix.accuracyM < p.radiusM && Geo.distance(lat1: fix.lat, lng1: fix.lng, lat2: p.lat, lng2: p.lng) <= p.radiusM
        }
        guard let place = hit else {
            // 离开范围：下次回来重新问
            if insideStreak > 0 || currentPlace != nil { resetVisit() }
            return .none
        }
        if currentPlace != place.id {
            resetVisit()
            currentPlace = place.id
        }
        insideStreak += 1
        guard insideStreak >= Self.requiredConsecutive, !answered else { return .none }
        if let q = quietUntil, fix.at < q { return .none }
        if asksThisVisit >= Self.maxAsksPerVisit { return .none }
        if let last = lastAskAt, fix.at.timeIntervalSince(last) < Self.repeatIfIgnored { return .none }
        lastAskAt = fix.at
        asksThisVisit += 1
        return .ask(place: place.name)
    }

    /// 用户点了“还没，继续”
    public mutating func answeredNotYet(at now: Date) {
        quietUntil = now.addingTimeInterval(Self.snoozeAfterNo)
        asksThisVisit = 0
        lastAskAt = nil
    }

    /// 用户点了“到家了，结束护航”
    public mutating func answeredArrived() {
        answered = true
    }

    private mutating func resetVisit() {
        insideStreak = 0
        currentPlace = nil
        lastAskAt = nil
        asksThisVisit = 0
        answered = false
        quietUntil = nil
    }
}
