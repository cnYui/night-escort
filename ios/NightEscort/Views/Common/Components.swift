import EscortKit
import SwiftUI

enum Theme {
    /// 到家没：主色用品牌深薰衣草紫（和图标、手表同一套）；临时用琥珀色；联系不上用红色
    static let accent = Color(red: 0x6B / 255, green: 0x47 / 255, blue: 0xBF / 255)
    static let temporary = Color(red: 0.96, green: 0.62, blue: 0.11)
    static let danger = Color(red: 0.92, green: 0.23, blue: 0.23)
    static let muted = Color.secondary
}

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 44
    var tint: Color = Theme.accent

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
            Circle().fill(tint.opacity(0.15))
            Text(String(name.prefix(1))).font(.system(size: size * 0.42, weight: .semibold)).foregroundStyle(tint)
        }
    }
}

struct ToastView: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.subheadline)
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
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background((tier == .standing ? Theme.accent : Theme.temporary).opacity(0.15), in: Capsule())
            .foregroundStyle(tier == .standing ? Theme.accent : Theme.temporary)
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    var color: Color = Theme.accent
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 14))
            .foregroundStyle(.white)
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
