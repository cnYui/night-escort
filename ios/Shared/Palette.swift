import SwiftUI
#if canImport(UIKit)
import UIKit
#endif

// 薰衣草金配色（2026-11-14）。色值取自最早那版手表设计「蜜桃薰衣草（深）」，见 design/README.md。
// 组件仍然全是苹果原生的（液态玻璃按钮、系统列表、SF Symbols、苹方），这里只管颜色。
// 现在有三个候选等用户挑：调试时用启动参数 `-palette a|b|c` 切换，不传就是原来的苹果默认蓝。

/// 手机、手表、小组件共用的品牌色
enum Brand {
    /// 深紫底
    static let base = Color(hex: 0x15111F)
    /// 蜜桃金
    static let gold = Color(hex: 0xFFDAB9)
    /// 薰衣草
    static let lavender = Color(hex: 0xC7B8EA)
    /// 金、薰衣草底上写字用的深紫
    static let deepPurple = Color(hex: 0x2A1F3D)
    /// 深底上的正文
    static let cream = Color(hex: 0xFFF7F0)
    /// 薰衣草紫：白底上的按钮、链接（#C7B8EA 在白底上太浅）
    static let purple = Color(hex: 0x6B47BF)
    /// 深底上的求救红
    static let rose = Color(hex: 0xFF6B7D)
}

enum Palette: String, CaseIterable {
    /// 原来的样子：白底 + 系统蓝
    case system
    /// A 白底薰衣草：底色不动，系统蓝换成薰衣草紫，金色只做点缀；跟随系统深浅色
    case a
    /// B 淡紫底金按钮：底色换成很淡的薰衣草，主按钮蜜桃金配深紫字
    case b
    /// C 夜色紫金：和最早的手表同款，深紫底加蜜桃金、薰衣草两团光晕，主按钮蜜桃金
    case c

    static let current: Palette = {
        let raw = UserDefaults.standard.string(forKey: "palette")?.lowercased() ?? ""
        return Palette(rawValue: raw) ?? .system
    }()

    /// 强调色：链接、图标、进度条
    var accent: Color {
        switch self {
        case .system: return .blue
        case .a, .b: return .adaptive(light: 0x6B47BF, dark: 0xC7B8EA)
        case .c: return Brand.lavender
        }
    }

    /// 强调色上面的图标和字
    var onAccent: Color {
        switch self {
        case .system: return .white
        case .a, .b: return .adaptive(light: 0xFFFFFF, dark: 0x2A1F3D)
        case .c: return Brand.deepPurple
        }
    }

    /// 主按钮底色
    var primary: Color {
        switch self {
        case .system: return .blue
        case .a: return accent
        case .b, .c: return Brand.gold
        }
    }

    /// 主按钮上的字
    var onPrimary: Color {
        switch self {
        case .system: return .white
        case .a: return onAccent
        case .b, .c: return Brand.deepPurple
        }
    }

    /// 今晚临时守护的人：原来的系统橙换成金。白底上用加深的蜜桃金，否则字看不清
    var temporary: Color {
        switch self {
        case .system: return .orange
        case .a, .b: return .adaptive(light: 0xB0722A, dark: 0xFFDAB9)
        case .c: return Brand.gold
        }
    }

    var onTemporary: Color {
        switch self {
        case .system: return .white
        case .a, .b: return .adaptive(light: 0xFFFFFF, dark: 0x2A1F3D)
        case .c: return Brand.deepPurple
        }
    }
}

extension Color {
    init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }

    /// 浅色、深色界面各用一个色值。手表只有深色界面，直接取深色那个
    static func adaptive(light: UInt32, dark: UInt32) -> Color {
        #if os(watchOS)
        return Color(hex: dark)
        #else
        return Color(UIColor { traits in
            let hex = traits.userInterfaceStyle == .dark ? dark : light
            return UIColor(
                red: CGFloat((hex >> 16) & 0xFF) / 255,
                green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255,
                alpha: 1
            )
        })
        #endif
    }
}

/// 深紫底上的两团光晕：左上蜜桃金、右下薰衣草（最早那版手表的做法）。只有 C 配色用
struct BrandGlow: View {
    var strength: Double = 1

    var body: some View {
        GeometryReader { geo in
            let reach = max(geo.size.width, geo.size.height)
            ZStack {
                RadialGradient(
                    colors: [Brand.gold.opacity(0.24 * strength), Brand.gold.opacity(0)],
                    center: .topLeading, startRadius: 0, endRadius: reach * 0.7
                )
                RadialGradient(
                    colors: [Brand.lavender.opacity(0.30 * strength), Brand.lavender.opacity(0)],
                    center: .bottomTrailing, startRadius: 0, endRadius: reach * 0.8
                )
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
