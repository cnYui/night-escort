#if DEBUG
import EscortKit
import Foundation

/**
 演示模式（只在调试包里有）：不连后端，用一组示例数据把各个界面摆出来，方便在模拟器里截图。
 启动参数 `-demoScene <名字>`，例如：
   xcrun simctl launch booted app.nightescort.ios -demoScene home
 iPhone：login / home / start / active / sos / guarding / incident / me / invite / confirm / confirm-login
 手表：signin / idle / running / paused / alerting / sos / home / message
 */
enum DemoMode {
    static var scene: String? {
        let s = UserDefaults.standard.string(forKey: "demoScene")
        return (s?.isEmpty ?? true) ? nil : s
    }
}

enum DemoData {
    private static func iso(_ offset: TimeInterval) -> String { JSON.formatDate(Date().addingTimeInterval(offset)) }
    private static let day: TimeInterval = 86_400

    private static func decode<T: Decodable>(_ type: T.Type, _ json: String) -> T {
        do {
            return try JSON.decoder.decode(T.self, from: Data(json.utf8))
        } catch {
            fatalError("演示数据解析失败 \(T.self)：\(error)")
        }
    }

    static var user: PublicUser {
        decode(PublicUser.self, """
        {"id":"u-me","display_name":"小林","phone_masked":"138****5621","time_zone":"Asia/Shanghai","has_wechat":false,"has_apple":false}
        """)
    }

    static var connections: [Connection] {
        func c(_ id: String, _ name: String, _ relation: String, daysAgo: Double, guards: String?) -> String {
            let g = guards.map { ",\"guards_me\":\($0)" } ?? ""
            return """
            {"peer":{"id":"\(id)","display_name":"\(name)"},"relation":"\(relation)","connected_at":"\(iso(-60 * day))","last_together_at":"\(iso(-daysAgo * day))"\(g)}
            """
        }
        let standing = { (id: String) in "{\"grant_id\":\"g-\(id)\",\"tier\":\"standing\",\"can_see\":\"全程看到位置\",\"bind_to_escort\":false}" }
        let temp = "{\"grant_id\":\"g-zy\",\"tier\":\"temporary\",\"can_see\":\"仅联系不上时看到位置\",\"bind_to_escort\":true}"
        let list = [
            c("p-zy", "周雨", "朋友", daysAgo: 0.1, guards: temp),
            c("p-ak", "阿珂", "室友", daysAgo: 1, guards: standing("ak")),
            c("p-mm", "妈妈", "妈妈", daysAgo: 3, guards: standing("mm")),
            c("p-tt", "唐唐", "同事", daysAgo: 12, guards: nil),
            c("p-aj", "阿杰", "朋友", daysAgo: 23, guards: standing("aj")),
            c("p-xz", "小赵", "同学", daysAgo: 40, guards: nil),
        ]
        return decode([Connection].self, "[" + list.joined(separator: ",") + "]")
    }

    private static let guardiansJSON = """
    [{"id":"p-zy","display_name":"周雨","tier":"temporary","can_see":"仅联系不上时看到位置"},
     {"id":"p-ak","display_name":"阿珂","tier":"standing","can_see":"全程看到位置"},
     {"id":"p-mm","display_name":"妈妈","tier":"standing","can_see":"全程看到位置"}]
    """

    /// 护航：active（12:05 后签到）/ alerting（超时或求救）/ paused（暂停到明早 8:00）
    static func escort(_ status: String, sos: Bool = false) -> Escort {
        let due = status == "alerting" ? -134.0 : 12 * 60 + 5
        let incident = status == "alerting"
            ? ",\"incident\":{\"id\":\"i-1\",\"opened_at\":\"\(iso(-120))\",\"kind\":\"\(sos ? "sos" : "missed")\"}"
            : ""
        let paused = status == "paused" ? ",\"paused_until\":\"\(iso(7 * 3600))\"" : ""
        return decode(Escort.self, """
        {"id":"e-1","status":"\(status)","stage":"\(status == "alerting" ? "escalated" : "waiting")","interval_min":30,
         "started_at":"\(iso(-38 * 60 - 12))","started_from":"phone","destination_label":"家",
         "next_due_at":"\(iso(due))","guardians":\(guardiansJSON)\(incident)\(paused)}
        """)
    }

