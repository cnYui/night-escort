import EscortKit
import SwiftUI

/// 首页「谁在守护我」的人员规则：按最近一次一起回家排，越久没一起气泡越小，35 天没一起就从首页消失（搜索里还能找到）。
enum HomePeople {
    /// 超过这么多天没一起回家，就不在首页显示
    static let fadeOutDays: Double = 35
    /// 回家路上那一排最多放几个
    static let rowCapacity = 6

    static func days(_ c: Connection, now: Date = Date()) -> Double {
        now.timeIntervalSince(c.lastTogetherAt ?? c.connectedAt) / 86_400
    }

    /// 首页能看到的人（最近的在前）和已经淡出的人
    static func split(_ connections: [Connection], now: Date = Date()) -> (shown: [Connection], gone: [Connection]) {
        let sorted = connections.sorted { days($0, now: now) < days($1, now: now) }
        return (sorted.filter { days($0, now: now) < fadeOutDays }, sorted.filter { days($0, now: now) >= fadeOutDays })
    }

    /// 气泡直径：3 天内一起回过家最大，之后一天天变小，到 35 天缩到最小然后消失；还不能守护你的人再小一号
    static func bubbleSize(_ c: Connection, now: Date = Date()) -> CGFloat {
        let d = days(c, now: now)
        let maxSize: CGFloat = 72, minSize: CGFloat = 30
        let t = CGFloat(min(max((d - 3) / (fadeOutDays - 3), 0), 1))
        let size = maxSize - (maxSize - minSize) * t
        return c.guardsMe == nil ? size * 0.82 : size
    }
}

/// 蜂窝气泡：你在中间，大家按最近一起回家的先后一圈圈排开，不画线。
/// 和 Apple Watch 主屏一样，靠近边缘的气泡会缩小；双指缩放、单指拖动可以看到外圈的人，右下角按钮回到中间。
struct GraphView: View {
    let me: String
    let connections: [Connection]
    /// 带蓝圈的人：没出发时是你点选的人，回家路上是正在守着你的人
    let inEscort: Set<String>
    let onTap: (Connection) -> Void
    /// 长按气泡看详情
    let onDetail: (Connection) -> Void

    /// 相邻两个格子中心的距离
    private static let spacing: CGFloat = 100
    private static let meSize: CGFloat = 84
    private static let zoomRange: ClosedRange<CGFloat> = 0.6...1.8

