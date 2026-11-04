import EscortKit
import Foundation
import SwiftUI
import UIKit
import UserNotifications

/// 全局状态：登录、图谱、我的护航、我在守护的人、正在响铃的事件。
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    let api: APIClient
    let location = LocationService()

    @Published var signedIn: Bool
    @Published var user: PublicUser?
    @Published var connections: [Connection] = []
    @Published var escort: Escort?
    @Published var cards: [GuardCard] = []
    /// 正在响铃、需要全屏挂着的事件（担保人一侧）
    @Published var alertIncident: IncidentView?
    /// 扫码 / 通用链接 / 粘贴进来的邀请，弹确认页
    @Published var pendingInvite: InviteRef?
    /// 到家提醒：“检测到你已经到家，安全到家了吗？”
    @Published var homePrompt: String?
    @Published var toast: String?

    private var pushToken: String?
    private var refreshTask: Task<Void, Never>?

    private init() {
        api = APIClient(baseURL: AppConfig.apiBaseURL, tokens: KeychainTokenStore(), device: DeviceInfo(kind: .iphone, appVersion: AppConfig.appVersion))
        signedIn = api.isSignedIn
        api.onSignedOut = { [weak self] in
            Task { @MainActor in self?.didSignOut() }
        }
        location.onHomePrompt = { [weak self] place in
            Task { @MainActor in self?.showHomePrompt(place) }
        }
    }

    // MARK: 生命周期

    func appBecameActive() async {
        guard signedIn else { return }
        await reportDevice(opened: true)
        await refreshAll()
    }

    func didLogin(_ outcome: LoginOutcome) async {
        guard outcome.status == .ok else { return }
        user = outcome.user
        signedIn = true
        await NotificationService.shared.requestAuthorization()
        await appBecameActive()
        await WatchBridge.shared.sendTokensToWatch(api: api)
    }

    func signOut() async {
        await api.logout()
        didSignOut()
    }

    private func didSignOut() {
        signedIn = false
        user = nil
        connections = []
        escort = nil
        cards = []
        alertIncident = nil
        location.stop()
        LiveActivityService.shared.endAll()
        AlarmPlayer.shared.stop()
        WatchBridge.shared.send(.signedOut)
    }

    func refreshAll() async {
        async let u = try? api.me()
        async let c = try? api.connections()
        async let g = try? api.guarding()
        await refreshEscort()
        let (uu, cc, gg) = await (u, c, g)
        if let uu { user = uu }
        if let cc { connections = cc }
        if let gg { applyCards(gg) }
    }

    /// 网络失败时保持原状，不能因为一次请求失败就停掉定位
    func refreshEscort() async {
        do {
            applyEscort(try await api.currentEscort())
        } catch {
            print("刷新护航失败：\(error)")
        }
    }

    func refreshGuarding() async {
        if let g = try? await api.guarding() { applyCards(g) }
    }

    private func applyEscort(_ e: Escort?) {
        escort = e
        if let e, e.status == .active || e.status == .alerting {
            location.start(escortId: e.id, api: api, statusProvider: { [weak self] in
                (self?.escort?.status, self?.escort?.stage)
            })
            LiveActivityService.shared.startOrUpdate(escort: e)
        } else {
            location.stop()
            if e == nil || e?.status == .ended { LiveActivityService.shared.endAll() }
        }
        WatchBridge.shared.send(.escortChanged)
    }

    private func applyCards(_ c: [GuardCard]) {
        cards = c
        // 有人联系不上且我已经接手：常驻框要一直挂着
        if alertIncident == nil, let card = c.first(where: { $0.status == .alerting && $0.incident?.contactingByMe == true }), let id = card.incident?.id {
            Task { await openIncident(id: id) }
        }
    }

    // MARK: 推送

    func didRegisterPushToken(_ token: String) async {
        pushToken = token
        await reportDevice(opened: false)
    }

    func reportDevice(opened: Bool) async {
        guard signedIn else { return }
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        let notif = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
        let critical = settings.criticalAlertSetting == .enabled
        try? await api.updateDevice(.init(
            apnsToken: pushToken,
            apnsEnv: AppConfig.apnsEnv,
            liveActivityToken: LiveActivityService.shared.pushToken,
            appVersion: AppConfig.appVersion,
            notifAllowed: notif,
            criticalAllowed: critical,
            opened: opened
        ))
    }

    /// 收到推送（前台）或用户点了通知
    func handlePush(_ info: [AnyHashable: Any], tapped: Bool) {
        let kind = info["kind"] as? String ?? ""
        switch kind {
        case "incident_ring":
            if let id = info["incident_id"] as? String, tapped || UIApplication.shared.applicationState == .active {
                Task { await openIncident(id: id) }
            }
            Task { await refreshGuarding() }
        case "incident_closed", "escort_paused":
            if let id = info["incident_id"] as? String, alertIncident?.id == id { closeAlert() }
            Task { await refreshGuarding() }
        case "checkin_due", "checkin_reminder", "cap_prompt", "pause_morning", "no_guardian_left", "grant_expiring":
            Task { await refreshEscort() }
        default:
            Task { await refreshAll() }
        }
    }

    // MARK: 担保人：联系不上

    /// 点开通知进入 App：第一个点开的人接手，弹出关不掉的框并持续震动
    func openIncident(id: String) async {
        do {
            let v = try await api.markSeen(incidentId: id)
            guard v.isOpen else { closeAlert(); return }
            alertIncident = v
            if let s = v.snoozedUntil, s > Date() {
                AlarmPlayer.shared.start(snoozedUntil: s)
            } else {
                AlarmPlayer.shared.start()
            }
            AlarmPlayer.shared.onVolumeButton = { [weak self] in
                Task { @MainActor in await self?.snoozeAlert() }
            }
        } catch {
            toast = error.localizedDescription
        }
    }

    func snoozeAlert() async {
        guard let inc = alertIncident else { return }
        AlarmPlayer.shared.snooze()
        _ = try? await api.snooze(incidentId: inc.id)
    }

    func closeAlert() {
        alertIncident = nil
        AlarmPlayer.shared.stop()
        UNUserNotificationCenter.current().removeAllDeliveredNotifications()
    }

    // MARK: 邀请

    func handleIncomingURL(_ url: URL) {
        if let ref = InviteLink.parse(url.absoluteString, allowedHosts: AppConfig.inviteHosts) {
            pendingInvite = ref
        }
    }

    // MARK: 到家（6.5）

    private func showHomePrompt(_ place: String) {
        guard let e = escort, e.isOpen, homePrompt == nil else { return }
        homePrompt = place
        Task { try? await api.reportNearHome(escortId: e.id) }
        NotificationService.shared.postHomePrompt(place: place)
    }

    func answerHome(arrived: Bool) async {
        homePrompt = nil
        guard let e = escort else { return }
        if arrived {
            location.homeAnsweredArrived()
            if let ended = try? await api.endEscort(escortId: e.id, reason: "home") { applyEscort(ended) }
        } else {
            location.homeAnsweredNotYet()
        }
    }

    // MARK: 出行者操作

    func checkin(_ action: CheckinAction = .ok, channel: CheckinChannel = .app) async {
        guard let e = escort else { return }
        do {
            applyEscort(try await api.checkin(escortId: e.id, action: action, channel: channel))
        } catch {
            toast = error.localizedDescription
        }
    }

    func endEscort(reason: String = "manual") async {
        guard let e = escort else { return }
        do {
            applyEscort(try await api.endEscort(escortId: e.id, reason: reason))
        } catch {
            toast = error.localizedDescription
        }
    }

    func started(_ e: Escort) {
        applyEscort(e)
    }
}
