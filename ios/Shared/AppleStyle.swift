import SwiftUI

// 手机、手表、小组件共用的视觉约定（2026-11-09 定）：
// 苹果默认的白底 + 系统蓝；按钮一律用系统的液态玻璃（Liquid Glass）样式；字体一律苹方。

// MARK: - 苹方

extension Font {
    /// 苹方的 PostScript 名。苹方最粗只有 Semibold，更粗的字重都落到 Semibold。
    static func pingFangName(_ weight: Font.Weight) -> String {
        switch weight {
        case .ultraLight: return "PingFangSC-Ultralight"
        case .thin: return "PingFangSC-Thin"
        case .light: return "PingFangSC-Light"
        case .regular: return "PingFangSC-Regular"
        case .medium: return "PingFangSC-Medium"
        default: return "PingFangSC-Semibold"
        }
    }

    /// 苹方，跟随系统字号（动态字体）。headline 默认 Semibold，其它默认 Regular。
    static func pf(_ style: Font.TextStyle, weight: Font.Weight? = nil) -> Font {
        let w = weight ?? (style == .headline ? .semibold : .regular)
        return .custom(pingFangName(w), size: baseSize(style), relativeTo: style)
    }

    /// 苹方，指定字号（仍按正文比例跟随动态字体）
    static func pf(size: CGFloat, weight: Font.Weight = .regular) -> Font {
        .custom(pingFangName(weight), size: size, relativeTo: .body)
    }

    /// 各文字样式在默认字号下的大小（与系统一致）
    private static func baseSize(_ style: Font.TextStyle) -> CGFloat {
        #if os(watchOS)
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 24
        case .title3: return 19
        case .headline: return 16
        case .body: return 16
        case .callout: return 15
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 14
        case .caption2: return 13
        default: return 16
        }
        #else
        switch style {
        case .largeTitle: return 34
        case .title: return 28
        case .title2: return 22
        case .title3: return 20
        case .headline: return 17
        case .body: return 17
        case .callout: return 16
        case .subheadline: return 15
        case .footnote: return 13
        case .caption: return 12
        case .caption2: return 11
        default: return 17
        }
        #endif
    }
}

// MARK: - 液态玻璃按钮

extension View {
    /// 主要操作：系统的着色液态玻璃按钮（`.glassProminent`），默认系统蓝。
    /// 旧系统（iOS 26 / watchOS 26 之前）退回系统的胶囊实心按钮。
    @ViewBuilder
    func glassProminentButton(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            self.buttonStyle(.glassProminent).tint(tint)
        } else {
            self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(tint)
        }
        #else
        self.buttonStyle(.borderedProminent).buttonBorderShape(.capsule).tint(tint)
        #endif
    }

    /// 次要操作：系统的透明液态玻璃按钮（`.glass`）。
    @ViewBuilder
    func glassButton(tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            self.buttonStyle(.glass).tint(tint)
        } else {
            self.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(tint)
        }
        #else
        self.buttonStyle(.bordered).buttonBorderShape(.capsule).tint(tint)
        #endif
    }

    /// 自定义形状（比如长按求救的圆钮）铺一层系统液态玻璃。
    @ViewBuilder
    func glassBackground<S: Shape>(in shape: S, tint: Color? = nil) -> some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, watchOS 26.0, *) {
            self.glassEffect(tint.map { Glass.regular.tint($0.opacity(0.25)).interactive() } ?? Glass.regular.interactive(), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
        }
        #else
        self.background(.ultraThinMaterial, in: shape)
        #endif
    }
}
