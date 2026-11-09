import CoreLocation
import EscortKit
import Foundation
import UIKit

/**
 护航期间的定位（设计文档 6.1–6.3）：
 - 只申请“使用 App 期间”权限；开始护航时创建 CLBackgroundActivitySession，锁屏后系统继续给位置，状态栏显示蓝色定位指示；
 - 按 SamplingPolicy 决定留哪些点、多久上报一次；点先进 PointQueue，失败留在队列里下次重发；
 - 每个点在本机算到家距离（HomeDetector），家的坐标从不上传；
 - 护航一结束就停。
 */
@MainActor
final class LocationService: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    @Published private(set) var lastFix: Fix?

    var onHomePrompt: ((String) -> Void)?

    private let manager = CLLocationManager()
    private var updatesTask: Task<Void, Never>?
    private var background: CLBackgroundActivitySession?
    private var escortId: String?
    private weak var api: APIClient?
    private var statusProvider: (() -> (EscortStatus?, Stage?))?
    private var queue = PointQueue()
    private var lastKept: Fix?
    private var lastMoveAt = Date()
    private var homeDetector = HomeDetector(places: [])
    private var uploading = false

    override init() {
        super.init()
        manager.delegate = self
        authorization = manager.authorizationStatus
        UIDevice.current.isBatteryMonitoringEnabled = true
    }

    /// 第一次护航时才请求位置权限，只要“使用 App 期间”
    func requestPermissionIfNeeded() {
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in self.authorization = status }
    }

    /// 今晚回哪：临时地点，只本次有效、只存本机
    var tonightDestination: HomePlace? {
        get { homeDetector.tonight }
        set { homeDetector.tonight = newValue }
    }

    func start(escortId: String, api: APIClient, statusProvider: @escaping () -> (EscortStatus?, Stage?)) {
        if self.escortId == escortId, updatesTask != nil { return }
        stop()
        self.escortId = escortId
        self.api = api
        self.statusProvider = statusProvider
        let tonight = homeDetector.tonight
        homeDetector = HomeDetector(places: HomePlaceStore.load(), tonight: tonight)
        requestPermissionIfNeeded()
        background = CLBackgroundActivitySession()
        updatesTask = Task { [weak self] in
            do {
                for try await update in CLLocationUpdate.liveUpdates() {
                    guard let self else { return }
                    if Task.isCancelled { return }
                    if let loc = update.location {
                        await self.handle(loc, stationary: update.isStationary)
                    }
                }
            } catch {
                print("定位更新结束：\(error)")
            }
        }
    }

    func stop() {
        updatesTask?.cancel()
        updatesTask = nil
        background?.invalidate()
        background = nil
        escortId = nil
        queue.reset()
        lastKept = nil
        homeDetector.tonight = nil
    }

    func homeAnsweredNotYet() { homeDetector.answeredNotYet(at: Date()) }
    func homeAnsweredArrived() { homeDetector.answeredArrived() }

    private var batteryPct: Int? {
        let level = UIDevice.current.batteryLevel
        return level < 0 ? nil : Int((level * 100).rounded())
    }

    private func handle(_ loc: CLLocation, stationary: Bool) async {
        guard let escortId, loc.horizontalAccuracy >= 0 else { return }
        let fix = Fix(lat: loc.coordinate.latitude, lng: loc.coordinate.longitude, accuracyM: loc.horizontalAccuracy, at: loc.timestamp)
        lastFix = fix

        // 到家判断：每个点都算，和采集频率无关
        if case .ask(let place) = homeDetector.feed(fix) {
            onHomePrompt?(place)
        }

        if !stationary { lastMoveAt = fix.at }
        let (status, stage) = statusProvider?() ?? (nil, nil)
        let plan = SamplingPolicy.plan(status: status, stage: stage, batteryPct: batteryPct, stationaryFor: fix.at.timeIntervalSince(lastMoveAt))
        guard SamplingPolicy.shouldKeep(fix, last: lastKept, plan: plan) else { return }
        lastKept = fix
        queue.append(PointUpload(
            recordedAt: fix.at,
            lat: fix.lat,
            lng: fix.lng,
            hAccM: fix.accuracyM,
            speedMps: loc.speed >= 0 ? loc.speed : nil,
            batteryPct: batteryPct,
            source: "phone"
        ))
        if queue.isDue(now: Date(), uploadEvery: plan.uploadEvery) {
            await flush(escortId: escortId)
        }
    }

    private func flush(escortId: String) async {
        guard !uploading, let api, let batch = queue.nextBatch() else { return }
        uploading = true
        defer { uploading = false }
        do {
            _ = try await api.uploadPoints(escortId: escortId, batch: batch)
            queue.markUploaded(batch, at: Date())
        } catch let e as APIError where e.code == "escort_ended" {
            stop()
        } catch {
            // 留在队列里，下次重发同一批
        }
    }
}

/**
 设定家庭地址时把地图定到附近：只取一次当前位置，拿到就停（最多等几秒）。
 地图自带的 .userLocation(fallback:) 在模拟器上一直停在 fallback（11-09 定位到北京也不动），所以自己取一次。
 没有权限时先问一次“使用 App 期间”；拒绝了就返回 nil，地图停在默认城市，用户自己拖。
 */
enum CurrentLocation {
    @MainActor
    static func once(timeout: Duration = .seconds(8)) async -> CLLocationCoordinate2D? {
        let manager = CLLocationManager()
        switch manager.authorizationStatus {
        case .denied, .restricted: return nil
        case .notDetermined: manager.requestWhenInUseAuthorization()
        default: break
        }
        let result = await withTaskGroup(of: CLLocationCoordinate2D?.self) { group -> CLLocationCoordinate2D? in
            group.addTask {
                do {
                    for try await update in CLLocationUpdate.liveUpdates() {
                        if let loc = update.location { return loc.coordinate }
                    }
                } catch {}
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
        withExtendedLifetime(manager) {}
        return result
    }
}
