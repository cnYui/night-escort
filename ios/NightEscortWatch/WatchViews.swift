import EscortKit
import SwiftUI
import WatchKit

// MARK: - 主题：watchOS 默认的黑底 + 系统蓝；按钮用系统液态玻璃；字体苹方

enum WTheme {
    static let accent = Color.blue
    static let ink = Color.white
    static let sub = Color.secondary
    /// 求救和超时专用的红
    static let danger = Color.red
    /// watchOS 默认的灰色卡片底
    static let platter = Color(white: 0.11)
}

/// 屏幕上方的系统图标（SF Symbols）
struct WIcon: View {
    let systemName: String
    var size: CGFloat = 34
    var color: Color = WTheme.accent
    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size, weight: .medium))
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(color)
            .frame(height: size + 4)
            .accessibilityHidden(true)
    }
}

/// 左上角的小标签
struct WLabel: View {
    let text: String
    var color: Color = WTheme.accent
    var dot = false
    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(text).font(.pf(size: 13, weight: .semibold)).foregroundStyle(color)
        }
    }
}

extension Text {
    /// 手表大标题
    func wTitle(_ size: CGFloat = 20) -> some View {
        self.font(.pf(size: size, weight: .semibold)).foregroundStyle(WTheme.ink)
    }

    /// 手表说明文字
    func wSub() -> some View {
        self.font(.pf(size: 13)).foregroundStyle(WTheme.sub)
    }
}

extension Text {
    /// 手表按钮上的字：苹方 Semibold，撑满一行
    func wButton() -> some View {
        self.font(.pf(size: 16, weight: .semibold)).frame(maxWidth: .infinity)
    }
}

// MARK: - 根视图

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        Group {
            if !model.signedIn {
                SignInView()
            } else if let e = model.escort, e.status != .ended {
                switch e.status {
                case .alerting: AlertingView(escort: e)
                case .paused: PausedView(escort: e)
                default: EscortRunningView(escort: e)
                }
            } else {
                IdleView()
            }
        }
        .font(.pf(.body))
        .task { await model.refresh() }
        .sheet(item: Binding(get: { model.askHome.map(HomeAsk.init) }, set: { if $0 == nil { model.askHome = nil } })) { ask in
            HomeAskView(place: ask.place).environmentObject(model)
        }
        .sheet(isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            MessageView(text: model.message ?? "").environmentObject(model)
        }
    }
}

private struct HomeAsk: Identifiable {
    let place: String
    var id: String { place }
}

// MARK: - ① 未登录

struct SignInView: View {
    @EnvironmentObject var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "安全回家")
                WIcon(systemName: "iphone", size: 40)
                Text("在 iPhone 上\n登录一下").wTitle()
                Text("登录后手表会自动同步").wSub()
                Button { model.requestTokensFromPhone() } label: { Text("重试").wButton() }
                    .glassButton()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ② 待机：长按开始（防误触）

struct IdleView: View {
    @EnvironmentObject var model: WatchModel
    @State private var hint = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "安全回家")
                WIcon(systemName: "moon.stars.fill", size: 40)
                Text("今晚\n平安到家").wTitle(22)
                Text(hint ? "按住 1 秒才会开始" : "用手机上的默认担保人").wSub()
                Button {
                    // 轻点不开始，只提示要按住，防止抬手误触
                    hint = true
                    WKInterfaceDevice.current().play(.click)
                } label: {
                    Group {
                        if model.busy {
                            ProgressView()
                        } else {
                            Label("长按开始", systemImage: "play.fill")
                        }
                    }
                    .font(.pf(size: 16, weight: .semibold))
                    .frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                .simultaneousGesture(LongPressGesture(minimumDuration: 1).onEnded { _ in
                    Task { await model.start() }
                })
                .disabled(model.busy)
                .accessibilityLabel("开始护航")
                .accessibilityHint("长按一秒开始")
                .accessibilityAction(named: "开始护航") { Task { await model.start() } }
                .padding(.top, 4)
                WSOSHoldButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 一键求救：长按 2 秒，红色进度走满就发出，所有担保人立刻响铃
struct WSOSHoldButton: View {
    @EnvironmentObject var model: WatchModel
    @State private var progress: CGFloat = 0
    @State private var fired = false
    static let holdSeconds: Double = 2

    var body: some View {
        Label("长按 2 秒求救", systemImage: "sos")
            .font(.pf(size: 15, weight: .semibold))
            .foregroundStyle(WTheme.danger)
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(alignment: .leading) {
                GeometryReader { g in
                    Rectangle().fill(WTheme.danger.opacity(0.35)).frame(width: max(0, g.size.width * progress))
                }
            }
            .clipShape(Capsule())
            .glassBackground(in: Capsule(), tint: WTheme.danger)
            .contentShape(Capsule())
            .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 30) {
                fired = true
                fire()
            } onPressingChanged: { pressing in
                if pressing {
                    fired = false
                    WKInterfaceDevice.current().play(.click)
                    withAnimation(.linear(duration: Self.holdSeconds)) { progress = 1 }
                } else if !fired {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            }
            .disabled(model.busy)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("紧急求救")
            .accessibilityHint("长按两秒，立刻通知你所有的担保人")
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { fire() }
    }

    private func fire() {
        Task {
            await model.sos()
            withAnimation(.easeOut(duration: 0.3)) { progress = 0 }
        }
    }
}

// MARK: - ③ 护航中

struct EscortRunningView: View {
    @EnvironmentObject var model: WatchModel
    let escort: Escort
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "护航中", dot: true)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let due = escort.nextDueAt {
                                    Text(Display.countdown(to: due, now: ctx.date))
                                        .font(.pf(size: 34, weight: .semibold))
                                        .monospacedDigit()
                                        .foregroundStyle(WTheme.ink)
                                    Text(due < ctx.date ? "到签到时间了" : "后签到 · \(Display.hhmm(due))").wSub()
                                } else {
                                    Text("护航中").wTitle(24)
                                }
                            }
                            Spacer(minLength: 0)
                            WIcon(systemName: "figure.walk", size: 30)
                        }
                        ProgressView(value: progress(now: ctx.date))
                            .tint(WTheme.accent)
                            .accessibilityHidden(true)
                        HStack(spacing: 6) {
                            StatTile(value: Display.countdown(to: ctx.date, now: escort.startedAt), label: "已护航")
                            StatTile(value: "\(escort.guardians.count) 人", label: "在守")
                        }
                    }
                }
                Button { Task { await model.checkin() } } label: { Text("我没事").wButton() }
                    .glassProminentButton()
                    .disabled(model.busy)
                    .padding(.top, 2)
                Button { Task { await model.checkin(.arrived) } } label: { Text("到了，结束").wButton() }
                    .glassButton()
                    .disabled(model.busy)
                Button { confirmEnd = true } label: {
                    Text("结束护航").font(.pf(size: 15)).frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
                .foregroundStyle(WTheme.sub)
                .padding(.vertical, 4)
                WSOSHoldButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("结束这次护航？", isPresented: $confirmEnd) {
            Button("结束", role: .destructive) { Task { await model.end() } }
        }
    }

    /// 这一轮签到间隔已经过去多少（0…1）
    private func progress(now: Date) -> Double {
        guard let due = escort.nextDueAt, escort.intervalMin > 0 else { return 0 }
        let total = Double(escort.intervalMin * 60)
        let remaining = max(0, due.timeIntervalSince(now))
        return min(1, max(0, 1 - remaining / total))
    }
}

