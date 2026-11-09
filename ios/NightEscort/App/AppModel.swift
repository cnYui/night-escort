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
    /// 扫码 / 点链接 / 粘贴板里认出来的邀请，弹“成为担保人”。没登录时先留着，登录后再弹
    @Published var pendingInvite: InviteRef?
    /// 到家提醒：“检测到你已经到家，安全到家了吗？”
    @Published var homePrompt: String?
    @Published var toast: String?
    /// 求救没发出去时的说明（弹框里附“拨打 110”）
    @Published var sosError: String?

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
        #if DEBUG
        if let scene = DemoMode.scene { loadDemo(scene) }
        #endif
    }

    #if DEBUG
    /// 演示模式：不连后端，直接摆出某个界面（见 Shared/DemoData.swift）
    private func loadDemo(_ scene: String) {
        guard scene != "login" else { signedIn = false; return }
        if scene == "confirm-login" { signedIn = false; pendingInvite = .token("Xk2pQ9vLmT4wZr8a"); return }
        signedIn = true
        user = DemoData.user
        connections = DemoData.connections
        cards = DemoData.guardCards
        switch scene {
        case "active": escort = DemoData.escort("active")
        case "sos": escort = DemoData.escort("alerting", sos: true)
        case "incident": alertIncident = DemoData.incident
        case "confirm": pendingInvite = .token("Xk2pQ9vLmT4wZr8a")
        default: break
        }
    }
    #endif

    // MARK: 生命周期

    func appBecameActive() async {
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
        checkPasteboardForInvite()
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
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
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
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
        do {
            applyEscort(try await api.currentEscort())
        } catch {
            print("刷新护航失败：\(error)")
        }
    }

    func refreshGuarding() async {
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
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
            markInviteHandled(ref)
            pendingInvite = ref
        }
    }

    /// “粘贴邀请链接”按钮（系统 PasteButton，不弹粘贴权限提示）
    @discardableResult
    func handlePastedText(_ strings: [String]) -> Bool {
        guard let ref = strings.lazy.compactMap({ InviteLink.find(in: $0, allowedHosts: AppConfig.inviteHosts) }).first else {
            toast = "粘贴板里没有「安全回家」的邀请链接"
            return false
        }
        markInviteHandled(ref)
        pendingInvite = ref
        return true
    }

    /**
     朋友在微信里复制了邀请链接（或在落地页点了“复制邀请链接”），回到 App 时自动弹“成为担保人”。
     - 先用 detectPatterns 看一眼是不是像链接，这一步不会弹系统的“允许粘贴”提示；
     - 像链接才真的读，这时 iOS 会问一次“允许粘贴”（用户可在设置里改成“允许”）；
     - 同一次复制只认一次（changeCount），同一个邀请弹过就不再弹。
     */
    func checkPasteboardForInvite() {
        let pb = UIPasteboard.general
        let defaults = UserDefaults.standard
        guard pb.hasStrings, pb.changeCount != defaults.integer(forKey: Self.lastPasteboardChangeKey) else { return }
        defaults.set(pb.changeCount, forKey: Self.lastPasteboardChangeKey)
        pb.detectPatterns(for: [.probableWebURL]) { [weak self] result in
            guard case .success(let found) = result, found.contains(.probableWebURL) else { return }
            Task { @MainActor in
                guard let self, self.pendingInvite == nil,
                      let text = UIPasteboard.general.string,
                      let ref = InviteLink.find(in: text, allowedHosts: AppConfig.inviteHosts),
                      !self.handledInviteTokens.contains(ref.token) else { return }
                self.markInviteHandled(ref)
                self.pendingInvite = ref
            }
        }
    }

    /// 自己复制自己的邀请（发微信、复制链接）：记下来，回到 App 时别把自己的邀请弹出来
    func copyOwnInvite(_ text: String, token: String) {
        UIPasteboard.general.string = text
        UserDefaults.standard.set(UIPasteboard.general.changeCount, forKey: Self.lastPasteboardChangeKey)
        markInviteHandled(.token(token))
    }

    private static let lastPasteboardChangeKey = "invite.lastPasteboardChange"
    private static let handledInvitesKey = "invite.handledTokens"

    private var handledInviteTokens: [String] {
        UserDefaults.standard.stringArray(forKey: Self.handledInvitesKey) ?? []
    }

    private func markInviteHandled(_ ref: InviteRef) {
        var list = handledInviteTokens.filter { $0 != ref.token }
        list.append(ref.token)
        UserDefaults.standard.set(Array(list.suffix(20)), forKey: Self.handledInvitesKey)
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

    /// 一键求救：立刻叫醒所有担保人；没在护航也能用
    func sos() async {
        do {
            applyEscort(try await api.sos(from: "phone"))
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            toast = "已发出求救，担保人正在联系你"
        } catch let e as APIError {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            sosError = e.code == "no_guardian" ? e.message : "求救没发出去：\(e.message)。情况紧急请直接拨打 110"
        } catch {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            sosError = "求救没发出去，可能是网络问题。情况紧急请直接拨打 110"
        }
    }
}
