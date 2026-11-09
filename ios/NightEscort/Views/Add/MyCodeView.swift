import CoreImage.CIFilterBuiltins
import EscortKit
import SwiftUI

/**
 「我的」›「我的二维码」（2026-11-09 用户定）：加人不放在首页「+」里，而是在这里出示自己的码、把链接发出去。
 朋友用「+」扫这个码，或者点微信里的链接打开 App，都会弹出我的名片，在名片上选长期还是今晚临时，加了就互相守护。
 一个码只能用一次：被用掉后自动换一个新的，旧链接作废。
 */
struct MyCodeView: View {
    @EnvironmentObject var model: AppModel

    @State private var invite: Invite?
    @State private var status: Invite?
    @State private var savedBrightness: CGFloat?

    private var myName: String { model.user?.displayName ?? "我" }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                card
                if let inv = invite { actions(inv) }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 16)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("我的二维码")
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

    private var card: some View {
        VStack(spacing: 14) {
            HStack(spacing: 12) {
                AvatarView(name: myName, url: model.user?.avatarUrl, size: 48)
                VStack(alignment: .leading, spacing: 2) {
                    Text(myName).font(.pf(.headline))
                    Text("加我为好友，回家时互相守护").font(.pf(.footnote)).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if let inv = invite {
                QRCodeImage(text: inv.url)
                    .frame(width: 220, height: 220)
                    .padding(.vertical, 4)
                Text("让朋友打开「安全回家」，点首页右上角 + 扫一扫").font(.pf(.footnote)).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                stateLine(inv)
            } else {
                ProgressView().frame(width: 220, height: 220)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 26, style: .continuous))
    }

    private func actions(_ inv: Invite) -> some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                // 复制以后到微信里粘贴发给朋友；朋友复制了再打开 App 也能认出来
                Button { copy(inv) } label: {
                    Label("复制链接", systemImage: "link").font(.pf(.subheadline, weight: .semibold)).frame(maxWidth: .infinity)
                }
                .glassProminentButton()
                ShareLink(item: shareText(inv)) {
                    Label("其他方式", systemImage: "square.and.arrow.up").font(.pf(.subheadline, weight: .medium)).frame(maxWidth: .infinity)
                }
                .glassButton()
            }
            .controlSize(.large)
            Text("朋友点开链接会直接打开「安全回家」，弹出你的名片。一个码只能加一个人，用过会自动换新的。")
                .font(.pf(.caption))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.top, 4)
            AsyncButton {
                if let id = invite?.id { invite = try await model.api.refreshInvite(id: id); status = nil }
            } label: { Label("换一个码（旧链接作废）", systemImage: "arrow.clockwise").font(.pf(.footnote)) }
            .buttonStyle(.borderless)
        }
    }

    private func shareText(_ inv: Invite) -> String {
        InviteLink.shareText(inviterName: myName, url: inv.url)
    }

    private func copy(_ inv: Invite) {
        model.copyOwnInvite(shareText(inv), token: inv.token)
        model.toast = "已复制，到微信里粘贴发给朋友"
    }

    @ViewBuilder
    private func stateLine(_ inv: Invite) -> some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            switch status?.state ?? "" {
            case "scanned": Text("\(status?.scannedByName ?? "对方")正在看你的名片…").foregroundStyle(Theme.accent)
            case "consumed": Text("\(status?.acceptedByName ?? "对方")已加你为好友").foregroundStyle(.green)
            case "expired", "revoked": Text("这个码失效了，点下面换一个").foregroundStyle(.secondary)
            default: Text(Self.remaining(until: inv.expiresAt, now: ctx.date)).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.pf(.subheadline))
    }

    /// “还剩 23 小时 40 分”：比 23:40:51 好懂，不会被看成一个时刻
    static func remaining(until due: Date, now: Date) -> String {
        let s = max(0, Int(due.timeIntervalSince(now)))
        let h = s / 3600, m = (s % 3600) / 60
        if h > 0 { return m > 0 ? "还剩 \(h) 小时 \(m) 分有效" : "还剩 \(h) 小时有效" }
        return m > 0 ? "还剩 \(m) 分钟有效" : "马上过期，点下面换一个"
    }

    private func create() async {
        guard invite == nil else { return }
        #if DEBUG
        if DemoMode.scene != nil { invite = DemoData.invite; return }
        #endif
        do { invite = try await model.api.createInvite(kind: .standing) } catch { model.toast = error.localizedDescription }
    }

    /// 被扫后变成“正在看你的名片…”；加上以后刷新好友，过一会儿换成新码，页面不关
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
                try? await Task.sleep(for: .seconds(2.5))
                guard !Task.isCancelled else { return }
                if let fresh = try? await model.api.createInvite(kind: .standing) {
                    invite = fresh
                    status = nil
                }
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
        f.correctionLevel = "M" // 中间不放头像，码更疏、夜里更好扫
        guard let out = f.outputImage?.transformed(by: CGAffineTransform(scaleX: 10, y: 10)),
              let cg = CIContext().createCGImage(out, from: out.extent) else { return nil }
        return UIImage(cgImage: cg)
    }
}
