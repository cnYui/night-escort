import EscortKit
import SwiftUI

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        NavigationStack {
            Group {
                if !model.signedIn {
                    VStack(spacing: 8) {
                        Image(systemName: "iphone").font(.title2)
                        Text("在 iPhone 上登录夜归护航后，手表会自动登录").multilineTextAlignment(.center).font(.footnote)
                        Button("重试") { model.requestTokensFromPhone() }
                    }
                } else if let e = model.escort, e.status != .ended {
                    EscortRunningView(escort: e)
                } else {
                    IdleView()
                }
            }
            .navigationTitle("夜归护航")
        }
        .task { await model.refresh() }
        .sheet(item: Binding(get: { model.askHome.map(HomeAsk.init) }, set: { if $0 == nil { model.askHome = nil } })) { ask in
            VStack(spacing: 10) {
                Text("检测到你已经到\(ask.place)，安全到家了吗？").multilineTextAlignment(.center)
                Button("到了，结束护航") { Task { await model.answerHome(arrived: true) } }.tint(.green)
                Button("还没，继续") { Task { await model.answerHome(arrived: false) } }
            }
        }
        .alert(model.message ?? "", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("好") { model.message = nil }
        }
    }
}

private struct HomeAsk: Identifiable {
    let place: String
    var id: String { place }
}

/// 没在护航：长按开始（防误触）
struct IdleView: View {
    @EnvironmentObject var model: WatchModel
    @State private var pressing = false

    var body: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Color.indigo.opacity(pressing ? 0.9 : 0.6))
                if model.busy { ProgressView() } else {
                    VStack {
                        Image(systemName: "moon.stars.fill").font(.title2)
                        Text("长按开始").font(.footnote)
                    }
                }
            }
            .frame(width: 110, height: 110)
            .scaleEffect(pressing ? 0.95 : 1)
            .onLongPressGesture(minimumDuration: 1.0, pressing: { pressing = $0 }) {
                Task { await model.start() }
            }
            Text("用手机上的默认担保人").font(.caption2).foregroundStyle(.secondary)
        }
    }
}

/// 护航中：倒计时、我没事、结束
struct EscortRunningView: View {
    @EnvironmentObject var model: WatchModel
    let escort: Escort
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(spacing: 10) {
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(spacing: 2) {
                        if escort.status == .alerting {
                            Text("担保人正在联系你").font(.headline).foregroundStyle(.red)
                        } else if escort.status == .paused {
                            Text("已暂停").font(.headline)
                        } else if let due = escort.nextDueAt {
                            Text(Display.countdown(to: due, now: ctx.date)).font(.system(size: 34, weight: .semibold, design: .rounded)).monospacedDigit()
                                .foregroundStyle(due < ctx.date ? .orange : .primary)
                            Text("后签到").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
                Text("\(escort.guardians.count) 人在守").font(.caption).foregroundStyle(.secondary)
                Button { Task { await model.checkin() } } label: {
                    Text("我没事").frame(maxWidth: .infinity)
                }
                .tint(.green)
                .disabled(model.busy)
                Button { Task { await model.checkin(.arrived) } } label: {
                    Text("到了，结束").frame(maxWidth: .infinity)
                }
                .disabled(model.busy)
                Button("结束护航", role: .destructive) { confirmEnd = true }
                    .font(.footnote)
            }
        }
        .confirmationDialog("结束这次护航？", isPresented: $confirmEnd) {
            Button("结束", role: .destructive) { Task { await model.end() } }
        }
        .refreshable { await model.refresh() }
    }
}
