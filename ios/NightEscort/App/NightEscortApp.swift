import EscortKit
import SwiftUI
import UIKit
import UserNotifications

@main
struct NightEscortApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in model.handleIncomingURL(url) }
                .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { activity in
                    if let url = activity.webpageURL { model.handleIncomingURL(url) }
                }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await model.appBecameActive() } }
            if phase == .background { model.appEnteredBackground() }
        }
    }
}

final class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        AppAppearance.apply()
        #if DEBUG
        if DemoMode.scene != nil { return true }
        #endif
        NotificationService.shared.registerCategories()
        UNUserNotificationCenter.current().delegate = NotificationService.shared
        WatchBridge.shared.activate()
        return true
    }

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        let token = deviceToken.map { String(format: "%02x", $0) }.joined()
        Task { await AppModel.shared.didRegisterPushToken(token) }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        print("APNs 注册失败：\(error)")
    }
}

/// 系统导航栏、标签栏的字也用苹方（SwiftUI 的 .font 管不到这两处）
enum AppAppearance {
    static func apply() {
        func pf(_ name: String, _ size: CGFloat, _ style: UIFont.TextStyle) -> UIFont {
            let base = UIFont(name: name, size: size) ?? .systemFont(ofSize: size)
            return UIFontMetrics(forTextStyle: style).scaledFont(for: base)
        }
        let nav = UINavigationBar.appearance()
        nav.largeTitleTextAttributes = [.font: pf("PingFangSC-Semibold", 34, .largeTitle)]
        nav.titleTextAttributes = [.font: pf("PingFangSC-Semibold", 17, .headline)]
        let item = UITabBarItem.appearance()
        item.setTitleTextAttributes([.font: pf("PingFangSC-Medium", 10, .caption2)], for: .normal)
        UIBarButtonItem.appearance().setTitleTextAttributes([.font: pf("PingFangSC-Regular", 17, .body)], for: .normal)
        // 配色固定了深浅色时，每个窗口都跟着固定：半屏页、系统弹窗、菜单才不会漏（SwiftUI 的 preferredColorScheme 管不全）
        if let scheme = Theme.colorScheme {
            let style: UIUserInterfaceStyle = scheme == .dark ? .dark : .light
            NotificationCenter.default.addObserver(forName: UIWindow.didBecomeVisibleNotification, object: nil, queue: .main) { note in
                (note.object as? UIWindow)?.overrideUserInterfaceStyle = style
            }
        }
    }
}
