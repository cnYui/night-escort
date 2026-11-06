import EscortKit
import SwiftUI
import UIKit

/// 首页：搜索栏 + 「+」，关系图谱，开始护航 / 护航中面板。
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
                HStack(spacing: 12) {
                    Button { showSearch = true } label: {
                        HStack {
                            Image(systemName: "magnifyingglass")
                            Text("搜索联系人").foregroundStyle(.secondary)
                            Spacer()
                        }
                        .padding(10)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    Button { showAdd = true } label: {
                        Image(systemName: "plus").font(.title3.weight(.semibold))
                            .frame(width: 42, height: 42)
                            .background(Theme.accent, in: Circle())
                            .foregroundStyle(.white)
                    }
                    .accessibilityLabel("添加联系人")
                }
                .padding(.horizontal)
                .padding(.top, 8)

                if let inter = model.escort?.intervention, model.escort?.status != .active {
                    InterventionBanner(text: inter.text)
                }

                GraphView(
                    me: model.user?.displayName ?? "我",
                    connections: model.connections,
                    inEscort: Set(model.escort?.guardians.map(\.id) ?? []),
                    onTap: { selected = $0 },
                    onDragOut: { scheduleRemoval($0) }
                )
                .frame(maxHeight: .infinity)

                if let e = model.escort, e.isOpen {
                    ActiveEscortPanel(escort: e)
                } else {
                    HStack(alignment: .center, spacing: 14) {
                        Button { showStart = true } label: {
                            Label("开始护航", systemImage: "moon.stars.fill").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(PrimaryButtonStyle())
                        SOSHoldButton { await model.sos() }
                    }
                    .padding()
                }
            }
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
            .navigationTitle("到家没")
            .navigationBarTitleDisplayMode(.inline)
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
            Text(text).font(.subheadline)
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
        VStack(spacing: 12) {
            TimelineView(.periodic(from: .now, by: 1)) { ctx in
                VStack(spacing: 4) {
                    Text(Display.ownerHeadline(escort, now: ctx.date))
                        .font(.subheadline)
                        .foregroundStyle(escort.status == .alerting ? Theme.danger : .secondary)
                    if escort.status == .active, let due = escort.nextDueAt {
                        Text(Display.countdown(to: due, now: ctx.date))
                            .font(.system(size: 44, weight: .semibold, design: .rounded))
                            .monospacedDigit()
                    }
                    Text("\(escort.guardians.count) 人在守").font(.caption).foregroundStyle(.secondary)
                }
            }
            HStack(alignment: .center, spacing: 12) {
                AsyncButton { await model.checkin(.ok) } label: {
                    Text("我没事").frame(maxWidth: .infinity)
                }
                .buttonStyle(PrimaryButtonStyle(color: escort.status == .alerting ? Theme.danger : Theme.accent))
                Menu {
                    Button("我到了，结束") { Task { await model.checkin(.arrived) } }
                    Button("我在别处过夜，结束") { Task { await model.checkin(.elsewhere) } }
                    Button("结束护航", role: .destructive) { Task { await model.endEscort() } }
                } label: {
                    Text("结束").font(.headline).frame(width: 76).padding(.vertical, 14)
                        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 14))
                }
                // 已经在求救了就不再显示
                if escort.incident?.isSOS != true {
                    SOSHoldButton { await model.sos() }
                }
            }
        }
        .padding()
        .background(.background)
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
                Circle().fill(Theme.danger.opacity(0.12))
                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(Theme.danger, style: StrokeStyle(lineWidth: 4, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .padding(2)
                if busy {
                    ProgressView().tint(Theme.danger)
                } else {
                    Text("SOS").font(.system(size: size * 0.28, weight: .heavy, design: .rounded))
                }
            }
            .foregroundStyle(Theme.danger)
            .frame(width: size, height: size)
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
            Text("长按求救").font(.caption2.weight(.semibold)).foregroundStyle(Theme.danger)
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