    static var startOptions: StartOptions {
        func cand(_ id: String, _ name: String, _ tier: String, _ see: String, checked: Bool, warning: String?) -> String {
            let ready = warning == nil
            let w = warning.map { "\"\($0)\"" } ?? "null"
            return """
            {"guardian":{"id":"\(id)","display_name":"\(name)"},"grant_id":"g-\(id)","tier":"\(tier)","can_see":"\(see)","default_checked":\(checked),
             "readiness":{"ready":\(ready),"notifications_on":\(ready),"critical_alerts_on":false,"opened_recently":true,"warning":\(w)}}
            """
        }
        let list = [
            cand("p-mm", "妈妈", "standing", "全程看到位置", checked: true, warning: nil),
            cand("p-ak", "阿珂", "standing", "全程看到位置", checked: true, warning: nil),
            cand("p-zy", "周雨", "temporary", "仅联系不上时看到位置", checked: true, warning: nil),
            cand("p-aj", "阿杰", "standing", "全程看到位置", checked: false, warning: "可能收不到通知"),
        ]
        return decode(StartOptions.self, """
        {"candidates":[\(list.joined(separator: ","))],"intervals":[15,30,60],"default_interval":30,"max_guardians":6}
        """)
    }

    static var guardCards: [GuardCard] {
        decode([GuardCard].self, """
        [{"escort_id":"e-xl","owner":{"id":"p-xl","display_name":"小林"},"status":"alerting","my_tier":"standing","started_at":"\(iso(-50 * 60))","can_view_location":true,
          "incident":{"id":"i-1","kind":"sos","contacting_by_me":false}},
         {"escort_id":"e-mia","owner":{"id":"p-mia","display_name":"Mia"},"status":"active","my_tier":"temporary","next_due_at":"\(iso(18 * 60))","started_at":"\(iso(-40 * 60))","can_view_location":false},
         {"escort_id":"e-jj","owner":{"id":"p-jj","display_name":"姐姐"},"status":"paused","my_tier":"standing","paused_until":"\(iso(8 * 3600))","started_at":"\(iso(-3 * 3600))","can_view_location":false},
         {"escort_id":"e-mm","owner":{"id":"p-mm","display_name":"妈妈"},"status":"ended","my_tier":"standing","started_at":"\(iso(-5 * 3600))","ended_at":"\(iso(-4 * 3600))","end_reason":"home","can_view_location":false}]
        """)
    }

    /// 出示邀请（invite 场景）
    static var invite: Invite {
        decode(Invite.self, """
        {"id":"inv-1","kind":"standing","token":"Xk2pQ9vLmT4wZr8a","url":"https://ye.example.com/i/Xk2pQ9vLmT4wZr8a","expires_at":"\(iso(23 * 3600 + 41 * 60))"}
        """)
    }

    /// 朋友那边弹出的“成为担保人”（confirm 场景）
    static var invitePreview: InvitePreview {
        decode(InvitePreview.self, """
        {"state":"valid","kind":"standing","inviter":{"display_name":"小林"},"expires_at":"\(iso(23 * 3600))",
         "headline":"小林邀请你长期守护她","explain":"她护航时你会收到通知并看到她的位置，护航结束就看不到了。","offer_reverse":true}
        """)
    }

    static var incident: IncidentView {
        decode(IncidentView.self, """
        {"id":"i-1","escort_id":"e-xl","owner":{"id":"p-xl","display_name":"小林"},"opened_at":"\(iso(-60))","contacting_by_me":true,
         "last_location":{"lat":31.2304,"lng":121.4737,"h_acc_m":18,"recorded_at":"\(iso(-60))","battery_pct":41,"source":"phone"},
         "my_tier":"standing","can_pause_or_end":true,"kind":"sos","owner_phone":"+8613800135621"}
        """)
    }
}
#endif
