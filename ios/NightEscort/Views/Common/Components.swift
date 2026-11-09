import EscortKit
import SwiftUI

enum Theme {
    /// 苹果默认配色：系统蓝做强调，临时担保人用系统橙，求救和联系不上用系统红
    static let accent = Color.blue
    static let temporary = Color.orange
    static let danger = Color.red
    static let muted = Color.secondary
    /// 通讯录默认的灰色字母头像
    static let monogram = Color(red: 0.56, green: 0.58, blue: 0.62)
}

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 44
    /// 字母头像的底色：默认通讯录那种灰，自己用系统蓝
    var tint: Color = Theme.monogram

    var body: some View {
        ZStack {
            if let url, let u = URL(string: url) {
                AsyncImage(url: u) { img in img.resizable().scaledToFill() } placeholder: { placeholder }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
    }

    private var placeholder: some View {
        ZStack {
            Circle().fill(LinearGradient(colors: [tint.opacity(0.72), tint], startPoint: .top, endPoint: .bottom))
            Text(String(name.prefix(1))).font(.pf(size: size * 0.42, weight: .medium)).foregroundStyle(.white)
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.pf(.subheadline))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(.ultraThinMaterial, in: Capsule())
            .padding(.top, 8)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}

struct TierBadge: View {
    let tier: Tier
    var text: String? = nil
    var body: some View {
        Text(text ?? Display.tierLabel(tier))
            .font(.pf(.caption2, weight: .semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tier == .standing ? Theme.accent : Theme.temporary).opacity(0.15), in: Capsule())
            .foregroundStyle(tier == .standing ? Theme.accent : Theme.temporary)
    }
}

/// 一次性异步操作的按钮：执行中显示转圈，出错弹提示
struct AsyncButton<Label: View>: View {
    let action: () async throws -> Void
    @ViewBuilder let label: () -> Label
    @State private var running = false
    @EnvironmentObject var model: AppModel

    var body: some View {
        Button {
            guard !running else { return }
            running = true
            Task {
                do { try await action() } catch { model.toast = error.localizedDescription }
                running = false
            }
        } label: {
            ZStack {
                label().opacity(running ? 0 : 1)
                if running { ProgressView() }
            }
        }
        .disabled(running)
    }
}