    @State private var zoom: CGFloat = GraphView.initialZoom
    @GestureState private var pinch: CGFloat = 1
    @State private var pan: CGSize = .zero
    @GestureState private var drag: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let split = HomePeople.split(connections)
            if geo.size.height < 360 && !split.shown.isEmpty {
                compactRow(Array(split.shown.prefix(HomePeople.rowCapacity)), size: geo.size)
            } else {
                honeycomb(split.shown, gone: split.gone.count, size: geo.size)
            }
        }
        .padding(.top, 8)
    }

    // MARK: 回家路上：下面面板占了地方，只留一排小气泡，蓝圈是这次守着你的人

    private func compactRow(_ people: [Connection], size: CGSize) -> some View {
        HStack(alignment: .top, spacing: 6) {
            ForEach(people) { c in
                HexBubble(connection: c, chosen: inEscort.contains(c.id), diameter: HomePeople.bubbleSize(c) * 0.8, showName: true)
                    .frame(maxWidth: .infinity)
                    .onTapGesture { onTap(c) }
                    .contextMenu { detailButton(c) }
            }
        }
        .padding(.horizontal)
        .padding(.top, 12)
        .frame(width: size.width, height: size.height, alignment: .top)
    }

    private func detailButton(_ c: Connection) -> some View {
        Button { onDetail(c) } label: { Label("查看\(c.shownName)", systemImage: "person.crop.circle") }
    }

    // MARK: 蜂窝

    private func honeycomb(_ people: [Connection], gone: Int, size: CGSize) -> some View {
        let z = (zoom * pinch).clamped(to: Self.zoomRange)
        let off = CGSize(width: pan.width + drag.width, height: pan.height + drag.height)
        let center = CGPoint(x: size.width / 2, y: size.height / 2)
        let cells = Self.hexCells(count: people.count + 1)
        let moved = abs(zoom - 1) > 0.01 || hypot(pan.width, pan.height) > 1

        func place(_ cell: CGPoint) -> (point: CGPoint, scale: CGFloat) {
            let raw = CGPoint(x: center.x + off.width + cell.x * Self.spacing * z,
                              y: center.y + off.height + cell.y * Self.spacing * z)
            return Self.fisheye(raw, center: center, size: size)
        }

        return ZStack {
            if people.isEmpty {
                VStack(spacing: 6) {
                    Text("还没有人守护你").font(.pf(.headline))
                    Text("点右上角 + 加一个你信任的人。加进来的人平时看不到你的位置，只有你回家时选中的人才能看到。")
                        .font(.pf(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                }
                .padding(.horizontal, 36)
                .position(x: center.x, y: center.y + 150)
            }

            ForEach(Array(people.enumerated()), id: \.element.id) { i, c in
                let at = place(cells[i + 1])
                if at.scale > 0.05 {
                    HexBubble(connection: c, chosen: inEscort.contains(c.id),
                              diameter: HomePeople.bubbleSize(c) * z * at.scale,
                              showName: at.scale > 0.75 && z > 0.75)
                        .opacity(Double(min(1, at.scale * 1.6)))
                        .onTapGesture { onTap(c) }
                        .contextMenu { detailButton(c) }
                        .position(at.point)
                }
            }

            let meAt = place(cells[0])
            if meAt.scale > 0.05 {
                VStack(spacing: 4) {
                    AvatarView(name: me, size: Self.meSize * z * meAt.scale, tint: Theme.accent)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                        .shadow(color: Theme.accent.opacity(0.25), radius: 12, y: 5)
                    if meAt.scale > 0.75 && z > 0.75 {
                        Text("我").font(.pf(.footnote, weight: .semibold))
                    }
                }
                .offset(y: meAt.scale > 0.75 && z > 0.75 ? 10 : 0)
                .position(meAt.point)
            }

            if gone > 0 && !moved {
                Text("还有 \(gone) 人超过 35 天没一起回家，搜索能找到")
                    .font(.pf(.caption)).foregroundStyle(.secondary)
                    .position(x: center.x, y: size.height - 10)
            }
        }
        .frame(width: size.width, height: size.height)
        .contentShape(Rectangle())
        .clipped()
        .gesture(
            SimultaneousGesture(
                MagnifyGesture()
                    .updating($pinch) { v, s, _ in s = v.magnification }
                    .onEnded { v in zoom = (zoom * v.magnification).clamped(to: Self.zoomRange) },
                DragGesture(minimumDistance: 8)
                    .updating($drag) { v, s, _ in s = v.translation }
                    .onEnded { v in
                        let limit = Self.spacing * zoom * CGFloat(Self.ringCount(people.count + 1))
                        pan = CGSize(width: (pan.width + v.translation.width).clamped(to: -limit...limit),
                                     height: (pan.height + v.translation.height).clamped(to: -limit...limit))
                    }
            )
        )
        .overlay(alignment: .bottomTrailing) {
            if moved {
                Button {
                    withAnimation(.spring(duration: 0.4)) { zoom = 1; pan = .zero }
                } label: {
                    Image(systemName: "scope").font(.system(size: 17, weight: .semibold))
                        .frame(width: 22, height: 22)
                }
                .glassButton()
                .controlSize(.large)
                .accessibilityLabel("回到中间")
                .padding(.trailing, 16)
                .padding(.bottom, 4)
                .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.2), value: moved)
    }

    /// 调试截图用：启动参数 `-homeZoom 0.6` 可以直接看缩放后的样子（模拟器没法模拟双指）
    private static var initialZoom: CGFloat {
        #if DEBUG
        let v = UserDefaults.standard.double(forKey: "homeZoom")
        if v > 0 { return CGFloat(v).clamped(to: zoomRange) }
        #endif
        return 1
    }

    // MARK: 几何

    /// 蜂窝格子，从中间一圈圈往外螺旋排；单位距离 = 相邻格子中心距
    static func hexCells(count: Int) -> [CGPoint] {
        let dirs = [(1, 0), (1, -1), (0, -1), (-1, 0), (-1, 1), (0, 1)]
        var axial: [(Int, Int)] = [(0, 0)]
        var k = 1
        while axial.count < count {
            var q = dirs[4].0 * k, r = dirs[4].1 * k
            for side in 0..<6 {
                for _ in 0..<k {
                    axial.append((q, r))
                    q += dirs[side].0
                    r += dirs[side].1
                }
            }
            k += 1
        }
        return axial.prefix(count).map { q, r in
            CGPoint(x: CGFloat(q) + CGFloat(r) / 2, y: CGFloat(r) * sqrt(3) / 2)
        }
    }

    /// 放下 count 个格子需要几圈
    static func ringCount(_ count: Int) -> Int {
        var k = 0, total = 1
        while total < count { k += 1; total += 6 * k }
        return k
    }

    /// 手表那种边缘缩小：中间一块原样，越靠边越小、越往里收，出了边就看不见
    static func fisheye(_ p: CGPoint, center: CGPoint, size: CGSize) -> (point: CGPoint, scale: CGFloat) {
        let rx = max(size.width / 2, 1), ry = max(size.height / 2, 1)
        let dx = p.x - center.x, dy = p.y - center.y
        let n = sqrt((dx / rx) * (dx / rx) + (dy / ry) * (dy / ry))
        let inner: CGFloat = 0.62
        guard n > inner else { return (p, 1) }
        let t = min((n - inner) / 0.5, 1)
        let scale = max(0, 1 - t)
        let squeezed = (inner + (n - inner) * 0.7) / n
        return (CGPoint(x: center.x + dx * squeezed, y: center.y + dy * squeezed), scale)
    }
}

private struct HexBubble: View {
    let connection: Connection
    let chosen: Bool
    let diameter: CGFloat
    let showName: Bool

    var body: some View {
        let c = connection
        VStack(spacing: 3) {
            AvatarView(name: c.shownName, url: c.peer.avatarUrl, size: diameter)
                .overlay(Circle().stroke(chosen ? Theme.accent : Color(.systemBackground), lineWidth: chosen ? 3 : 2))
                .shadow(color: .black.opacity(0.10), radius: 8, y: 4)
                .overlay(alignment: .bottomTrailing) {
                    if chosen && diameter > 34 {
                        Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy))
                            .frame(width: 20, height: 20)
                            .background(Theme.accent, in: Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .foregroundStyle(.white)
                            .offset(x: 3, y: 3)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if c.guardsMe?.tier == .temporary && diameter > 40 {
                        Image(systemName: "hourglass").font(.system(size: 9, weight: .bold))
                            .frame(width: 20, height: 20)
                            .background(Theme.temporary, in: Circle())
                            .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                            .foregroundStyle(.white)
                            .offset(x: 3, y: -3)
                    }
                }
            if showName {
                Text(c.shownName).font(.pf(.caption, weight: .medium)).lineLimit(1).fixedSize()
            }
        }
        // 名字不参与占位，避免把气泡顶歪
        .frame(width: diameter, height: diameter)
        .contentShape(Circle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(c.shownName)
        .accessibilityAddTraits(.isButton)
    }
}

private extension Comparable {
    func clamped(to r: ClosedRange<Self>) -> Self { min(max(self, r.lowerBound), r.upperBound) }
}
