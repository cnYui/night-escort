import SwiftUI
import WatchKit

@main
struct NightEscortWatchApp: App {
    @WKApplicationDelegateAdaptor(WatchAppDelegate.self) private var delegate
    @StateObject private var model = WatchModel.shared

    var body: some Scene {
        WindowGroup {
            WatchRootView().environmentObject(model)
        }
    }
}

/// 手表自己注册推送：手机不在身边（比如只连着 Wi-Fi）时，提醒也能直接推到手表上
final class WatchAppDelegate: NSObject, WKApplicationDelegate {
    func didRegisterForRemoteNotifications(withDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { @MainActor in await WatchModel.shared.didRegisterPushToken(token) }
    }

    func didFailToRegisterForRemoteNotificationsWithError(_ error: Error) {
        print("手表 APNs 注册失败：\(error)")
    }
}
