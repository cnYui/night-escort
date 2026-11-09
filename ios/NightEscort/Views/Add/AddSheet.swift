import CoreImage.CIFilterBuiltins
import EscortKit
import SwiftUI

/**
 首页「+」（3.1、3.3、8.2）：先问“这是谁？”——长期守护我的人 / 今晚临时一起的人；
 临时的先过权限卡；然后出示二维码，下面一键发到微信。另有“扫一扫”和“粘贴邀请链接”。
 2026-11-09 起只有二维码和链接，没有 6 位邀请码。
 */
struct AddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var template = TemporaryTemplate.default
    @State private var showScanner = false

    var body: some View {
        NavigationStack {
            List {
                Section("这是谁？") {
                    NavigationLink {
                        InviteView(kind: .standing, template: nil)
                    } label: {
                        Label { VStack(alignment: .leading) { Text("长期守护我的人"); Text("爸妈、伴侣、长期室友").font(.pf(.caption)).foregroundStyle(.secondary) } } icon: {
                            Image(systemName: "house.fill").foregroundStyle(Theme.accent)
                        }
                    }
                    NavigationLink {
                        TemporaryPermissionForm(name: "她", template: $template)
                            .safeAreaInset(edge: .bottom) {
                                NavigationLink {
                                    InviteView(kind: .temporary, template: template)
                                } label: { Text("生成二维码").font(.pf(.headline)).frame(maxWidth: .infinity) }
                                .glassProminentButton(tint: Theme.temporary)
                                .controlSize(.large)
                                .padding()
                            }
                    } label: {
                        Label { VStack(alignment: .leading) { Text("今晚临时一起的人"); Text("聚会上刚认识、今晚顺路的人").font(.pf(.caption)).foregroundStyle(.secondary) } } icon: {
                            Image(systemName: "hourglass").foregroundStyle(Theme.temporary)
                        }
                    }
                }
                Section("别人给了我邀请") {
                    Button { showScanner = true } label: { Label("扫一扫", systemImage: "qrcode.viewfinder") }
                    // 系统粘贴按钮：用户点了才读，不弹“允许粘贴”提示
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in
                            if model.handlePastedText(strings) { dismiss() }
                        }
                    }
                }
            }
            .navigationTitle("添加")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
            .fullScreenCover(isPresented: $showScanner) {
                ScannerScreen { ref in
                    showScanner = false
                    dismiss()
                    model.pendingInvite = ref
                }
                .environmentObject(model)
            }
        }
    }
}

