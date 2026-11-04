import EscortKit
import Foundation
import UIKit
import UserNotifications

/**
 通知：权限、按钮组、点按处理。
 - 签到通知上的“我没事 / 我到了，结束 / 我在别处过夜，结束”在后台直接发请求，不打开 App；
 - 联系不上的响铃通知上有“静音 5 分钟”（App 在后台时听不到音量键，所以放一个按钮）；
 - 点开响铃通知进入 App，弹出常驻框。
 */
final class NotificationService: NSObject, UNUserNotificationCenterDelegate {
    static let shared = NotificationService()
    private let center = UNUserNotificationCenter.current()

    func registerCategories() {
        typealias A = AppConstants.Action
        typealias C = AppConstants.Category
        let ok = UNNotificationAction(identifier: A.ok, title: "我没事", options: [])
        let arrived = UNNotificationAction(identifier: A.arrived, title: "我到了，结束", options: [])
        let elsewhere = UNNotificationAction(identifier: A.elsewhere, title: "我在别处过夜，结束", options: [])
        let snooze = UNNotificationAction(identifier: A.snooze, title: "静音 5 分钟", options: [])
        let open = UNNotificationAction(identifier: A.open, title: "去联系她", options: [.foreground])
        let end = UNNotificationAction(identifier: A.endEscort, title: "结束护航", options: [])
        let homeYes = UNNotificationAction(identifier: A.homeYes, title: "到家了，结束护航", options: [])
        let homeNo = UNNotificationAction(identifier: A.homeNo, title: "还没，继续", options: [])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: C.checkin, actions: [ok, arrived, elsewhere], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: C.incident, actions: [open, snooze], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: C.pauseMorning, actions: [end, ok], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: C.cap, actions: [ok, end], intentIdentifiers: [], options: []),
            UNNotificationCategory(identifier: C.home, actions: [homeYes, homeNo], intentIdentifiers: [], options: []),
        ])
    }

    /// 通知权限和紧急提醒（Critical Alerts 需要 Apple 单独批准的权限，没批下来时系统忽略这一项）
    func requestAuthorization() async {
        _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge, .criticalAlert])
        await MainActor.run { UIApplicationShim.registerForRemoteNotifications() }
    }

    /// 到家提醒（本地通知，手表会同步弹出并震动）
    func postHomePrompt(place: String) {
        let c = UNMutableNotificationContent()
        c.title = "检测到你已经到\(place == "家" ? "家" : place)"
        c.body = "安全到家了吗？"
        c.sound = .default
        c.categoryIdentifier = AppConstants.Category.home
        c.interruptionLevel = .timeSensitive
        center.add(UNNotificationRequest(identifier: "home-prompt", content: c, trigger: nil))
    }

    // MARK: UNUserNotificationCenterDelegate

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        let info = notification.request.content.userInfo
        await MainActor.run { AppModel.shared.handlePush(info, tapped: false) }
        // 前台收到响铃：App 里已经弹框并持续响，不再叠一层横幅
        if (info["kind"] as? String) == "incident_ring" { return [] }
        return [.banner, .sound, .list]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        typealias A = AppConstants.Action
        let info = response.notification.request.content.userInfo
        let model = await AppModel.shared
        let api = model.api
        let escortId = info["escort_id"] as? String
        let incidentId = info["incident_id"] as? String
        switch response.actionIdentifier {
        case A.ok:
            if let escortId { _ = try? await api.checkin(escortId: escortId, action: .ok, channel: .notification) }
            await model.refreshEscort()
        case A.arrived:
            if let escortId { _ = try? await api.checkin(escortId: escortId, action: .arrived, channel: .notification) }
            await model.refreshEscort()
        case A.elsewhere:
            if let escortId { _ = try? await api.checkin(escortId: escortId, action: .elsewhere, channel: .notification) }
            await model.refreshEscort()
        case A.endEscort:
            await model.endEscort()
        case A.snooze:
            if let incidentId { _ = try? await api.snooze(incidentId: incidentId) }
        case A.homeYes:
            await model.answerHome(arrived: true)
        case A.homeNo:
            await model.answerHome(arrived: false)
        default:
            await MainActor.run { model.handlePush(info, tapped: true) }
        }
    }
}

/// 包一层，避免在非主线程直接碰 UIApplication
enum UIApplicationShim {
    @MainActor static func registerForRemoteNotifications() {
        UIApplication.shared.registerForRemoteNotifications()
    }
}
