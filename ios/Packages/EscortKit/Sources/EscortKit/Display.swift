import Foundation

/// 界面文案和倒计时：手机、手表、灵动岛共用，保证三处说法一致。
public enum Display {
    /// “23:52 出发”这类时间
    public static func hhmm(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let c = cal.dateComponents([.hour, .minute], from: d)
        return String(format: "%02d:%02d", c.hour ?? 0, c.minute ?? 0)
    }

    /// 倒计时 “12:05”；超过一小时 “1:02:03”；过了就是 “00:00”
    public static func countdown(to due: Date, now: Date) -> String {
        let s = max(0, Int(due.timeIntervalSince(now).rounded(.down)))
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%02d:%02d", m, sec)
    }

    /// 出行者首页上的一句话状态
    public static func ownerHeadline(_ e: Escort, now: Date) -> String {
        switch e.status {
        case .active:
            switch e.stage {
            case .waiting:
                if let due = e.nextDueAt { return "\(hhmm(due)) 前报一次平安" }
                return "回家路上"
            case .due: return "到签到时间了"
            case .reminded: return "还没签到，5 分钟内不回应会请担保人联系你"
            case .escalated: return "担保人正在联系你"
            }
        case .alerting:
            if e.incident?.isSOS == true { return "已发出求救，担保人正在联系你。安全了就点“我没事”解除" }
            return "担保人正在联系你，点“我没事”报平安"
        case .paused:
            if let u = e.pausedUntil { return "已暂停到 \(hhmm(u))" }
            return "已暂停"
        case .ended: return "护航已结束"
        }
    }

    /// 担保人守护页卡片上的一句话
    public static func guardianLine(_ c: GuardCard, now: Date) -> String {
        switch c.status {
        case .alerting:
            if let inc = c.incident {
                if inc.contactingByMe { return "你正在联系她" }
                if let n = inc.contactingName { return "\(n)正在联系她" }
                if inc.isSOS { return "她发起了求救，请马上打电话给她" }
            }
            return "联系不上，请尝试联系她"
        case .active:
            if let due = c.nextDueAt { return "在回家路上，\(hhmm(due)) 前报平安" }
            return "在回家路上"
        case .paused:
            if let u = c.pausedUntil { return "她在别处过夜，暂停到 \(hhmm(u))" }
            return "已暂停"
        case .ended:
            switch c.endReason {
            case "home": return "已安全到家"
            case "elsewhere": return "在别处过夜，已结束"
            case "by_guardian": return "已由担保人代为结束"
            default: return "已结束"
            }
        }
    }

    /// 临时权限卡底部的一句话总结（设计文档 3.3）
    public static func temporarySummary(name: String, template t: TemporaryTemplate) -> String {
        let see = t.locationScope == .alertOnly ? "只会在你失联时收到通知和最后位置" : "护航全程能看到你的位置"
        let end: String
        switch (t.expires, t.onExpire) {
        case (.escort, .remove): end = "你到家后她从你的列表里消失"
        case (.escort, .keep): end = "你到家后她变回普通联系人"
        case (.tonight, .remove): end = "明早 6:00 后她从你的列表里消失"
        case (.tonight, .keep): end = "明早 6:00 后她变回普通联系人"
        case (.sevenDays, .remove): end = "7 天后她从你的列表里消失"
        case (.sevenDays, .keep): end = "7 天后她变回普通联系人"
        }
        return "\(name)\(see)，\(end)。"
    }

    public static func tierLabel(_ t: Tier) -> String { t == .standing ? "常驻" : "临时" }
}
