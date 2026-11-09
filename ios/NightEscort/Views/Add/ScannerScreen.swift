import AVFoundation
import EscortKit
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/**
 扫码页（8.3）：全屏取景，系统 VisionKit 识别；底部手电筒、从相册选、粘贴邀请链接。
 识别到本 App 的码轻震一下跳确认页；其他二维码只提示“这不是「安全回家」的邀请”，不跳转、不打开链接。
 */
struct ScannerScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onFound: (InviteRef) -> Void

    @State private var hint: String?
    @State private var torch = false
    @State private var photo: PhotosPickerItem?
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        ZStack {
            if cameraDenied || !DataScannerViewController.isSupported {
                VStack(spacing: 14) {
                    Text("需要相机权限才能扫码").font(.pf(.headline))
                    Button("去设置里打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in paste(strings) }
                    }
                }
                .foregroundStyle(.white)
            } else {
                DataScannerRepresentable(onText: handle).ignoresSafeArea()
                RoundedRectangle(cornerRadius: 24).stroke(.white, lineWidth: 3).frame(width: 250, height: 250)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "xmark").font(.title2).padding() }
                    Spacer()
                }
                Spacer()
                if let hint {
                    Text(hint).padding(10).background(.black.opacity(0.6), in: Capsule())
                }
                HStack(spacing: 40) {
                    Button { toggleTorch() } label: { VStack { Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill").font(.pf(.title2)); Text("手电筒").font(.pf(.caption)) } }
                    PhotosPicker(selection: $photo, matching: .images) { VStack { Image(systemName: "photo").font(.pf(.title2)); Text("相册").font(.pf(.caption)) } }
                    PasteButton(payloadType: String.self) { strings in
                        Task { @MainActor in paste(strings) }
                    }
                    .labelStyle(.iconOnly)
                    .buttonBorderShape(.circle)
                }
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
    }

    private func paste(_ strings: [String]) {
        if let ref = strings.lazy.compactMap({ InviteLink.find(in: $0, allowedHosts: AppConfig.inviteHosts) }).first {
            onFound(ref)
        } else {
            hint = "粘贴板里没有「安全回家」的邀请链接"
        }
    }

    private func handle(_ payload: String) {
        if let ref = InviteLink.parse(payload, allowedHosts: AppConfig.inviteHosts) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onFound(ref)
        } else {
            hint = "这不是「安全回家」的邀请"
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
 “成为担保人”弹窗（3.1 第 4 步）：点邀请链接、扫码、或者复制了链接回到 App 时弹出。
 “小林邀请你长期守护她。她护航时你会收到通知并看到她的位置，护航结束就看不到了。”
 选她是你的什么人；长期邀请多一个默认关闭的“也让她守护我”。临时邀请不显示这个开关。
 */
struct ConfirmInviteView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let ref: InviteRef
    @State private var preview: InvitePreview?
    @State private var relation = "朋友"
    @State private var alsoGuardMe = false
    @State private var error: String?

    static let relations = ["家人", "女儿", "妈妈", "爸爸", "伴侣", "室友", "朋友", "同事"]

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
            if DemoMode.scene != nil { preview = DemoData.invitePreview; return }
            #endif
            do { preview = try await model.api.previewInvite(ref) } catch { self.error = error.localizedDescription }
        }
    }

    private func content(_ p: InvitePreview) -> some View {
        let tint = p.kind == .temporary ? Theme.temporary : Theme.accent
        let name = p.inviter?.displayName ?? "她"
        return ScrollView {
            VStack(spacing: 14) {
                Text("成为担保人").font(.pf(.subheadline, weight: .semibold)).foregroundStyle(.secondary)
                    .padding(.top, 20)
                AvatarView(name: name, url: p.inviter?.avatarUrl, size: 72)
                Text(p.headline ?? "").font(.pf(.title3, weight: .semibold)).multilineTextAlignment(.center)
                Text(p.explain ?? "").font(.pf(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)

                VStack(spacing: 0) {
                    HStack {
                        Text("她是你的").font(.pf(.body))
                        Spacer()
                        Picker("她是你的", selection: $relation) {
                            ForEach(Self.relations, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 6)
                    if p.offerReverse == true {
                        Divider().padding(.leading, 16)
                        Toggle(isOn: $alsoGuardMe) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text("也让\(name)守护我").font(.pf(.body))
                                Text("你护航时她也会被默认选中").font(.pf(.caption)).foregroundStyle(.secondary)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 10)
                    }
                }
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
                .padding(.top, 6)

                AsyncButton {
                    #if DEBUG
                    if DemoMode.scene != nil { dismiss(); return }
                    #endif
                    _ = try await model.api.acceptInvite(ref, relation: relation, alsoGuardMe: alsoGuardMe)
                    await model.refreshAll()
                    model.toast = "你已成为\(name)的担保人"
                    dismiss()
                } label: { Text("成为担保人").font(.pf(.headline)).frame(maxWidth: .infinity) }
                .glassProminentButton(tint: tint)
                .controlSize(.large)
                .padding(.top, 8)

                Button { dismiss() } label: { Text("暂不").font(.pf(.body)).frame(maxWidth: .infinity) }
                    .glassButton()
                    .controlSize(.large)
            }
            .padding(.horizontal, 20)
            .padding(.bottom, 20)
        }
        .background(Color(.systemGroupedBackground))
    }
}