/// 出示邀请：二维码 + 一键发到微信；倒计时和刷新；被扫后变成“正在确认…”，接受后“已加入”并自动关闭
struct InviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    let kind: InviteKind
    let template: TemporaryTemplate?

    @State private var invite: Invite?
    @State private var status: Invite?
    @State private var savedBrightness: CGFloat?

    var body: some View {
        VStack(spacing: 16) {
            banner
            Spacer(minLength: 0)
            if let inv = invite {
                QRCodeImage(text: inv.url).frame(width: 220, height: 220)
                    .overlay(AvatarView(name: model.user?.displayName ?? "我", size: 44).background(Circle().fill(.white).padding(-4)))
                Text("当面扫码，或者把链接发给对方").font(.pf(.footnote)).foregroundStyle(.secondary)
                stateLine(inv)
                Spacer(minLength: 0)
                VStack(spacing: 10) {
                    Button { sendToWeChat(inv) } label: {
                        Label("发给微信好友", systemImage: "paperplane.fill").font(.pf(.headline)).frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                    .controlSize(.large)
                    HStack(spacing: 10) {
                        Button { copy(inv) } label: {
                            Label("复制链接", systemImage: "link").font(.pf(.subheadline, weight: .medium)).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                        ShareLink(item: shareText(inv)) {
                            Label("其他方式", systemImage: "square.and.arrow.up").font(.pf(.subheadline, weight: .medium)).frame(maxWidth: .infinity)
                        }
                        .glassButton()
                    }
                    .controlSize(.large)
                    AsyncButton {
                        if let id = invite?.id { invite = try await model.api.refreshInvite(id: id); status = nil }
                    } label: { Label("刷新（旧链接作废）", systemImage: "arrow.clockwise").font(.pf(.footnote)) }
                    .buttonStyle(.borderless)
                    .padding(.top, 4)
                }
                .padding(.horizontal, 20)
            } else {
                ProgressView()
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical)
        .navigationTitle("邀请担保人")
        .navigationBarTitleDisplayMode(.inline)
        .task { await create() }
        .task(id: invite?.id) { await poll() }
        .onAppear {
            // 夜里酒吧灯光暗也好扫：亮度调到最高，离开时恢复
            savedBrightness = UIScreen.main.brightness
            UIScreen.main.brightness = 1
        }
        .onDisappear { if let b = savedBrightness { UIScreen.main.brightness = b } }
    }

    private func shareText(_ inv: Invite) -> String {
        InviteLink.shareText(inviterName: model.user?.displayName ?? "我", kind: kind, url: inv.url)
    }

    private func copy(_ inv: Invite) {
        model.copyOwnInvite(shareText(inv), token: inv.token)
        model.toast = "已复制，发给对方即可"
    }

    /**
     一键发到微信：把“说明 + 链接”放进粘贴板，直接跳到微信，选好友粘贴发送。
     没装微信就只复制，提示用“其他方式”发。（接入微信 OpenSDK 后可以改成直接弹微信的好友选择，需要开放平台 AppID）
     */
    private func sendToWeChat(_ inv: Invite) {
        model.copyOwnInvite(shareText(inv), token: inv.token)
        if let wx = URL(string: "weixin://"), UIApplication.shared.canOpenURL(wx) {
            model.toast = "邀请已复制，到微信里粘贴给好友"
            openURL(wx)
        } else {
            model.toast = "没装微信，邀请已复制，可以用其他方式发给对方"
        }
    }

    private var banner: some View {
        let text = kind == .standing
            ? "长期守护 · 24 小时内有效"
            : "今晚临时 · \(template?.locationScope == .live ? "全程可见位置" : "仅报警时可见位置") · 30 分钟内有效"
        return Text(text)
            .font(.pf(.subheadline, weight: .semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .background((kind == .standing ? Theme.accent : Theme.temporary).opacity(0.15))
            .foregroundStyle(kind == .standing ? Theme.accent : Theme.temporary)
    }

    @ViewBuilder
    private func stateLine(_ inv: Invite) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { ctx in
            switch status?.state ?? "" {
            case "scanned": Text("\(status?.scannedByName ?? "对方")正在确认…").foregroundStyle(Theme.accent)
            case "consumed": Text("\(status?.acceptedByName ?? "对方")已加入").foregroundStyle(.green)
            case "expired": Text("已过期，点刷新重新生成").foregroundStyle(.secondary)
            case "revoked": Text("已作废，点刷新重新生成").foregroundStyle(.secondary)
            default: Text("\(Display.countdown(to: inv.expiresAt, now: ctx.date)) 后过期").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.pf(.subheadline))
    }

    private func create() async {
        guard invite == nil else { return }
        #if DEBUG
        if DemoMode.scene != nil { invite = DemoData.invite; return }
        #endif
        do { invite = try await model.api.createInvite(kind: kind, template: template) } catch { model.toast = error.localizedDescription }
    }

    private func poll() async {
        guard let id = invite?.id else { return }
        #if DEBUG
        if DemoMode.scene != nil { return }
        #endif
        while !Task.isCancelled {
            try? await Task.sleep(for: .seconds(2))
            guard let s = try? await model.api.inviteStatus(id: id) else { continue }
            status = s
            if s.state == "consumed" {
                await model.refreshAll()
                try? await Task.sleep(for: .seconds(1.5))
                dismiss()
                return
            }
        }
    }
}

struct QRCodeImage: View {
    let text: String
    var body: some View {
        if let img = Self.make(text) {
            Image(uiImage: img).interpolation(.none).resizable().scaledToFit()
        } else {
            Color.gray.opacity(0.2)
        }
    }

    static func make(_ text: String) -> UIImage? {
        let f = CIFilter.qrCodeGenerator()
        f.message = Data(text.utf8)
        f.correctionLevel = "H" // 中间放头像，用最高纠错
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
