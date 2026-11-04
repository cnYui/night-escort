import EscortKit
import Foundation
import WatchConnectivity

/// 手机 ↔ 手表：交登录令牌（手表不输密码）、同步“我的家”、通知护航状态变化。
final class WatchBridge: NSObject, WCSessionDelegate {
    static let shared = WatchBridge()

    func activate() {
        guard WCSession.isSupported() else { return }
        WCSession.default.delegate = self
        WCSession.default.activate()
    }

    func send(_ m: WatchMessage) {
        guard WCSession.isSupported(), WCSession.default.activationState == .activated, WCSession.default.isPaired else { return }
        guard let payload = try? m.encoded() else { return }
        switch m {
        case .tokens, .homePlaces, .signedOut:
            // 最新状态，手表下次醒来就能拿到
            try? WCSession.default.updateApplicationContext(payload)
            WCSession.default.transferUserInfo(payload)
        case .escortChanged:
            if WCSession.default.isReachable {
                WCSession.default.sendMessage(payload, replyHandler: nil)
            }
        }
    }

    /// 登录后（以及手表请求时）给手表签一对专用令牌
    func sendTokensToWatch(api: APIClient) async {
        guard WCSession.isSupported(), WCSession.default.isPaired, WCSession.default.isWatchAppInstalled else { return }
        guard let t = try? await api.watchTokens() else { return }
        send(.tokens(t, baseURL: api.baseURL.absoluteString))
        send(.homePlaces(HomePlaceStore.load()))
    }

    // MARK: WCSessionDelegate

    func session(_ session: WCSession, activationDidCompleteWith activationState: WCSessionActivationState, error: Error?) {}
    func sessionDidBecomeInactive(_ session: WCSession) {}
    func sessionDidDeactivate(_ session: WCSession) { WCSession.default.activate() }

    /// 手表发来“需要令牌”
    func session(_ session: WCSession, didReceiveMessage message: [String: Any]) {
        if message["need"] as? String == "tokens" {
            Task { await self.sendTokensToWatch(api: await AppModel.shared.api) }
        }
    }
}
