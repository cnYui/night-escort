import SwiftUI

/// 用户协议和隐私政策。文字和后端网页版同一份（backend/legal/*.md，打进 App 包），离线也能看。
enum LegalDoc: String, Identifiable {
    case terms, privacy
    var id: String { rawValue }
    var title: String { self == .terms ? "用户协议" : "隐私政策" }

    /// 登录页文字里的链接：anquanhuijia-legal:terms / anquanhuijia-legal:privacy
    static let linkScheme = "anquanhuijia-legal"
    init?(url: URL) {
        guard url.scheme == Self.linkScheme, let d = LegalDoc(rawValue: url.absoluteString.replacingOccurrences(of: "\(Self.linkScheme):", with: "")) else { return nil }
        self = d
    }

    var markdown: String {
        let url = Bundle.main.url(forResource: rawValue, withExtension: "md")
            ?? Bundle.main.url(forResource: rawValue, withExtension: "md", subdirectory: "legal")
        return url.flatMap { try? String(contentsOf: $0, encoding: .utf8) } ?? "# \(title)\n\n没找到文档，请稍后在网页上查看。"
    }
}

struct LegalView: View {
    @Environment(\.dismiss) private var dismiss
    let doc: LegalDoc

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(Self.blocks(doc.markdown).enumerated()), id: \.offset) { _, b in
                        block(b)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(Backdrop(glow: false))
            .navigationTitle(doc.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("完成") { dismiss() } }
            }
        }
    }

    enum Block { case title(String), heading(String), bullet(String, indent: Bool), text(String) }

    /// 只认文档里用到的写法：# 标题、## 小标题、- 列表（可缩进一级）、**加粗**
    static func blocks(_ md: String) -> [Block] {
        md.split(separator: "\n", omittingEmptySubsequences: true).compactMap { raw in
            let line = String(raw)
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return nil }
            if line.hasPrefix("# ") { return .title(String(line.dropFirst(2))) }
            if line.hasPrefix("## ") { return .heading(String(line.dropFirst(3))) }
            if trimmed.hasPrefix("- ") { return .bullet(String(trimmed.dropFirst(2)), indent: line.hasPrefix("  ")) }
            return .text(line)
        }
    }

    private func rich(_ s: String) -> Text {
        Text((try? AttributedString(markdown: s)) ?? AttributedString(s))
    }

    @ViewBuilder private func block(_ b: Block) -> some View {
        switch b {
        case .title(let s):
            Text(s).font(.pf(.title2, weight: .semibold)).padding(.bottom, 4)
        case .heading(let s):
            Text(s).font(.pf(.headline)).padding(.top, 12)
        case .bullet(let s, let indent):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text("•").foregroundStyle(.secondary)
                rich(s).font(.pf(.subheadline))
            }
            .padding(.leading, indent ? 18 : 0)
        case .text(let s):
            rich(s).font(.pf(.subheadline))
        }
    }
}
