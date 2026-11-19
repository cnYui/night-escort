import EscortKit
import SwiftUI

/// 手机上的颜色：夜色紫金。深紫底、主要页面两团光晕、主按钮蜜桃金、强调色薰衣草，整个 App 固定深色。
/// 色值见 Shared/Palette.swift；组件本身还是系统的
enum Theme {
    /// 强调色：链接、图标、进度条
    static let accent = Palette.accent
    static let onAccent = Palette.onAccent
    /// 今晚临时守护的人
    static let temporary = Palette.temporary
    static let onTemporary = Palette.onTemporary
    /// 求救和联系不上一直用系统红
    static let danger = Color.red
    static let muted = Color.secondary

    /// 首页气泡上「选中」的那一圈和小对勾
    static let ring = Brand.gold
    static let onRing = Brand.deepPurple
    /// 首页那句说明里怎么称呼这一圈
    static let ringWord = "金圈"

    /// 别人的字母头像
    static let monogram = Brand.lavender
    static let onMonogram = Brand.deepPurple
    /// 首页中间自己的头像
    static let me = Brand.gold
    static let onMe = Brand.deepPurple

    /// 普通页面的底
    static let page = Brand.base
    /// 列表、表单页面的底
    static let grouped = Brand.base
    /// 卡片、列表行的底
    static let card = Color(hex: 0x221B31)
    /// 首页搜索栏的底
    static let fill = Color.white.opacity(0.10)
    /// 登录页输入框的底
    static let field = Color.white.opacity(0.10)
    /// 列表行的底（配 `.listRowBackground`）
    static let rowBackground = card
    /// 整个 App 固定深色
    static let colorScheme = ColorScheme.dark
}

/// 页面的底：深紫，主要页面再加两团光晕
struct Backdrop: View {
    var grouped = false
    var glow = true

    var body: some View {
        ZStack {
            grouped ? Theme.grouped : Theme.page
            if glow { BrandGlow(strength: 0.7) }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 列表、表单换成深紫底。行的底色另外用 `.listRowBackground(Theme.rowBackground)`
    func themedList(glow: Bool = false) -> some View {
        self.scrollContentBackground(.hidden).background(Backdrop(grouped: true, glow: glow))
    }
}

struct AvatarView: View {
    let name: String
    var url: String? = nil
    var size: CGFloat = 44
    /// 字母头像的底色和字色：默认是别人的头像那一套，自己和求救中的人另外传
    var tint: Color = Theme.monogram
    var ink: Color = Theme.onMonogram

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
            Text(String(name.prefix(1))).font(.pf(size: size * 0.42, weight: .medium)).foregroundStyle(ink)
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
