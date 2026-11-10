import EscortKit
import PhotosUI
import SwiftUI
import UIKit
import UserNotifications

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmDelete = false
    @State private var showHomePlaces = SettingsView.demo("myhome")
    @State private var showMyCode = SettingsView.demo("mycode")
    @State private var pickingAvatar = false
    @State private var avatarItem: PhotosPickerItem?
    @State private var uploadingAvatar = false

    private static func demo(_ scene: String) -> Bool {
        #if DEBUG
        return DemoMode.scene == scene
        #else
        return false
        #endif
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        // 点头像换：从相册选，或去掉回到名字首字
                        Menu {
                            Button { pickingAvatar = true } label: { Label("从相册选一张", systemImage: "photo.on.rectangle") }
                            if model.user?.avatarUrl != nil {
                                Button(role: .destructive) { Task { await removeAvatar() } } label: { Label("去掉头像", systemImage: "trash") }
                            }
                        } label: {
                            avatar
                        }
                        .accessibilityLabel("更换头像")
                        VStack(alignment: .leading, spacing: 2) {
                            Text(model.user?.displayName ?? "").font(.pf(.headline))
                            Text(model.user?.phoneMasked ?? "").font(.pf(.footnote)).foregroundStyle(.secondary)
                            Text("点头像可以更换").font(.pf(.caption)).foregroundStyle(.secondary)
                        }
                    }
                }
                // 加好友从这里出示自己的码、发链接；首页「+」只负责扫别人的码
                Section {
                    NavigationLink { MyCodeView() } label: {
                        Label {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("我的二维码")
                                Text("让朋友扫一扫，或把链接发到微信").font(.pf(.caption)).foregroundStyle(.secondary)
                            }
                        } icon: { Image(systemName: "qrcode") }
                    }
                } footer: {
                    Text("朋友加了你以后，你们回家时都可以选对方守着。")
                }
                Section {
                    NavigationLink { WhoCanSeeMeView() } label: { Label("谁能看到我", systemImage: "eye") }
                    NavigationLink { HomePlacesView() } label: { Label("设定家庭地址", systemImage: "house") }
                }
                Section {
                    NotificationStatusRow()
                } footer: {
                    Text("别人回家时选你守护，只能靠通知叫醒你。关了通知，对方出发前会看到“可能收不到通知”。")
                }
                Section {
                    Button("退出登录") { Task { await model.signOut() } }
                    Button("删除账号", role: .destructive) { confirmDelete = true }
                }
            }
            .navigationTitle("我的")
            .photosPicker(isPresented: $pickingAvatar, selection: $avatarItem, matching: .images)
            .onChange(of: avatarItem) { _, item in
                guard let item else { return }
                Task { await uploadAvatar(item) }
            }
            .navigationDestination(isPresented: $showHomePlaces) { HomePlacesView() }
            .navigationDestination(isPresented: $showMyCode) { MyCodeView() }
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

    private var avatar: some View {
        AvatarView(name: model.user?.displayName ?? "我", url: model.user?.avatarUrl, size: 60)
            .overlay {
                if uploadingAvatar {
                    Circle().fill(.black.opacity(0.35))
                    ProgressView().tint(.white)
                }
            }
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "camera.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Theme.accent, in: Circle())
                    .overlay(Circle().stroke(Color(.secondarySystemGroupedBackground), lineWidth: 2))
            }
    }

    private func uploadAvatar(_ item: PhotosPickerItem) async {
        defer { avatarItem = nil; uploadingAvatar = false }
        uploadingAvatar = true
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data),
              let jpeg = AvatarImage.squareJPEG(image) else {
            model.toast = "这张图片读不出来，换一张试试"
            return
        }
        #if DEBUG
        if DemoMode.scene != nil { model.toast = "演示模式不上传头像"; return }
        #endif
        do {
            model.user = try await model.api.uploadAvatar(jpeg: jpeg)
            model.toast = "头像换好了"
        } catch {
            model.toast = error.localizedDescription
        }
    }

    private func removeAvatar() async {
        do { model.user = try await model.api.removeAvatar() } catch { model.toast = error.localizedDescription }
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
                    Text("不管常驻还是临时，只有你在回家路上时守护你的人才看得到你的位置。")
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

/// 「设定家庭地址」（6.5，原“我的家”）：最多两处，只存这台 iPhone 和手表，不上传
struct HomePlacesView: View {
    @EnvironmentObject var model: AppModel
    @State private var places: [HomePlace] = HomePlaceStore.load()
    @State private var editing: HomePlace?
    @State private var adding = false

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
                Text("家的位置只存在这台 iPhone 和你的手表上，不会上传，守护你的人也看不到。换手机后要重新设。到家时只会问你一句“安全到家了吗”，不会替你自动结束。")
            }
        }
        .navigationTitle("家庭地址")
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

/// 头像图片：从中间裁成正方形、缩到 512px，压成 JPEG（服务端上限 300KB）
enum AvatarImage {
    static let side: CGFloat = 512

    static func squareJPEG(_ image: UIImage) -> Data? {
        let w = image.size.width, h = image.size.height
        guard w > 0, h > 0 else { return nil }
        let s = min(w, h)
        let scale = min(1, side / s)
        let out = CGSize(width: (s * scale).rounded(), height: (s * scale).rounded())
        let format = UIGraphicsImageRendererFormat.default()
        format.scale = 1
        let img = UIGraphicsImageRenderer(size: out, format: format).image { _ in
            // 按比例画整张图，让中间那块正方形落在画布上
            let drawSize = CGSize(width: w * scale, height: h * scale)
            image.draw(in: CGRect(x: (out.width - drawSize.width) / 2, y: (out.height - drawSize.height) / 2, width: drawSize.width, height: drawSize.height))
        }
        for q in [0.82, 0.7, 0.55, 0.4] {
            if let d = img.jpegData(compressionQuality: q), d.count <= 280 * 1024 { return d }
        }
        return nil
    }
}
