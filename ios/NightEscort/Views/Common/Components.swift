import EscortKit
import SwiftUI

/// 手机上的颜色。跟着当前配色走（见 Shared/Palette.swift），组件本身不变
enum Theme {
    private static let palette = Palette.current

    /// 强调色：链接、图标、进度条
    static let accent = palette.accent
    static let onAccent = palette.onAccent
    /// 今晚临时守护的人
    static let temporary = palette.temporary
    static let onTemporary = palette.onTemporary
    /// 求救和联系不上一直用系统红
    static let danger = Color.red
    static let muted = Color.secondary

    /// 首页气泡上「选中」的那一圈和小对勾
    static let ring: Color = palette == .c ? Brand.gold : palette.accent
    static let onRing: Color = palette == .c ? Brand.deepPurple : palette.onAccent
    /// 首页那句说明里怎么称呼这一圈
    static let ringWord: String = {
        switch palette {
        case .system: return "蓝圈"
        case .a, .b: return "紫圈"
        case .c: return "金圈"
        }
    }()

    /// 别人的字母头像：默认是通讯录那种灰，B、C 换成薰衣草
    static let monogram: Color = {
        switch palette {
        case .system, .a: return Color(red: 0.56, green: 0.58, blue: 0.62)
        case .b, .c: return Brand.lavender
        }
    }()
    static let onMonogram: Color = {
        switch palette {
        case .system, .a: return .white
        case .b, .c: return Brand.deepPurple
        }
    }()
    /// 首页中间自己的头像
    static let me: Color = {
        switch palette {
        case .system, .a: return palette.accent
        case .b, .c: return Brand.gold
        }
    }()
    static let onMe: Color = {
        switch palette {
        case .system, .a: return palette.onAccent
        case .b, .c: return Brand.deepPurple
        }
    }()

    /// 普通页面的底
    static let page: Color = {
        switch palette {
        case .system, .a: return Color(.systemBackground)
        case .b: return Color(hex: 0xF6F2FC)
        case .c: return Brand.base
        }
    }()
    /// 列表、表单页面的底
    static let grouped: Color = {
        switch palette {
        case .system, .a: return Color(.systemGroupedBackground)
        case .b: return Color(hex: 0xF1ECFA)
        case .c: return Brand.base
        }
    }()
    /// 卡片、列表行的底
    static let card: Color = {
        switch palette {
        case .system, .a: return Color(.secondarySystemGroupedBackground)
        case .b: return .white
        case .c: return Color(hex: 0x221B31)
        }
    }()
    /// 首页搜索栏的底
    static let fill: Color = {
        switch palette {
        case .system, .a: return Color(.tertiarySystemFill)
        case .b: return Brand.lavender.opacity(0.28)
        case .c: return Color.white.opacity(0.10)
        }
    }()
    /// 登录页输入框的底
    static let field: Color = {
        switch palette {
        case .system, .a: return Color(.secondarySystemBackground)
        case .b: return Brand.lavender.opacity(0.28)
        case .c: return Color.white.opacity(0.10)
        }
    }()

    /// B、C 换了底色；系统默认和 A 用系统自己的底，列表行不单独上色（保留点按高亮）
    static let customSurfaces: Bool = palette == .b || palette == .c
    static let rowBackground: Color? = customSurfaces ? card : nil
    /// 只有 C 有光晕
    static let glow: Bool = palette == .c
    /// B 固定浅色，C 固定深色，其它跟随系统
    static let colorScheme: ColorScheme? = {
        switch palette {
        case .system, .a: return nil
        case .b: return .light
        case .c: return .dark
        }
    }()
}

/// 页面的底：纯色；C 配色的主要页面再加两团光晕
struct Backdrop: View {
    var grouped = false
    var glow = true

    var body: some View {
        ZStack {
            grouped ? Theme.grouped : Theme.page
            if glow && Theme.glow { BrandGlow(strength: 0.7) }
        }
        .ignoresSafeArea()
    }
}

extension View {
    /// 列表、表单换成当前配色的底（系统默认和 A 配色不动）。行的底色另外用 `.listRowBackground(Theme.rowBackground)`
    @ViewBuilder
    func themedList(glow: Bool = false) -> some View {
        if Theme.customSurfaces {
            self.scrollContentBackground(.hidden).background(Backdrop(grouped: true, glow: glow))
        } else {
            self
        }
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
