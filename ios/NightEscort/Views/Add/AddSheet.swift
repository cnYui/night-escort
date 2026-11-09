import CoreImage.CIFilterBuiltins
import EscortKit
import SwiftUI

/**
 首页「+」（3.1、3.3、8.2）：先问“这是谁？”——长期守护我的人 / 今晚临时一起的人；
 临时的先过权限卡；然后是 二维码 / 邀请码 / 链接 三个标签页。另有“扫一扫”和“输入邀请码”。
 */
struct AddSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var template = TemporaryTemplate.default
    @State private var showScanner = false
    @State private var showCode = false

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
                    Button { showCode = true } label: { Label("输入邀请码", systemImage: "number") }
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
            .sheet(isPresented: $showCode) {
                EnterCodeView { code in
                    showCode = false
                    dismiss()
                    model.pendingInvite = .code(code)
                }
                .presentationDetents([.medium])
            }
        }
    }
}

/// 出示邀请：二维码（默认）/ 邀请码 / 链接；倒计时和刷新；被扫后变成“正在确认…”，接受后“已加入”并自动关闭
struct InviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let kind: InviteKind
    let template: TemporaryTemplate?

    enum Tab: String, CaseIterable { case qr = "二维码", code = "邀请码", link = "链接" }
    @State private var tab: Tab = .qr
    @State private var invite: Invite?
    @State private var status: Invite?
    @State private var savedBrightness: CGFloat?

    var body: some View {
        VStack(spacing: 18) {
            banner
            Picker("", selection: $tab) { ForEach(Tab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                .pickerStyle(.segmented)
                .padding(.horizontal)
            Spacer(minLength: 0)
            if let inv = invite {
                switch tab {
                case .qr:
                    QRCodeImage(text: inv.url).frame(width: 240, height: 240)
                        .overlay(AvatarView(name: model.user?.displayName ?? "我", size: 48).background(Circle().fill(.white).padding(-4)))
                case .code:
                    Text(inv.code).font(.pf(size: 48, weight: .semibold).monospacedDigit()).kerning(8).textSelection(.enabled)
                case .link:
                    VStack(spacing: 12) {
                        Text(inv.url).font(.pf(.footnote)).textSelection(.enabled).multilineTextAlignment(.center).padding(.horizontal)
                        ShareLink(item: URL(string: inv.url)!, message: Text("\(model.user?.displayName ?? "我")邀请你\(kind == .standing ? "长期守护" : "今晚临时守护")她，邀请码 \(inv.code)")) {
                            Label("发给对方", systemImage: "square.and.arrow.up")
                        }
                    }
                }
                stateLine(inv)
            } else {
                ProgressView()
            }
            Spacer(minLength: 0)
            if invite != nil {
                AsyncButton {
                    if let id = invite?.id { invite = try await model.api.refreshInvite(id: id); status = nil }
                } label: { Label("刷新（旧码作废）", systemImage: "arrow.clockwise") }
            }
        }
        .padding(.vertical)
        .navigationTitle("邀请")
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
            default: Text("\(Display.countdown(to: inv.expiresAt, now: ctx.date)) 后过期").foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .font(.pf(.subheadline))
    }

    private func create() async {
        guard invite == nil else { return }
        #if DEBUG
        if DemoMode.scene != nil { invite = DemoData.invite(kind: kind.rawValue); return }
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

/// 输入 6 位邀请码；有“粘贴”按钮（系统粘贴按钮不会弹剪贴板权限提示）
struct EnterCodeView: View {
    let onDone: (String) -> Void
    @State private var code = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("有人邀请你？").font(.pf(.title3, weight: .semibold))
            TextField("6 位邀请码", text: $code)
                .keyboardType(.numberPad)
                .font(.pf(size: 32, weight: .semibold).monospacedDigit())
                .multilineTextAlignment(.center)
                .onChange(of: code) { _, v in code = String(v.filter(\.isNumber).prefix(6)) }
            PasteButton(payloadType: String.self) { strings in
                if let c = strings.compactMap({ InviteLink.findCode(in: $0) }).first { code = c }
            }
            Button { onDone(code) } label: { Text("下一步").font(.pf(.headline)).frame(maxWidth: .infinity) }
                .glassProminentButton()
                .controlSize(.large)
                .disabled(code.count != 6)
        }
        .padding(24)
    }
}
