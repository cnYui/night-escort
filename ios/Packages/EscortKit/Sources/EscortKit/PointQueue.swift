import Foundation

public struct PointUpload: Codable, Hashable, Sendable {
    public let recordedAt: Date
    public let lat: Double
    public let lng: Double
    public let hAccM: Double
    public let speedMps: Double?
    public let batteryPct: Int?
    public let source: String

    public init(recordedAt: Date, lat: Double, lng: Double, hAccM: Double, speedMps: Double?, batteryPct: Int?, source: String) {
        self.recordedAt = recordedAt
        self.lat = lat
        self.lng = lng
        self.hAccM = hAccM
        self.speedMps = speedMps
        self.batteryPct = batteryPct
        self.source = source
    }
}

public struct PointBatch: Codable, Hashable, Sendable {
    public let idempotencyKey: String
    public let points: [PointUpload]
}

/**
 本地上报队列（设计文档 6.3）：点先进队列，按计划批量上传；失败就留在队列里下次重发。
 一批一旦切出来就固定下来（同一个幂等键、同一组点），重发时服务端认出来不会重复入库。
 */
public struct PointQueue: Codable, Sendable {
    public private(set) var pending: [PointUpload] = []
    /// 已切出、还没确认成功的批次
    public private(set) var inflight: PointBatch?
    public private(set) var lastUploadAt: Date?
    public static let maxBatch = 200
    public static let maxPending = 2000

    public init() {}

    public mutating func append(_ p: PointUpload) {
        pending.append(p)
        if pending.count > Self.maxPending { pending.removeFirst(pending.count - Self.maxPending) }
    }

    /// 是否该上报了
    public func isDue(now: Date, uploadEvery: TimeInterval) -> Bool {
        if inflight != nil { return true }
        guard !pending.isEmpty else { return false }
        if uploadEvery <= 0 { return true }
        guard let last = lastUploadAt else { return true }
        return now.timeIntervalSince(last) >= uploadEvery
    }

    /// 取出要上传的那一批（有在途批次就重发它）
    public mutating func nextBatch(makeKey: () -> String = { UUID().uuidString }) -> PointBatch? {
        if let b = inflight { return b }
        guard !pending.isEmpty else { return nil }
        let n = min(Self.maxBatch, pending.count)
        let b = PointBatch(idempotencyKey: makeKey(), points: Array(pending.prefix(n)))
        pending.removeFirst(n)
        inflight = b
        return b
    }

    public mutating func markUploaded(_ batch: PointBatch, at now: Date) {
        if inflight?.idempotencyKey == batch.idempotencyKey { inflight = nil }
        lastUploadAt = now
    }

    /// 护航结束：清空，不再上报
    public mutating func reset() {
        pending = []
        inflight = nil
        lastUploadAt = nil
    }
}
