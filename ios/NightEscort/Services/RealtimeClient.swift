import EscortKit
import Foundation

/// 担保人地图的实时位置：WebSocket 订阅某个出行者。授权变更时服务端发 revoked，当场停止。
@MainActor
final class RealtimeClient: ObservableObject {
    @Published private(set) var point: LocationPoint?
    @Published private(set) var revoked = false

    private var task: URLSessionWebSocketTask?
    private var ownerId: String?

    func subscribe(ownerId: String, api: APIClient) {
        unsubscribe()
        guard let token = api.tokens.load()?.accessToken else { return }
        var comps = URLComponents(url: api.baseURL.appendingPathComponent("/v1/ws"), resolvingAgainstBaseURL: false)!
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        let t = URLSession.shared.webSocketTask(with: comps.url!)
        task = t
        self.ownerId = ownerId
        revoked = false
        t.resume()
        send(["type": "subscribe", "owner_id": ownerId])
        receive()
    }

    func unsubscribe() {
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
        ownerId = nil
    }

    private func send(_ obj: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    private func receive() {
        task?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                switch result {
                case .success(let msg):
                    if case .string(let s) = msg { self.handle(s) }
                    self.receive()
                case .failure:
                    self.task = nil
                }
            }
        }
    }

    private struct Message: Decodable {
        let type: String
        let ownerId: String?
        let point: LocationPoint?
    }

    private func handle(_ s: String) {
        guard let m = try? JSON.decoder.decode(Message.self, from: Data(s.utf8)), m.ownerId == nil || m.ownerId == ownerId else { return }
        switch m.type {
        case "subscribed", "location":
            if let p = m.point { point = p }
        case "revoked", "denied":
            revoked = true
            point = nil
            unsubscribe()
        default:
            break
        }
    }
}
