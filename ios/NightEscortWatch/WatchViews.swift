import EscortKit
import SwiftUI
import WatchKit

// MARK: - 主题：蜜桃薰衣草（深），和 App 图标同一套

enum WTheme {
    static let base = Color(red: 0x15 / 255, green: 0x11 / 255, blue: 0x1F / 255)
    static let peach = Color(red: 1, green: 0xDA / 255, blue: 0xB9 / 255)
    static let lavender = Color(red: 0xC7 / 255, green: 0xB8 / 255, blue: 0xEA / 255)
    static let ink = Color(red: 1, green: 0xF7 / 255, blue: 0xF0 / 255)
    static let sub = Color(red: 1, green: 0xF7 / 255, blue: 0xF0 / 255).opacity(0.72)
    static let deep = Color(red: 0x2A / 255, green: 0x1F / 255, blue: 0x3D / 255)
    static let alertInk = Color(red: 0x1E / 255, green: 0x15 / 255, blue: 0x30 / 255)
    /// 求救专用的红，只在求救按钮上用
    static let danger = Color(red: 1, green: 0x6B / 255, blue: 0x7D / 255)
    static let brand = LinearGradient(colors: [peach, lavender], startPoint: .leading, endPoint: .trailing)
}

/// 深底 + 左上蜜桃光、右下薰衣草光
struct WBackground: View {
    var body: some View {
        ZStack {
            WTheme.base
            RadialGradient(colors: [WTheme.peach.opacity(0.5), .clear], center: UnitPoint(x: 0.15, y: 0.1), startRadius: 0, endRadius: 120)
            RadialGradient(colors: [WTheme.lavender.opacity(0.55), .clear], center: UnitPoint(x: 0.9, y: 0.92), startRadius: 0, endRadius: 130)
        }
        .ignoresSafeArea()
    }
}

/// 超时：整屏铺满品牌渐变
struct WAlertBackground: View {
    var body: some View {
        LinearGradient(colors: [WTheme.peach, WTheme.lavender], startPoint: .topLeading, endPoint: .bottomTrailing)
            .ignoresSafeArea()
    }
}

struct WPrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(WTheme.deep)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(WTheme.brand, in: Capsule())
            .opacity(configuration.isPressed ? 0.75 : 1)
    }
}

struct WSoftButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 15, weight: .bold, design: .rounded))
            .foregroundStyle(WTheme.ink)
            .frame(maxWidth: .infinity, minHeight: 38)
            .background(Color.white.opacity(0.14), in: Capsule())
            .overlay(Capsule().stroke(Color.white.opacity(0.24), lineWidth: 1))
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

struct WDarkButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 42)
            .background(WTheme.alertInk, in: Capsule())
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

struct WTextButtonStyle: ButtonStyle {
    var color: Color = WTheme.sub
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .bold, design: .rounded))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, minHeight: 30)
            .opacity(configuration.isPressed ? 0.6 : 1)
    }
}

/// 立体图标（Assets 里的 Icon*）
struct WIcon: View {
    let name: String
    var size: CGFloat = 50
    var glow: Color = WTheme.peach.opacity(0.4)
    var body: some View {
        Image(name)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: glow, radius: 8, y: 4)
            .accessibilityHidden(true)
    }
}

/// 左上角的小标签
struct WLabel: View {
    let text: String
    var color: Color = WTheme.peach
    var dot = false
    var body: some View {
        HStack(spacing: 4) {
            if dot { Circle().fill(color).frame(width: 5, height: 5) }
            Text(text).font(.system(size: 13, weight: .heavy, design: .rounded)).foregroundStyle(color)
        }
    }
}

// MARK: - 根视图

struct WatchRootView: View {
    @EnvironmentObject var model: WatchModel

    private var isAlerting: Bool { model.signedIn && model.escort?.status == .alerting }

