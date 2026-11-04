import ActivityKit
import EscortKit
import Foundation

/// 锁屏和灵动岛的实时活动：倒计时和“3 人在守”。开始时由 App 创建，之后由服务端推送更新。
@MainActor
final class LiveActivityService {
    static let shared = LiveActivityService()
    private(set) var pushToken: String?
    private var tokenTask: Task<Void, Never>?

    func startOrUpdate(escort e: Escort) {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else { return }
        let state = EscortActivityAttributes.ContentState(
            status: e.status.rawValue,
            nextDueAt: e.status == .active ? e.nextDueAt : nil,
            guardianCount: e.guardians.count
        )
        let content = ActivityContent(state: state, staleDate: nil)
        if let existing = Activity<EscortActivityAttributes>.activities.first(where: { $0.attributes.escortId == e.id }) {
            Task { await existing.update(content) }
            return
        }
        endAll()
        do {
            let activity = try Activity.request(attributes: EscortActivityAttributes(escortId: e.id), content: content, pushType: .token)
            tokenTask?.cancel()
            tokenTask = Task { [weak self] in
                for await data in activity.pushTokenUpdates {
                    let token = data.map { String(format: "%02x", $0) }.joined()
                    await MainActor.run { self?.pushToken = token }
                    await AppModel.shared.reportDevice(opened: false)
                }
            }
        } catch {
            print("实时活动开启失败：\(error)")
        }
    }

    func endAll() {
        tokenTask?.cancel()
        tokenTask = nil
        pushToken = nil
        for a in Activity<EscortActivityAttributes>.activities {
            Task { await a.end(nil, dismissalPolicy: .immediate) }
        }
    }
}
