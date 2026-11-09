import EscortKit
import SwiftUI
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var showHomePlaces = SettingsView.demoOpensHomePlaces

    private static var demoOpensHomePlaces: Bool {
        #if DEBUG
        return ["myhome", "pickplace"].contains(DemoMode.scene ?? "")
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(name: model.user?.displayName ?? "我", url: model.user?.avatarUrl, size: 52)
                        VStack(alignment: .leading) {
                            Text(model.user?.displayName ?? "").font(.pf(.headline))
                            Text(model.user?.phoneMasked ?? "").font(.pf(.footnote)).foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    NavigationLink { WhoCanSeeMeView() } label: { Label("谁能看到我", systemImage: "eye") }
                    NavigationLink { HomePlacesView() } label: { Label("我的家", systemImage: "house") }
                    NavigationLink { GuardingWhoView() } label: { Label("我在守护的人", systemImage: "shield") }
                }
                Section {
                    NotificationStatusRow()
                } footer: {
                    Text("别人选你当担保人时，只能靠通知叫醒你。关了通知，对方开始护航时会看到“可能收不到通知”。")
                }
                Section {
                    Button("退出登录") { Task { await model.signOut() } }
                    Button("删除账号", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("我的")
            .navigationDestination(isPresented: $showHomePlaces) { HomePlacesView() }
            .confirmationDialog("删除后所有连接、授权和位置记录立即删除，不能恢复。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除账号", role: .destructive) {
                    Task {
                        try? await model.api.deleteAccount()
                        await model.signOut()
                    }
                }
            }
        }
    }
}

struct NotificationStatusRow: View {
    @State private var settings: UNNotificationSettings?
    var body: some View {
        HStack {
            Label("通知", systemImage: "bell.badge")
            Spacer()
            if let s = settings {
                if s.authorizationStatus == .authorized {
                    Text(s.criticalAlertSetting == .enabled ? "已开启（含紧急提醒）" : "已开启").foregroundStyle(.secondary)
                } else {
                    Button("去打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                }
            }
        }
        .task { settings = await UNUserNotificationCenter.current().notificationSettings() }
    }
}

/// “谁能看到我”（3.7）
struct WhoCanSeeMeView: View {
    @EnvironmentObject var model: AppModel
    @State private var data: WhoCanSeeMe?

    var body: some View {
        List {
            if let d = data {
                Section {
                    Text(d.headline).font(.pf(.headline))
                } footer: {
                    Text("不管常驻还是临时，护航之外谁都看不到你的位置。")
                }
                Section("有效的守护") {
                    ForEach(d.grants) { g in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack { Text(g.guardian.displayName).font(.pf(.headline)); TierBadge(tier: g.tier) }
                            Text(g.canSee).font(.pf(.subheadline))
                            Text(g.expiryText).font(.pf(.caption)).foregroundStyle(.secondary)
                            if let v = g.lastViewedAt {
                                Text("最近一次查看你的位置：\(v.formatted(date: .abbreviated, time: .shortened))").font(.pf(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        .swipeActions {
                            Button("移出", role: .destructive) {
                                Task {
                                    try? await model.api.revokeGrant(id: g.id)
                                    await load()
                                }
                            }
                        }
                    }
                }
                if d.grants.contains(where: { $0.tier == .temporary }) {
                    Section {
                        AsyncButton {
                            try await model.api.revokeAllTemporary()
                            await load()
                        } label: { Text("撤回所有临时授权").foregroundStyle(Theme.danger) }
                    }
                }
            } else {
                ProgressView()
            }
        }
        .navigationTitle("谁能看到我")
        .task { await load() }
        .refreshable { await load() }
    }

    private func load() async {
        data = try? await model.api.whoCanSeeMe()
    }
}

struct GuardingWhoView: View {
    @EnvironmentObject var model: AppModel
    @State private var list: [GrantToMe] = []
    var body: some View {
        List(list) { g in
            VStack(alignment: .leading, spacing: 4) {
                HStack { Text(g.owner.displayName).font(.pf(.headline)); TierBadge(tier: g.tier) }
                Text("\(g.canSee) · \(g.expiryText)").font(.pf(.caption)).foregroundStyle(.secondary)
            }
            .swipeActions {
                Button("不再守护", role: .destructive) {
                    Task {
                        try? await model.api.revokeGrant(id: g.id)
                        list = (try? await model.api.grantsToMe()) ?? []
                    }
                }
            }
        }
        .overlay { if list.isEmpty { ContentUnavailableView("你还没有在守护谁", systemImage: "shield") } }
        .navigationTitle("我在守护的人")
        .task { list = (try? await model.api.grantsToMe()) ?? [] }
    }
}

/// “我的家”（6.5）：最多两处，只存这台 iPhone 和手表，不上传
struct HomePlacesView: View {
    @EnvironmentObject var model: AppModel
    @State private var places: [HomePlace] = HomePlaceStore.load()
    @State private var editing: HomePlace?
    @State private var adding = HomePlacesView.demoOpensPicker

    private static var demoOpensPicker: Bool {
        #if DEBUG
        return DemoMode.scene == "pickplace"
        #else
        return false
        #endif
    }

    var body: some View {
        List {
            Section {
                ForEach(places) { p in
                    Button { editing = p } label: {
                        VStack(alignment: .leading) {
                            Text(p.name).foregroundStyle(.primary)
                            Text("范围 \(Int(p.radiusM)) 米").font(.pf(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                .onDelete { idx in
                    places.remove(atOffsets: idx)
                    save()
                }
                if places.count < HomePlace.maxCount {
                    Button { adding = true } label: { Label("添加地点", systemImage: "plus") }
                }
            } footer: {
                Text("家的位置只存在这台 iPhone 和你的手表上，不会上传，担保人也看不到。换手机后要重新设。到家时只会问你一句“安全到家了吗”，不会替你自动结束。")
            }
        }
        .navigationTitle("我的家")
        .sheet(isPresented: $adding) {
            PlacePicker(title: "添加地点", initial: nil) { p in
                if let p { places.append(p); save() }
            }
        }
        .sheet(item: $editing) { p in
            PlacePicker(title: "修改地点", initial: p) { np in
                if let np, let i = places.firstIndex(where: { $0.id == np.id }) { places[i] = np; save() }
            }
        }
    }

    private func save() {
        HomePlaceStore.save(places)
        WatchBridge.shared.send(.homePlaces(places))
    }
}