    var body: some View {
        ZStack {
            if isAlerting { WAlertBackground() } else { WBackground() }
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
            .padding(.horizontal, 6)
        }
        .fontDesign(.rounded)
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
                WLabel(text: "到家没")
                WIcon(name: "IconPhone", size: 46)
                Text("在 iPhone 上\n登录一下")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(WTheme.ink)
                Text("登录后手表会自动同步")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(WTheme.sub)
                Button("重试") { model.requestTokensFromPhone() }
                    .buttonStyle(WSoftButtonStyle())
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - ② 待机：长按开始（防误触）

struct IdleView: View {
    @EnvironmentObject var model: WatchModel
    @State private var pressing = false

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 4) {
            WLabel(text: "到家没")
            WIcon(name: "IconMoon", size: 48)
            Text("今晚\n平安到家")
                .font(.system(size: 22, weight: .heavy, design: .rounded))
                .foregroundStyle(WTheme.ink)
            Text("用手机上的默认担保人")
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(WTheme.sub)
            HStack(spacing: 6) {
                if model.busy {
                    ProgressView().tint(WTheme.deep)
                } else {
                    Image(systemName: "play.fill").font(.system(size: 12, weight: .bold))
                    Text("长按开始")
                }
            }
            .font(.system(size: 16, weight: .heavy, design: .rounded))
            .foregroundStyle(WTheme.deep)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(WTheme.brand, in: Capsule())
            .scaleEffect(pressing ? 0.95 : 1)
            .animation(.easeOut(duration: 0.15), value: pressing)
            .onLongPressGesture(minimumDuration: 1.0, pressing: { pressing = $0 }) {
                Task { await model.start() }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityLabel("开始护航")
            .accessibilityAction { Task { await model.start() } }
            .padding(.top, 4)
            WSOSHoldButton()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// 一键求救：长按 2 秒，进度条走满就发出，所有担保人立刻响铃
struct WSOSHoldButton: View {
    @EnvironmentObject var model: WatchModel
    @State private var progress: CGFloat = 0
    @State private var fired = false
    static let holdSeconds: Double = 2

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "sos").font(.system(size: 13, weight: .heavy))
            Text("长按 2 秒求救")
        }
        .font(.system(size: 14, weight: .heavy, design: .rounded))
        .foregroundStyle(WTheme.danger)
        .frame(maxWidth: .infinity, minHeight: 38)
        .background(alignment: .leading) {
            GeometryReader { g in
                Rectangle().fill(WTheme.danger.opacity(0.35)).frame(width: max(0, g.size.width * progress))
            }
        }
        .background(WTheme.danger.opacity(0.14))
        .clipShape(Capsule())
        .overlay(Capsule().stroke(WTheme.danger.opacity(0.6), lineWidth: 1))
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
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .center) {
                            VStack(alignment: .leading, spacing: 0) {
                                if let due = escort.nextDueAt {
                                    Text(Display.countdown(to: due, now: ctx.date))
                                        .font(.system(size: 34, weight: .heavy, design: .rounded))
                                        .monospacedDigit()
                                        .foregroundStyle(WTheme.ink)
                                    Text(due < ctx.date ? "到签到时间了" : "后签到")
                                        .font(.system(size: 12, weight: .heavy, design: .rounded))
                                        .foregroundStyle(WTheme.peach)
                                } else {
                                    Text("护航中")
                                        .font(.system(size: 24, weight: .heavy, design: .rounded))
                                        .foregroundStyle(WTheme.ink)
                                }
                            }
                            Spacer(minLength: 0)
                            WIcon(name: "IconWalk", size: 44)
                        }
                        ProgressBar(value: progress(now: ctx.date))
                        HStack(spacing: 6) {
                            StatTile(value: Display.countdown(to: ctx.date, now: escort.startedAt), label: "已护航")
                            StatTile(value: "\(escort.guardians.count) 人", label: "在守")
                        }
                    }
                }
                Button("我没事") { Task { await model.checkin() } }
                    .buttonStyle(WPrimaryButtonStyle())
                    .disabled(model.busy)
                    .padding(.top, 2)
                Button("到了，结束") { Task { await model.checkin(.arrived) } }
                    .buttonStyle(WSoftButtonStyle())
                    .disabled(model.busy)
                Button("结束护航") { confirmEnd = true }
                    .buttonStyle(WTextButtonStyle())
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

struct ProgressBar: View {
    let value: Double
    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.15))
                Capsule().fill(WTheme.brand).frame(width: max(6, geo.size.width * value))
            }
        }
        .frame(height: 5)
        .accessibilityHidden(true)
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value)
                .font(.system(size: 16, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(WTheme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(WTheme.sub)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.white.opacity(0.22), lineWidth: 1))
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
                WIcon(name: "IconPause", size: 46)
                Text(escort.pausedUntil.map { "暂停到\n\(Display.hhmm($0))" } ?? "已暂停")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(WTheme.ink)
                Text("在别处过夜 · 担保人已知道")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(WTheme.sub)
                Button("结束护航") { confirmEnd = true }
                    .buttonStyle(WSoftButtonStyle())
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

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 4) {
                WLabel(text: escort.incident?.isSOS == true ? "已发出求救" : "需要你回应", color: WTheme.alertInk)
                WIcon(name: "IconBell", size: 46, glow: Color.black.opacity(0.25))
                TimelineView(.periodic(from: .now, by: 1)) { ctx in
                    if let due = escort.nextDueAt, due < ctx.date {
                        Text("已超时 \(Display.countdown(to: ctx.date, now: due))")
                            .font(.system(size: 12, weight: .bold, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(WTheme.alertInk)
                    }
                }
                Text("担保人正在\n联系你")
                    .font(.system(size: 21, weight: .heavy, design: .rounded))
                    .foregroundStyle(WTheme.alertInk)
                if escort.incident?.isSOS == true {
                    Text("安全了就点“我没事”解除")
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        .foregroundStyle(WTheme.alertInk.opacity(0.75))
                }
                Button("我没事") { Task { await model.checkin() } }
                    .buttonStyle(WDarkButtonStyle())
                    .disabled(model.busy)
                    .padding(.top, 4)
                Button("到了，结束") { Task { await model.checkin(.arrived) } }
                    .buttonStyle(WTextButtonStyle(color: WTheme.alertInk))
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
                WIcon(name: "IconHouse", size: 46)
                Text("检测到你\n已经到\(place)")
                    .font(.system(size: 20, weight: .heavy, design: .rounded))
                    .foregroundStyle(WTheme.ink)
                Text("安全到家了吗？")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(WTheme.sub)
                Button("到了，结束护航") { Task { await model.answerHome(arrived: true) } }
                    .buttonStyle(WPrimaryButtonStyle())
                    .padding(.top, 4)
                Button("还没，继续") { Task { await model.answerHome(arrived: false) } }
                    .buttonStyle(WSoftButtonStyle())
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .background(WBackground())
        .fontDesign(.rounded)
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
                WIcon(name: "IconInfo", size: 46)
                Text(text)
                    .font(.system(size: 17, weight: .heavy, design: .rounded))
                    .foregroundStyle(WTheme.ink)
                Button("好") { model.message = nil }
                    .buttonStyle(WSoftButtonStyle())
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 6)
        }
        .background(WBackground())
        .fontDesign(.rounded)
    }
}
