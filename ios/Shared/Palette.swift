import SwiftUI

// 配色（2026-11-18 定稿）：手机用「夜色紫金」，手表用「黑底薰衣草」。
// 色值取自最早那版手表设计「蜜桃薰衣草（深）」，见 design/README.md。
// 组件仍然全是苹果原生的（液态玻璃按钮、系统列表、SF Symbols、苹方），这里只管颜色。

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
}

/// 按用途取色。手机和手表只有主按钮不同：手机蜜桃金，手表薰衣草
enum Palette {
    /// 强调色：链接、图标、进度条
    static let accent = Brand.lavender
    /// 强调色上面的图标和字
    static let onAccent = Brand.deepPurple

    /// 主按钮底色
    #if os(watchOS)
    static let primary = Brand.lavender
    #else
    static let primary = Brand.gold
    #endif
    /// 主按钮上的字
    static let onPrimary = Brand.deepPurple

    /// 今晚临时守护的人
    static let temporary = Brand.gold
    static let onTemporary = Brand.deepPurple
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
}

/// 深紫底上的两团光晕：左上蜜桃金、右下薰衣草（最早那版手表的做法）。手机的主要页面用
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
