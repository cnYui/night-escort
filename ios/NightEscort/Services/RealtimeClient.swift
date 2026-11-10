import EscortKit
import Foundation

/// 连 /v1/ws 的公共部分：断了自动重连（2、4、8… 最多 30 秒），重连前先发一个普通请求让 APIClient 换新令牌。
@MainActor
class SocketConnection {
    private var task: URLSessionWebSocketTask?
    private var pingTask: Task<Void, Never>?
    private(set) var api: APIClient?
    private var wanted = false
    private var retry = 0

    func open(api: APIClient) {
        self.api = api
        wanted = true
        if task == nil { connect() }
    }

    func close() {
        wanted = false
        teardown()
    }

    func send(_ obj: [String: String]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj), let s = String(data: data, encoding: .utf8) else { return }
        task?.send(.string(s)) { _ in }
    }

    /// 子类：连上以后（含重连）要做的事
    func didConnect() {}
    /// 子类：收到一条文本消息
    func didReceive(_ text: String) {}

    private func connect() {
        guard wanted, let api, let token = api.tokens.load()?.accessToken,
              var comps = URLComponents(url: api.baseURL.appendingPathComponent("/v1/ws"), resolvingAgainstBaseURL: false) else { return }
        comps.scheme = comps.scheme == "https" ? "wss" : "ws"
        comps.queryItems = [URLQueryItem(name: "access_token", value: token)]
        guard let url = comps.url else { return }
        let t = URLSession.shared.webSocketTask(with: url)
        task = t
        t.resume()
        receive(t)
        didConnect()
        // 每 25 秒 ping 一次，防止中间的代理和 NAT 把空闲连接掐掉
        pingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(25))
                guard let self, self.task === t else { return }
                t.sendPing { _ in }
            }
        }
    }

    private func receive(_ t: URLSessionWebSocketTask) {
        t.receive { [weak self] result in
            Task { @MainActor in
                guard let self, self.task === t else { return }
                switch result {
                case .success(let msg):
                    self.retry = 0
                    if case .string(let s) = msg { self.didReceive(s) }
                    self.receive(t)
                case .failure:
                    self.dropped()
                }
            }
        }
    }

    private func dropped() {
        teardown()
        guard wanted else { return }
        retry += 1
        let delay = min(30, 1 << min(retry, 5))
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(delay))
            guard let self, self.wanted, self.task == nil else { return }
            // 断开可能是访问令牌过期（服务端 4401）：随便发一个需要登录的请求，APIClient 会自己刷新
            _ = try? await self.api?.me()
            self.connect()
        }
    }

    private func teardown() {
        pingTask?.cancel()
        pingTask = nil
        task?.cancel(with: .goingAway, reason: nil)
        task = nil
    }
}

/// 担保人地图的实时位置：订阅某个出行者。授权变更时服务端发 revoked，当场停止，不再重连。
@MainActor
final class RealtimeClient: ObservableObject {
    @Published private(set) var point: LocationPoint?
    @Published private(set) var revoked = false

    private let socket = Socket()

    init() {
        socket.owner = self
    }

    func subscribe(ownerId: String, api: APIClient) {
        socket.close()
        socket.ownerId = ownerId
        revoked = false
        socket.open(api: api)
    }

    func unsubscribe() {
        socket.close()
        socket.ownerId = nil
    }

    private struct Message: Decodable {
        let type: String
        let ownerId: String?
        let point: LocationPoint?
    }

    fileprivate func handle(_ s: String) {
        guard let m = try? JSON.decoder.decode(Message.self, from: Data(s.utf8)), m.ownerId == nil || m.ownerId == socket.ownerId else { return }
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

    private final class Socket: SocketConnection {
        weak var owner: RealtimeClient?
        var ownerId: String?

        override func didConnect() {
            // 重连后要重新订阅，服务端会先回一次最新位置
            if let ownerId { send(["type": "subscribe", "owner_id": ownerId]) }
        }

        override func didReceive(_ text: String) {
            owner?.handle(text)
        }
    }
}

/**
 App 在前台时一直连着的事件通道：自己或守护的人的回家、联系不上、求救一有变化，服务端发 refresh，这边马上重新拉。
 推送晚到、被系统合并，或者本地联调没配推送（模拟器拿不到推送令牌）时，开着 App 的守护人也能立刻看到提醒。
 */
@MainActor
final class EventsClient: SocketConnection {
    /// what：escort_changed / incident_changed / reconnected；ownerId：是谁的回家
    var onRefresh: ((_ what: String, _ ownerId: String?) -> Void)?
    private var connectedOnce = false

    func start(api: APIClient) { open(api: api) }
    func stop() {
        close()
        connectedOnce = false
    }

    override func didConnect() {
        // 断线期间可能错过了消息，重连后整体刷新一次
        if connectedOnce { onRefresh?("reconnected", nil) }
        connectedOnce = true
    }

    private struct Message: Decodable {
        let type: String
        let what: String?
        let ownerId: String?
    }

    override func didReceive(_ text: String) {
        guard let m = try? JSON.decoder.decode(Message.self, from: Data(text.utf8)), m.type == "refresh" else { return }
        onRefresh?(m.what ?? "", m.ownerId)
    }
}
