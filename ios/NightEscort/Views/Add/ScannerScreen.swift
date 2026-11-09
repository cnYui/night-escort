import AVFoundation
import EscortKit
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/**
 扫码页（8.3）：首页「+」直接打开这里。全屏取景，系统 VisionKit 识别；底部手电筒、从相册选、我的二维码三个按钮居中。
 别人发来的链接不用在这里粘贴：点链接直接进 App，或者复制后回到 App 会自动认出来。
 识别到本 App 的码轻震一下弹对方的名片；其他二维码只提示“这不是「安全回家」的二维码”，不跳转、不打开链接。
 */
struct ScannerScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onFound: (InviteRef) -> Void

    @State private var hint: String?
    @State private var torch = false
    @State private var photo: PhotosPickerItem?
    @State private var showMyCode = false
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    /// 模拟器没有相机：演示时只画取景框
    private var demoViewfinder: Bool {
        #if DEBUG
        return DemoMode.scene != nil
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack {
            if cameraDenied {
                unavailable("需要相机权限才能扫码", settings: true)
            } else if !DataScannerViewController.isSupported && !demoViewfinder {
                unavailable("这台设备不能扫码", settings: false)
            } else {
                if !demoViewfinder { DataScannerRepresentable(onText: handle).ignoresSafeArea() }
                VStack(spacing: 18) {
                    RoundedRectangle(cornerRadius: 24).stroke(.white, lineWidth: 3).frame(width: 250, height: 250)
                    Text("扫朋友「我的二维码」，加为好友互相守护")
                        .font(.pf(.subheadline, weight: .medium))
                        .multilineTextAlignment(.center)
                }
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.system(size: 17, weight: .semibold)).frame(width: 22, height: 22) }
                        .glassButton()
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .accessibilityLabel("关闭")
                    Spacer()
                    Text("扫一扫").font(.pf(.headline))
                    Spacer()
                    Color.clear.frame(width: 44, height: 44)
                }
                .padding(.horizontal, 16)
                Spacer()
                if let hint {
                    Text(hint).font(.pf(.subheadline)).padding(.horizontal, 14).padding(.vertical, 8).background(.black.opacity(0.6), in: Capsule())
                }
                HStack(alignment: .top, spacing: 44) {
                    tool("手电筒", systemImage: torch ? "flashlight.on.fill" : "flashlight.off.fill") { toggleTorch() }
                    PhotosPicker(selection: $photo, matching: .images) { toolLabel("相册", systemImage: "photo") }
                    tool("我的二维码", systemImage: "qrcode") { showMyCode = true }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 24)
            }
            .foregroundStyle(.white)
        }
        .background(Color.black)
        .task {
            if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined {
                cameraDenied = !(await AVCaptureDevice.requestAccess(for: .video))
            }
        }
        .onChange(of: photo) { _, item in
            Task { await scanPhoto(item) }
        }
        // 两个人当面：对方也可以从这里直接亮出自己的码
        .sheet(isPresented: $showMyCode) {
            NavigationStack {
                MyCodeView()
                    .toolbar {
                        ToolbarItem(placement: .cancellationAction) {
                            Button { showMyCode = false } label: { Image(systemName: "xmark") }.accessibilityLabel("关闭")
                        }
                    }
            }
            .environmentObject(model)
        }
    }

    private func unavailable(_ title: String, settings: Bool) -> some View {
        VStack(spacing: 14) {
            Text(title).font(.pf(.headline))
            if settings {
                Button("去设置里打开") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
            }
            Text("也可以让朋友把链接发到微信，点开链接就能加").font(.pf(.footnote)).foregroundStyle(.white.opacity(0.7))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 32)
    }

    private func tool(_ title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { toolLabel(title, systemImage: systemImage) }
    }

    private func toolLabel(_ title: String, systemImage: String) -> some View {
        VStack(spacing: 6) {
            Image(systemName: systemImage).font(.system(size: 20, weight: .medium)).frame(width: 48, height: 48)
                .glassBackground(in: Circle())
            Text(title).font(.pf(.caption))
        }
    }

    private func handle(_ payload: String) {
        if let ref = InviteLink.parse(payload, allowedHosts: AppConfig.inviteHosts) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onFound(ref)
        } else {
            hint = "这不是「安全回家」的二维码"
        }
    }

    private func toggleTorch() {
        guard let d = AVCaptureDevice.default(for: .video), d.hasTorch else { return }
        try? d.lockForConfiguration()
        torch.toggle()
        d.torchMode = torch ? .on : .off
        d.unlockForConfiguration()
    }

    private func scanPhoto(_ item: PhotosPickerItem?) async {
        guard let data = try? await item?.loadTransferable(type: Data.self), let img = UIImage(data: data)?.cgImage else { return }
        let req = VNDetectBarcodesRequest()
        req.symbologies = [.qr]
        try? VNImageRequestHandler(cgImage: img).perform([req])
        if let s = req.results?.compactMap(\.payloadStringValue).first {
            handle(s)
        } else {
            hint = "图片里没有找到二维码"
        }
    }
}

