import EscortKit
import SwiftUI
import UIKit

/// 首页：搜索栏 + 「+」，谁在守护我（气泡或列表），我要回家了 / 回家路上面板。
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @State private var showAdd = false
    @State private var showSearch = false
    @State private var showStart = false
    @State private var selected: Connection?
    @State private var pendingRemoval: PendingRemoval?

    struct PendingRemoval: Equatable {
        let connection: Connection
        let task: Task<Void, Never>
        static func == (a: Self, b: Self) -> Bool { a.connection.id == b.connection.id }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Button { showSearch = true } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                        Text("搜索联系人").font(.pf(.body)).foregroundStyle(.secondary)
                        Spacer()
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 11)
                    .background(Color(.tertiarySystemFill), in: Capsule())
                }
                .buttonStyle(.plain)
                .padding(.horizontal)
                .padding(.top, 4)

                if let inter = model.escort?.intervention, model.escort?.status != .active {
                    InterventionBanner(text: inter.text)
                }

                switch HomeStyle.current {
                case .bubble:
                    VStack(alignment: .leading, spacing: 2) {
                        Text("谁在守护我").font(.pf(.title3, weight: .semibold))
                        Text("回家时从这些人里选几个，他们会看到你到没到家。")
                            .font(.pf(.footnote)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 18)
                    GraphView(
                        me: model.user?.displayName ?? "我",
                        connections: model.connections,
                        inEscort: Set(model.escort?.guardians.map(\.id) ?? []),
                        onTap: { selected = $0 },
                        onDragOut: { scheduleRemoval($0) }
                    )
                    .frame(maxHeight: .infinity)
                case .list:
                    PeopleListView(
                        connections: model.connections,
                        inEscort: Set(model.escort?.guardians.map(\.id) ?? []),
                        onTap: { selected = $0 },
                        onRemove: { scheduleRemoval($0) }
                    )
                    .frame(maxHeight: .infinity)
                }

                if let e = model.escort, e.isOpen {
                    ActiveEscortPanel(escort: e)
                } else {
                    // 首页不放求救按钮：求救在回家路上的面板里和手表上
                    VStack(spacing: 8) {
                        Button { showStart = true } label: {
                            Label { Text("我要回家了").font(.pf(.headline)) } icon: { Image(systemName: "house.fill") }
                                .padding(.horizontal, 28)
                        }
                        .glassProminentButton()
                        .controlSize(.large)
                        Text("选几个人守着你，到家前定时报个平安")
                            .font(.pf(.footnote)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                }
            }
            .background(HomeStyle.current == .list ? Color(.systemGroupedBackground) : Color(.systemBackground))
            .overlay(alignment: .bottom) {
                if let p = pendingRemoval {
                    HStack {
                        Text("已移出 \(p.connection.shownName)")
                        Spacer()
                        Button("撤销") {
                            p.task.cancel()
                            pendingRemoval = nil
                        }
                        .bold()
                    }
                    .padding()
                    .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
                    .padding()
                    .padding(.bottom, 80)
                }
            }
            .navigationTitle("安全回家")
            .navigationBarTitleDisplayMode(.large)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                        .accessibilityLabel("添加联系人")
                }
            }
            #if DEBUG
            .onAppear { if DemoMode.scene == "start" { showStart = true } }
            #endif
            .refreshable { await model.refreshAll() }
            .sheet(isPresented: $showAdd) { AddSheet().environmentObject(model) }
            .sheet(isPresented: $showSearch) { SearchView(onPick: { selected = $0 }).environmentObject(model) }
            .sheet(isPresented: $showStart) { StartEscortView().environmentObject(model) }
            .sheet(item: $selected) { c in ContactCard(connection: c).environmentObject(model).presentationDetents([.medium, .large]) }
        }
    }

    /// 拖出图谱 = 移出担保人，底部 5 秒“撤销”（3.8）
    private func scheduleRemoval(_ c: Connection) {
        guard let grant = c.guardsMe else { return }
        if model.escort?.status == .alerting {
            // 联系不上时不允许拖动移出，只能从卡片里确认
            selected = c
            return
        }
        let task = Task {
            try? await Task.sleep(for: .seconds(5))
            if Task.isCancelled { return }
            try? await model.api.revokeGrant(id: grant.grantId)
            await model.refreshAll()
            pendingRemoval = nil
        }
        pendingRemoval = PendingRemoval(connection: c, task: task)
    }
}

struct InterventionBanner: View {
    let text: String
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.shield.fill").foregroundStyle(Theme.accent)
            Text(text).font(.pf(.subheadline))
            Spacer()
        }
        .padding()
        .background(Theme.accent.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
        .padding(.horizontal)
        .padding(.top, 8)
    }
}

