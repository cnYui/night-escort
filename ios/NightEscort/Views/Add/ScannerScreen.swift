import AVFoundation
import EscortKit
import PhotosUI
import SwiftUI
import UIKit
import Vision
import VisionKit

/**
 扫码页（8.3）：全屏取景，系统 VisionKit 识别；底部手电筒、从相册选、输入邀请码。
 识别到本 App 的码轻震一下跳确认页；其他二维码只提示“这不是夜归护航的邀请码”，不跳转、不打开链接。
 */
struct ScannerScreen: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onFound: (InviteRef) -> Void

    @State private var hint: String?
    @State private var torch = false
    @State private var photo: PhotosPickerItem?
    @State private var showCode = false
    @State private var cameraDenied = AVCaptureDevice.authorizationStatus(for: .video) == .denied

    var body: some View {
        ZStack {
            if cameraDenied || !DataScannerViewController.isSupported {
                VStack(spacing: 14) {
                    Text("需要相机权限才能扫码").font(.headline)
                    Button("去设置里打开") {
                        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                    }
                    Button("改用邀请码") { showCode = true }
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
                    Button { toggleTorch() } label: { VStack { Image(systemName: torch ? "flashlight.on.fill" : "flashlight.off.fill").font(.title2); Text("手电筒").font(.caption) } }
                    PhotosPicker(selection: $photo, matching: .images) { VStack { Image(systemName: "photo").font(.title2); Text("相册").font(.caption) } }
                    Button { showCode = true } label: { VStack { Image(systemName: "number").font(.title2); Text("邀请码").font(.caption) } }
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
        .sheet(isPresented: $showCode) {
            EnterCodeView { code in
                showCode = false
                onFound(.code(code))
            }
            .presentationDetents([.medium])
        }
    }

    private func handle(_ payload: String) {
        if let ref = InviteLink.parse(payload, allowedHosts: AppConfig.inviteHosts) {
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onFound(ref)
        } else {
            hint = "这不是夜归护航的邀请码"
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
 确认页（3.1 第 4 步）：“小林邀请你长期守护她。她护航时你会收到通知并看到她的位置，护航结束就看不到了。”
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
        NavigationStack {
            Group {
                if let p = preview {
                    if let problem = p.problem {
                        ContentUnavailableView(problem, systemImage: "exclamationmark.circle")
                    } else {
                        form(p)
                    }
                } else if let error {
                    ContentUnavailableView(error, systemImage: "wifi.exclamationmark")
                } else {
                    ProgressView()
                }
            }
            .navigationTitle("守护邀请")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("取消") { dismiss() } } }
        }
        .task {
            do { preview = try await model.api.previewInvite(ref) } catch { self.error = error.localizedDescription }
        }
    }

    private func form(_ p: InvitePreview) -> some View {
        Form {
            Section {
                VStack(alignment: .leading, spacing: 10) {
                    AvatarView(name: p.inviter?.displayName ?? "", url: p.inviter?.avatarUrl, size: 64,
                               tint: p.kind == .temporary ? Theme.temporary : Theme.accent)
                    Text(p.headline ?? "").font(.title3.bold())
                    Text(p.explain ?? "").foregroundStyle(.secondary)
                }
                .padding(.vertical, 6)
            }
            Section("她是你的什么人") {
                Picker("关系", selection: $relation) {
                    ForEach(Self.relations, id: \.self) { Text($0).tag($0) }
                }
            }
            if p.offerReverse == true {
                Section {
                    Toggle("也让\(p.inviter?.displayName ?? "她")守护我", isOn: $alsoGuardMe)
                } footer: {
                    Text("打开后，你护航时她也会被默认选中。")
                }
            }
            Section {
                AsyncButton {
                    _ = try await model.api.acceptInvite(ref, relation: relation, alsoGuardMe: alsoGuardMe)
                    await model.refreshAll()
                    dismiss()
                } label: { Text("接受").frame(maxWidth: .infinity) }
                .buttonStyle(PrimaryButtonStyle(color: p.kind == .temporary ? Theme.temporary : Theme.accent))
                .listRowInsets(EdgeInsets())
            }
        }
    }
}