/// 小卡片：watchOS 默认的灰色圆角底
struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.pf(size: 16, weight: .semibold))
                .monospacedDigit()
                .foregroundStyle(WTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.pf(size: 11))
                .foregroundStyle(WTheme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(WTheme.platter, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}

// MARK: - ④ 已暂停

struct PausedView: View {
    @EnvironmentObject var model: WatchModel
    let escort: Escort
    @State private var confirmEnd = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "已暂停", color: WTheme.sub, dot: true)
                WIcon(systemName: "pause.circle.fill", size: 40)
                Text(escort.pausedUntil.map { "暂停到\n\(Display.hhmm($0))" } ?? "已暂停").wTitle()
                Text("在别处过夜 · 担保人已知道").wSub()
                Button { confirmEnd = true } label: { Text("结束护航").wButton() }
                    .glassButton()
                    .disabled(model.busy)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .confirmationDialog("结束这次护航？", isPresented: $confirmEnd) {
            Button("结束", role: .destructive) { Task { await model.end() } }
        }
    }
}

// MARK: - ⑤ 超时：担保人正在联系你

struct AlertingView: View {
    @EnvironmentObject var model: WatchModel
    let escort: Escort

    private var isSOS: Bool { escort.incident?.isSOS == true }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: isSOS ? "已发出求救" : "需要你回应", color: WTheme.danger, dot: true)
                WIcon(systemName: isSOS ? "sos.circle.fill" : "bell.fill", size: 40, color: WTheme.danger)
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if let due = escort.nextDueAt, due < ctx.date {
                        Text("已超时 \(Display.countdown(to: ctx.date, now: due))")
                            .font(.pf(size: 13, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(WTheme.danger)
                    }
                }
                Text("担保人正在\n联系你").wTitle(21)
                if isSOS {
                    Text("安全了就点“我没事”解除").wSub()
                }
                Button { Task { await model.checkin() } } label: { Text("我没事").wButton() }
                    .glassProminentButton(tint: WTheme.danger)
                    .disabled(model.busy)
                    .padding(.top, 4)
                Button { Task { await model.checkin(.arrived) } } label: { Text("到了，结束").wButton() }
                    .glassButton()
                    .disabled(model.busy)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ⑥ 到家确认

struct HomeAskView: View {
    @EnvironmentObject var model: WatchModel
    let place: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "到家了？")
                WIcon(systemName: "house.fill", size: 40)
                Text("检测到你\n已经到\(place)").wTitle()
                Text("安全到家了吗？").wSub()
                Button { Task { await model.answerHome(arrived: true) } } label: { Text("到了，结束护航").wButton() }
                    .glassProminentButton()
                    .padding(.top, 4)
                Button { Task { await model.answerHome(arrived: false) } } label: { Text("还没，继续").wButton() }
                    .glassButton()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.pf(.body))
    }
}

// MARK: - ⑦ 提示

struct MessageView: View {
    @EnvironmentObject var model: WatchModel
    let text: String

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 6) {
                WLabel(text: "提示")
                WIcon(systemName: "info.circle.fill", size: 40)
                Text(text).wTitle(17)
                Button { model.message = nil } label: { Text("好").wButton() }
                    .glassButton()
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(.pf(.body))
    }
}