/// 护航中：倒计时、我没事、结束；暂停中提示；联系不上时大按钮“我没事”
struct ActiveEscortPanel: View {
    @EnvironmentObject var model: AppModel
    let escort: Escort

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Label {
                            Text(statusTitle).font(.pf(.subheadline, weight: .semibold))
                        } icon: {
                            Image(systemName: escort.status == .alerting ? "exclamationmark.triangle.fill" : "circle.fill")
                                .font(.system(size: escort.status == .alerting ? 13 : 7))
                        }
                        .foregroundStyle(escort.status == .alerting ? Theme.danger : Theme.accent)
                        Spacer()
                        Text("\(escort.guardians.count) 人在守").font(.pf(.subheadline)).foregroundStyle(.secondary)
                    }
                    if escort.status == .active, let due = escort.nextDueAt {
                        HStack(alignment: .lastTextBaseline, spacing: 10) {
                            Text(Display.countdown(to: due, now: ctx.date))
                                .font(.pf(size: 52, weight: .semibold))
                                .monospacedDigit()
                            Text("后签到 · \(Display.hhmm(due))").font(.pf(.subheadline)).foregroundStyle(.secondary)
                        }
                        ProgressView(value: progress(due: due, now: ctx.date))
                    } else {
                        Text(Display.ownerHeadline(escort, now: ctx.date))
                            .font(.pf(.body))
                            .foregroundStyle(escort.status == .alerting ? Theme.danger : .primary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack(alignment: .center, spacing: 10) {
                AsyncButton { await model.checkin(.ok) } label: {
                    Text("我没事").font(.pf(.headline)).frame(maxWidth: .infinity)
                }
                .glassProminentButton(tint: escort.status == .alerting ? Theme.danger : nil)
                .controlSize(.large)
                Menu {
                    Button("我到了，结束") { Task { await model.checkin(.arrived) } }
                    Button("我在别处过夜，结束") { Task { await model.checkin(.elsewhere) } }
                    Button("结束，不用再守了", role: .destructive) { Task { await model.endEscort() } }
                } label: {
                    Text("结束").font(.pf(.headline)).padding(.horizontal, 6)
                }
                .glassButton()
                .controlSize(.large)
                // 已经在求救了就不再显示
                if escort.incident?.isSOS != true {
                    SOSHoldButton { await model.sos() }
                }
            }
        }
        .padding(20)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
        .padding(.horizontal)
        .padding(.bottom, 8)
    }

    private var statusTitle: String {
        switch escort.status {
        case .alerting: return escort.incident?.isSOS == true ? "已发出求救" : "需要你回应"
        case .paused: return "已暂停"
        default: return "回家路上"
        }
    }

    /// 这一轮签到间隔已经过去多少（0…1）
    private func progress(due: Date, now: Date) -> Double {
        guard escort.intervalMin > 0 else { return 0 }
        let total = Double(escort.intervalMin * 60)
        return min(1, max(0, 1 - max(0, due.timeIntervalSince(now)) / total))
    }
}

/// 一键求救：长按 2 秒，圆环走满就发出，所有担保人立刻响铃。
/// 长按是为了防误触；VoiceOver 下双击直接发出。
struct SOSHoldButton: View {
    var size: CGFloat = 54
    let action: () async -> Void
    @State private var progress: CGFloat = 0
    @State private var fired = false
    @State private var busy = false
    static let holdSeconds: Double = 2

    var body: some View {
        VStack(spacing: 3) {
            ZStack {
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                if busy {
                    ProgressView().tint(Theme.danger)
                } else {
                    Text("SOS").font(.pf(size: size * 0.28, weight: .semibold))
                }
            }
            .foregroundStyle(Theme.danger)
            .frame(width: size, height: size)
            .glassBackground(in: Circle(), tint: Theme.danger)
            .contentShape(Circle())
            .onLongPressGesture(minimumDuration: Self.holdSeconds, maximumDistance: 40) {
                fired = true
                fire()
            } onPressingChanged: { pressing in
                if pressing {
                    fired = false
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    withAnimation(.linear(duration: Self.holdSeconds)) { progress = 1 }
                } else if !fired {
                    withAnimation(.easeOut(duration: 0.2)) { progress = 0 }
                }
            }
            Text("长按求救").font(.pf(.caption2, weight: .semibold)).foregroundStyle(Theme.danger)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("紧急求救")
        .accessibilityHint("长按两秒，立刻通知你所有的担保人")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { fire() }
    }

    private func fire() {
        guard !busy else { return }
        busy = true
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
        Task {
            await action()
            busy = false
            withAnimation(.easeOut(duration: 0.3)) { progress = 0 }
        }
    }
}
