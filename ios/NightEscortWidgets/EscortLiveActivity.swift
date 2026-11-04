import ActivityKit
import EscortKit
import SwiftUI
import WidgetKit

@main
struct NightEscortWidgetBundle: WidgetBundle {
    var body: some Widget {
        EscortLiveActivity()
    }
}

/// 锁屏和灵动岛（4.4）：下次签到倒计时、“N 人在守”；联系不上时变红写“谁正在联系你”。
struct EscortLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: EscortActivityAttributes.self) { ctx in
            LockScreenView(state: ctx.state)
                .padding()
                .activityBackgroundTint(ctx.state.status == "alerting" ? Color.red.opacity(0.25) : Color.black.opacity(0.6))
        } dynamicIsland: { ctx in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label("\(ctx.state.guardianCount) 人在守", systemImage: "shield.fill").font(.caption)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    CountdownText(state: ctx.state).font(.title3.monospacedDigit())
                }
                DynamicIslandExpandedRegion(.bottom) {
                    Text(StatusText.line(ctx.state)).font(.footnote).foregroundStyle(.secondary)
                }
            } compactLeading: {
                Image(systemName: ctx.state.status == "alerting" ? "exclamationmark.shield.fill" : "moon.stars.fill")
                    .foregroundStyle(ctx.state.status == "alerting" ? .red : .indigo)
            } compactTrailing: {
                CountdownText(state: ctx.state).monospacedDigit().frame(maxWidth: 48)
            } minimal: {
                Image(systemName: "moon.stars.fill").foregroundStyle(.indigo)
            }
        }
    }
}

private struct LockScreenView: View {
    let state: EscortActivityAttributes.ContentState
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text("夜归护航").font(.headline)
                Text(StatusText.line(state)).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            CountdownText(state: state).font(.title.monospacedDigit().weight(.semibold))
        }
    }
}

private struct CountdownText: View {
    let state: EscortActivityAttributes.ContentState
    var body: some View {
        if state.status == "active", let due = state.nextDueAt, due > Date() {
            Text(timerInterval: Date()...due, countsDown: true)
        } else if state.status == "paused" {
            Text("暂停")
        } else if state.status == "alerting" {
            Text("联系中").foregroundStyle(.red)
        } else {
            Text("签到")
        }
    }
}

private enum StatusText {
    static func line(_ s: EscortActivityAttributes.ContentState) -> String {
        switch s.status {
        case "alerting":
            if let n = s.contactingName { return "\(n)正在联系你" }
            return "担保人正在联系你，回个消息报平安"
        case "paused": return "已暂停，明早 8:00 提醒你"
        default: return "\(s.guardianCount) 人在守 · 到点会提醒你签到"
        }
    }
}