private struct DataScannerRepresentable: UIViewControllerRepresentable {
    let onText: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let vc = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isHighlightingEnabled: true
        )
        vc.delegate = context.coordinator
        try? vc.startScanning()
        return vc
    }

    func updateUIViewController(_ vc: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onText: onText) }

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onText: (String) -> Void
        private var last: String?
        init(onText: @escaping (String) -> Void) { self.onText = onText }

        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                if case .barcode(let b) = item, let s = b.payloadStringValue, s != last {
                    last = s
                    onText(s)
                }
            }
        }
    }
}

/**
 别人的名片（2026-11-09 用户定：加好友，互相守护）：扫码、点邀请链接、或者复制了链接回到 App 时弹出。
 名片上选她是你的什么人，再选长期互相守护还是今晚临时一起；加了以后你们回家时都可以选对方守着。
 */
struct ConfirmInviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ref: InviteRef
    @State private var preview: InvitePreview?
    @State private var relation = "朋友"
    @State private var tier: InviteKind = .standing
    @State private var error: String?
    /// 身份选项可以自己新增、删除，存在这台手机上，下次加人还在
    @AppStorage("relationOptions") private var relationsRaw = RelationOptions.defaults.joined(separator: "\n")
    @State private var addingRelation = false
    @State private var newRelation = ""

    private var relations: [String] { relationsRaw.split(separator: "\n").map(String.init) }

    var body: some View {
        Group {
            if let p = preview {
                if let problem = p.problem {
                    ContentUnavailableView {
                        Label(problem, systemImage: "exclamationmark.circle")
                    } actions: {
                        Button { dismiss() } label: { Text("好").font(.pf(.headline)).frame(maxWidth: 200) }
                            .glassButton()
                            .controlSize(.large)
                    }
                } else {
                    content(p)
                }
            } else if let error {
                ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task {
            #if DEBUG
            if DemoMode.scene != nil { show(DemoData.invitePreview); return }
            #endif
            do {
                let p = try await model.api.previewInvite(ref)
                show(p)
            } catch { self.error = error.localizedDescription }
        }
    }

    private func show(_ p: InvitePreview) {
        preview = p
        // 当面扫的临时码默认选“今晚临时”，其余默认长期
        tier = p.kind ?? .standing
        // “朋友”被删掉了就选第一个
        if !relations.contains(relation) { relation = relations.first ?? "朋友" }
    }

    private func content(_ p: InvitePreview) -> some View {
        let name = p.inviter?.displayName ?? "她"
        return ScrollView {
            VStack(spacing: 12) {
                AvatarView(name: name, url: p.inviter?.avatarUrl, size: 76)
                    .padding(.top, 24)
                Text(name).font(.pf(.title2, weight: .semibold))
                Text("加\(name)为好友，你们回家时都可以选对方守着。被选中才会收到通知、看到位置，到家就停。")
                    .font(.pf(.subheadline))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 8)

                group {
                    HStack {
                        Text("对方是你的").font(.pf(.body))
                        Spacer()
                        relationMenu
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                }
                .padding(.top, 8)

                Text("怎么守护").font(.pf(.subheadline)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .padding(.top, 6)
                group {
                    tierRow(.standing, title: "长期互相守护", detail: "家人、室友、好朋友。以后每次回家都能选对方，被选中时全程看到位置。")
                    Divider().padding(.leading, 52).padding(.trailing, 16)
                    tierRow(.temporary, title: "今晚临时一起", detail: "聚会上刚认识、今晚顺路的人。只在联系不上时看到位置，这次回家结束或 24 小时后自动解除。")
                }
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 12)
        }
        // 两个按钮钉在底部，上面的说明可以滚动
        .safeAreaInset(edge: .bottom) {
            VStack(spacing: 10) {
                AsyncButton {
                    #if DEBUG
                    if DemoMode.scene != nil { dismiss(); return }
                    #endif
                    _ = try await model.api.acceptInvite(ref, relation: relation, tier: tier)
                    await model.refreshAll()
                    model.toast = tier == .standing ? "已和\(name)互相守护" : "今晚和\(name)临时互相守护"
                    dismiss()
                } label: { Text("加为好友").font(.pf(.headline)).frame(maxWidth: .infinity) }
                .glassProminentButton(tint: tier == .temporary ? Theme.temporary : Theme.accent)
                .controlSize(.large)

                Button { dismiss() } label: { Text("暂不").font(.pf(.body)).frame(maxWidth: .infinity) }
                    .glassButton()
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.top, 10)
            .padding(.bottom, 8)
            .background(Color(.systemGroupedBackground))
        }
        .background(Color(.systemGroupedBackground))
    }

    /// 下拉：选身份；最下面「新增身份」和「删除身份」（展开后点要删的那个）
    private var relationMenu: some View {
        Menu {
            Picker("对方是你的", selection: $relation) {
                ForEach(relations, id: \.self) { Text($0).tag($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button { newRelation = ""; addingRelation = true } label: { Label("新增身份", systemImage: "plus") }
            Menu {
                ForEach(relations, id: \.self) { r in
                    Button(r, role: .destructive) { removeRelation(r) }
                }
            } label: { Label("删除身份", systemImage: "trash") }
            .disabled(relations.count <= 1)
        } label: {
            HStack(spacing: 4) {
                Text(relation).font(.pf(.body))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 13, weight: .semibold))
            }
            .foregroundStyle(Theme.accent)
        }
        .alert("新增身份", isPresented: $addingRelation) {
            TextField("比如 闺蜜、学姐", text: $newRelation)
            Button("添加") { addRelation() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("最多 10 个字，只存在这台手机上")
        }
    }

    private func addRelation() {
        let name = String(newRelation.trimmingCharacters(in: .whitespacesAndNewlines).prefix(10))
        guard !name.isEmpty else { return }
        if !relations.contains(name) { relationsRaw = (relations + [name]).joined(separator: "\n") }
        relation = name
    }

    private func removeRelation(_ r: String) {
        let rest = relations.filter { $0 != r }
        guard !rest.isEmpty else { return }
        relationsRaw = rest.joined(separator: "\n")
        if relation == r { relation = rest.contains("朋友") ? "朋友" : rest[0] }
    }

    private func group<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 0, content: c)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
    }

    private func tierRow(_ t: InviteKind, title: String, detail: String) -> some View {
        Button {
            UISelectionFeedbackGenerator().selectionChanged()
            tier = t
        } label: {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: tier == t ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(tier == t ? (t == .temporary ? Theme.temporary : Theme.accent) : Color(.tertiaryLabel))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title).font(.pf(.body, weight: .medium)).foregroundStyle(.primary)
                    Text(detail).font(.pf(.caption)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(tier == t ? .isSelected : [])
    }
}

/// 名片上「对方是你的」默认几个身份；用户可以自己加、删
enum RelationOptions {
    static let defaults = ["家人", "女儿", "妈妈", "爸爸", "伴侣", "室友", "朋友", "同事"]
}
