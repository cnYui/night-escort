import Foundation

/**
 采集频率（设计文档 6.2）。只有“待签到”和“联系不上”时提高频率，平时省电更重要。

 | 状态 | 采集 | 上报 |
 | 护航中，在移动 | 每 50 米或 30 秒 | 每 60 秒批量 |
 | 护航中，静止超过 3 分钟 | 每 3 分钟 | 随下一批 |
 | 待签到或已提醒 | 每 30 秒 | 每个点立即 |
 | 联系不上 | 每 10 秒 | 每个点立即 |
 | 电量低于 15% | 每 2 分钟（联系不上时不降） | 每 2 分钟 |
 | 护航之外 / 暂停 | 不采集 | 不上报 |
 */
public struct SamplingPolicy: Sendable {
    public struct Plan: Equatable, Sendable {
        /// 两个点之间至少隔多久（秒）；nil 表示不采集
        public let minInterval: TimeInterval?
        /// 移动多少米就采一个点（只在普通移动时）
        public let distanceFilterM: Double?
        /// 攒多久上报一次；0 表示每个点立即上报
        public let uploadEvery: TimeInterval
        /// 是否要求最佳精度
        public let bestAccuracy: Bool
    }

    public static let stationaryAfter: TimeInterval = 3 * 60
    public static let lowBattery = 15

    public static func plan(status: EscortStatus?, stage: Stage?, batteryPct: Int?, stationaryFor: TimeInterval) -> Plan {
        guard let status, status != .ended, status != .paused else {
            return Plan(minInterval: nil, distanceFilterM: nil, uploadEvery: 0, bestAccuracy: false)
        }
        if status == .alerting {
            return Plan(minInterval: 10, distanceFilterM: nil, uploadEvery: 0, bestAccuracy: true)
        }
        if let b = batteryPct, b < lowBattery {
            return Plan(minInterval: 120, distanceFilterM: nil, uploadEvery: 120, bestAccuracy: false)
        }
        if stage == .due || stage == .reminded {
            return Plan(minInterval: 30, distanceFilterM: nil, uploadEvery: 0, bestAccuracy: true)
        }
        if stationaryFor >= stationaryAfter {
            return Plan(minInterval: 180, distanceFilterM: nil, uploadEvery: 60, bestAccuracy: false)
        }
        return Plan(minInterval: 30, distanceFilterM: 50, uploadEvery: 60, bestAccuracy: false)
    }

    /// 根据计划决定这个位置要不要留下
    public static func shouldKeep(_ fix: Fix, last: Fix?, plan: Plan) -> Bool {
        guard let minInterval = plan.minInterval else { return false }
        guard let last else { return true }
        let dt = fix.at.timeIntervalSince(last.at)
        if dt >= minInterval { return true }
        if let d = plan.distanceFilterM {
            return Geo.distance(lat1: fix.lat, lng1: fix.lng, lat2: last.lat, lng2: last.lng) >= d
        }
        return false
    }
}
