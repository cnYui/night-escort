import CoreLocation
import EscortKit
import Foundation
import WatchConnectivity
import WatchKit

/**
 手表端（6.x）：不输密码，令牌由手机通过 WatchConnectivity 交过来。
 能做的事：长按开始护航（用手机上的默认担保人和间隔）、看倒计时、“我没事”签到、结束、到家确认。
 “我的家”由手机同步过来，只存手表本机。
 */
@MainActor
final class WatchModel: NSObject, ObservableObject {
    static let shared = WatchModel()

    @Published private(set) var escort: Escort?
    @Published private(set) var signedIn = false
    @Published var askHome: String?
    @Published var message: String?
    @Published var busy = false

    private let tokens = KeychainTokenStore(account: "watch")
    private var baseURL: URL? {
        get { UserDefaults.standard.string(forKey: "baseURL").flatMap(URL.init(string:)) }
        set { UserDefaults.standard.set(newValue?.absoluteString, forKey: "baseURL") }
    }
    private var api: APIClient?
    private let location = CLLocationManager()
    private var detector = HomeDetector(places: HomePlaceStore.load())

    override init() {
        super.init()
        location.delegate = self
        location.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        location.distanceFilter = 30
        rebuildAPI()
        if WCSession.isSupported() {
            WCSession.default.delegate = self
            WCSession.default.activate()
        }
    }

    private func rebuildAPI() {
        guard let url = baseURL, tokens.load() != nil else {
            api = nil
            signedIn = false
            return
        }
        api = APIClient(baseURL: url, tokens: tokens, device: DeviceInfo(kind: .watch, appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String))
        signedIn = true
    }

    func requestTokensFromPhone() {
        guard WCSession.default.activationState == .activated, WCSession.default.isReachable else {
            message = "请在 iPhone 上打开夜归护航"
            return
        }
        WCSession.default.sendMessage(["need": "tokens"], replyHandler: nil)
    }

    func refresh() async {
        guard let api else { return }
        do {
            escort = try await api.currentEscort()
            syncLocationTracking()
        } catch let e as APIError where e.status == 401 {
            tokens.save(nil)
            rebuildAPI()
        } catch {
            // 网络不好时保留旧状态
        }
    }

    /// 长按开始：用默认勾选的担保人和默认间隔；一个能收到通知的都没有就让她去手机上选
    func start() async {
        guard let api else { return }
        busy = true
        defer { busy = false }
        do {
            let o = try await api.startOptions()
            let chosen = o.candidates.filter(\.defaultChecked)
            guard !chosen.isEmpty else {
                message = "还没有默认担保人，请在 iPhone 上开始"
                return
            }
            if chosen.allSatisfy({ $0.readiness?.ready == false }) {
                message = "选中的人都可能收不到通知，请在 iPhone 上换人"
                return
            }
            escort = try await api.startEscort(guardianIds: chosen.map(\.id), intervalMin: o.defaultInterval, from: "watch")
            WKInterfaceDevice.current().play(.start)
            syncLocationTracking()
        } catch {
            message = error.localizedDescription
        }
    }

    func checkin(_ action: CheckinAction = .ok) async {
        guard let api, let e = escort else { return }
        busy = true
        defer { busy = false }
        do {
            escort = try await api.checkin(escortId: e.id, action: action, channel: .watch)
            WKInterfaceDevice.current().play(.success)
            if escort?.status == .ended { syncLocationTracking() }
        } catch {
            WKInterfaceDevice.current().play(.failure)
            message = error.localizedDescription
        }
    }

    func end() async {
        guard let api, let e = escort else { return }
        busy = true
        defer { busy = false }
        do {
            escort = try await api.endEscort(escortId: e.id)
            WKInterfaceDevice.current().play(.stop)
            syncLocationTracking()
        } catch {
            message = error.localizedDescription
        }
    }

    func answerHome(arrived: Bool) async {
        askHome = nil
        if arrived {
            detector.answeredArrived()
            await checkin(.arrived)
        } else {
            detector.answeredNotYet(at: Date())
        }
    }

    private var isOpen: Bool {
        guard let s = escort?.status else { return false }
        return s == .active || s == .alerting
    }

    /// 手表上只在护航进行中、而且设了家时才用位置（只做到家判断，不上传）
    private func syncLocationTracking() {
        if isOpen && !detector.places.isEmpty {
            if location.authorizationStatus == .notDetermined { location.requestWhenInUseAuthorization() }
            location.startUpdatingLocation()
        } else {
            location.stopUpdatingLocation()
        }
    }

    fileprivate func handle(_ m: WatchMessage) {
        switch m {
        case let .tokens(pair, baseURL: url):
            tokens.save(pair)
            baseURL = URL(string: url)
            rebuildAPI()
            Task { await refresh() }
        case let .homePlaces(places):
            HomePlaceStore.save(places)
            detector.places = places
            syncLocationTracking()
        case .escortChanged:
            Task { await refresh() }
        case .signedOut:
            tokens.save(nil)
            escort = nil
            rebuildAPI()
            location.stopUpdatingLocation()
        }
    }

    fileprivate func handle(fix: CLLocation) {
        guard isOpen else { return }
        let d = detector.feed(Fix(lat: fix.coordinate.latitude, lng: fix.coordinate.longitude, accuracyM: fix.horizontalAccuracy, at: fix.timestamp))
        if case let .ask(place) = d {
            askHome = place
            WKInterfaceDevice.current().play(.notification)
            if let api, let e = escort { Task { try? await api.reportNearHome(escortId: e.id) } }
        }
    }
}

extension WatchModel: WCSessionDelegate {
    nonisolated func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {
        let ctx = session.receivedApplicationContext
        Task { @MainActor in
            if let m = WatchMessage.decode(ctx) { self.handle(m) }
            if !self.signedIn { self.requestTokensFromPhone() }
        }
    }

    nonisolated func session(_ session: WCSession, didReceiveApplicationContext applicationContext: [String: Any]) {
        let m = WatchMessage.decode(applicationContext)
        Task { @MainActor in if let m { self.handle(m) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveUserInfo userInfo: [String: Any] = [:]) {
        let m = WatchMessage.decode(userInfo)
        Task { @MainActor in if let m { self.handle(m) } }
    }

    nonisolated func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        let m = WatchMessage.decode(message)
        Task { @MainActor in if let m { self.handle(m) } }
    }
}

extension WatchModel: CLLocationManagerDelegate {
    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.handle(fix: last) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
