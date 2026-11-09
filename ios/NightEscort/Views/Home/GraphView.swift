import EscortKit
import SwiftUI

/**
 关系图谱：你在中间，最多 6 人。
 - 灰线 = 已连接，蓝线 = 今晚选了；
 - 按亲疏显示：7 天内一起回过家的离中心近、清楚；8–20 天稍远稍淡；21 天以上更远更淡，标“N 周没一起”；
   35 天没一起就移到「全部」，空位给新连上的人；
 - 点头像出小卡；长按拖到图谱外 = 移出担保人。
 */
struct GraphView: View {
    let me: String
    let connections: [Connection]
    let inEscort: Set<String>
    let onTap: (Connection) -> Void
    let onDragOut: (Connection) -> Void

    static let capacity = 6
    private static let meAvatarSize: CGFloat = 64

    struct Node: Identifiable {
        let connection: Connection
        let ring: CGFloat   // 0…1，离中心的相对距离
        let opacity: Double
        let note: String?
        var id: String { connection.id }
    }

    static func layout(_ connections: [Connection], now: Date = Date()) -> (shown: [Node], rest: [Connection]) {
        func days(_ c: Connection) -> Double {
            let ref = c.lastTogetherAt ?? c.connectedAt
            return now.timeIntervalSince(ref) / 86_400
        }
        let sorted = connections.sorted { days($0) < days($1) }
        var shown: [Node] = []
        var rest: [Connection] = []
        for c in sorted {
            let d = days(c)
            if d >= 35 || shown.count >= capacity {
                rest.append(c)
                continue
            }
            if d <= 7 {
                shown.append(Node(connection: c, ring: 0.55, opacity: 1, note: nil))
            } else if d <= 20 {
                shown.append(Node(connection: c, ring: 0.72, opacity: 0.75, note: nil))
            } else {
                shown.append(Node(connection: c, ring: 0.9, opacity: 0.45, note: "\(Int(d / 7)) 周没一起"))
            }
        }
        return (shown, rest)
    }

    @State private var dragging: String?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let laid = Self.layout(connections)
            let nodes = laid.shown
            let rest = laid.rest
            ZStack {
                if nodes.isEmpty {
                    VStack(spacing: 8) {
                        Text("点 + 加一个你信任的人").font(.pf(.headline))
                        Text("加进来的人不会看到你的位置，只有你护航时选中的人才能看到。")
                            .font(.pf(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 40)
                    .offset(y: size * 0.32)
                }
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                    let p = position(i, count: nodes.count, ring: n.ring, size: size, center: center)
                    let chosen = inEscort.contains(n.id)
                    let ends = lineEnds(from: center, to: p, startInset: Self.meAvatarSize / 2 + 2, endInset: NodeView.outerRadius(n.connection) + 1)
                    Path { path in
                        path.move(to: ends.start)
                        path.addLine(to: ends.end)
                    }
                    .stroke(chosen ? Theme.accent : Color.gray.opacity(0.35), style: StrokeStyle(lineWidth: chosen ? 2.5 : 1.2))
                    .opacity(n.opacity)
                }
                ForEach(Array(nodes.enumerated()), id: \.element.id) { i, n in
                    let p = position(i, count: nodes.count, ring: n.ring, size: size, center: center)
                    NodeView(node: n, chosen: inEscort.contains(n.id), labelsAbove: p.y < center.y)
                        .position(p)
                        .offset(dragging == n.id ? dragOffset : .zero)
                        .onTapGesture { onTap(n.connection) }
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .sequenced(before: DragGesture())
                                .onChanged { v in
                                    if case .second(true, let drag?) = v {
                                        dragging = n.id
                                        dragOffset = drag.translation
                                    }
                                }
                                .onEnded { v in
                                    defer { dragging = nil; dragOffset = .zero }
                                    guard case .second(true, let drag?) = v else { return }
                                    let end = CGPoint(x: p.x + drag.translation.width, y: p.y + drag.translation.height)
                                    if hypot(end.x - center.x, end.y - center.y) > size * 0.5 { onDragOut(n.connection) }
                                }
                        )
                }
                AvatarView(name: me, size: Self.meAvatarSize, tint: Theme.accent)
                    .overlay(alignment: .bottom) {
                        Text("我").font(.pf(.caption, weight: .semibold))
                            .padding(.horizontal, 4)
                            .background(Color(.systemBackground), in: Capsule())
                            .alignmentGuide(.bottom) { d in d[.top] - 4 }
                    }
                    .position(center)
                if !rest.isEmpty {
                    Text("全部 \(connections.count) 人").font(.pf(.caption)).foregroundStyle(.secondary)
                        .position(x: center.x, y: geo.size.height - 12)
                }
            }
        }
        .padding()
    }

    /// 连线两端都收到头像边缘，不从头像上穿过去
    private func lineEnds(from a: CGPoint, to b: CGPoint, startInset: CGFloat, endInset: CGFloat) -> (start: CGPoint, end: CGPoint) {
        let d = max(hypot(b.x - a.x, b.y - a.y), 1)
        let u = CGPoint(x: (b.x - a.x) / d, y: (b.y - a.y) / d)
        return (CGPoint(x: a.x + u.x * startInset, y: a.y + u.y * startInset),
                CGPoint(x: b.x - u.x * endInset, y: b.y - u.y * endInset))
    }

    private func position(_ i: Int, count: Int, ring: CGFloat, size: CGFloat, center: CGPoint) -> CGPoint {
        let angle = (Double(i) / Double(max(count, 1))) * 2 * .pi - .pi / 2
        let r = size / 2 * ring
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }
}

private struct NodeView: View {
    let node: GraphView.Node
    let chosen: Bool
    /// 文字放在头像远离中心的一侧，连线不会穿过文字，也不会碰到中间的“我”
    let labelsAbove: Bool

    /// 头像外圈（含蓝环的留白）的半径
    static func outerRadius(_ c: Connection) -> CGFloat { (c.guardsMe != nil ? 50 : 30) / 2 + 3 }

    var body: some View {
        let c = node.connection
        let isGuardian = c.guardsMe != nil
        ZStack(alignment: .topTrailing) {
            AvatarView(name: c.shownName, url: c.peer.avatarUrl, size: isGuardian ? 50 : 30)
                .padding(3)
                .overlay(Circle().stroke(chosen ? Theme.accent : .clear, lineWidth: 2.5))
            if c.guardsMe?.tier == .temporary {
                Image(systemName: "hourglass").font(.system(size: 9, weight: .bold))
                    .frame(width: 18, height: 18)
                    .background(Theme.temporary, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: labelsAbove ? Alignment.top : Alignment.bottom) {
            VStack(spacing: 2) {
                Text(c.shownName).font(.pf(.caption))
                if c.guardsMe?.tier == .temporary, c.guardsMe?.bindToEscort == true {
                    Text("到家失效").font(.pf(.caption2)).foregroundStyle(Theme.temporary)
                } else if let note = node.note {
                    Text(note).font(.pf(.caption2)).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .alignmentGuide(labelsAbove ? VerticalAlignment.top : VerticalAlignment.bottom) { d in
                labelsAbove ? d[.bottom] + 3 : d[.top] - 3
            }
        }
        .opacity(node.opacity)
        .contentShape(Rectangle())
    }
}
