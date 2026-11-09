import EscortKit
import SwiftUI

/// 首页「谁在守护我」的两种样子，先都留着给用户挑：
/// - bubble：气泡，你在中间，大家散在周围，不画线
/// - list：系统设置 / 查找那种分组列表
/// 调试时用启动参数 `-homeStyle bubble|list` 切换。
enum HomeStyle: String {
    case bubble, list
    static var current: HomeStyle { HomeStyle(rawValue: UserDefaults.standard.string(forKey: "homeStyle") ?? "") ?? .bubble }
}

/// 首页人员的共用规则：最多显示 6 人，按最近一起回家的远近排；35 天没一起的收进「全部」。
enum HomePeople {
    static let capacity = 6

    static func days(_ c: Connection, now: Date = Date()) -> Double {
        now.timeIntervalSince(c.lastTogetherAt ?? c.connectedAt) / 86_400
    }

    static func split(_ connections: [Connection], now: Date = Date()) -> (shown: [Connection], rest: [Connection]) {
        let sorted = connections.sorted { days($0, now: now) < days($1, now: now) }
        var shown: [Connection] = []
        var rest: [Connection] = []
        for c in sorted {
            if days(c, now: now) >= 35 || shown.count >= capacity { rest.append(c) } else { shown.append(c) }
        }
        return (shown, rest)
    }

    /// 一句话写清楚这个人和你的关系现在是什么状态
    static func detail(_ c: Connection, now: Date = Date()) -> String {
        if let g = c.guardsMe, g.tier == .temporary, g.bindToEscort { return "临时守护，这次到家后自动取消" }
        let d = days(c, now: now)
        let when: String
        if d < 1 { when = "今天一起回过家" }
        else if d <= 20 { when = "\(Int(d)) 天前一起回过家" }
        else { when = "\(Int(d / 7)) 周没一起回家" }
        return c.guardsMe == nil ? "还不能守护你 · \(when)" : when
    }
}

// MARK: - A 气泡

struct GraphView: View {
    let me: String
    let connections: [Connection]
    let inEscort: Set<String>
    let onTap: (Connection) -> Void
    let onDragOut: (Connection) -> Void

    private static let meSize: CGFloat = 92
    /// 每个位置的角度和远近都稍微错开一点，看起来像散开的气泡，不是钟表刻度
    private static let angleJitter: [Double] = [0, 9, -7, 12, -10, 6]
    /// 远近只做一点点区分，亲疏主要看气泡大小
    private static let ringJitter: [CGFloat] = [0, 0.03, -0.02, 0.03, -0.01, 0.02]

    @State private var dragging: String?
    @State private var dragOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            let size = min(geo.size.width, geo.size.height)
            let center = CGPoint(x: geo.size.width / 2, y: geo.size.height / 2)
            let split = HomePeople.split(connections)
            let shown = split.shown
            if geo.size.height < 360 && !shown.isEmpty {
                // 回家路上下面的面板会把这块压矮：不再围成一圈，只留一排小气泡，蓝圈是这次守着你的人
                HStack(alignment: .top, spacing: 6) {
                    ForEach(shown) { c in
                        BubbleView(connection: c, chosen: inEscort.contains(c.id), labelsAbove: false, scale: 0.7, showDetail: false)
                            .padding(.bottom, 22)
                            .frame(maxWidth: .infinity)
                            .onTapGesture { onTap(c) }
                    }
                }
                .frame(width: geo.size.width, height: geo.size.height)
            } else {
            ZStack {
                if shown.isEmpty {
                    VStack(spacing: 6) {
                        Text("还没有人守护你").font(.pf(.headline))
                        Text("点右上角 + 加一个你信任的人。加进来的人平时看不到你的位置，只有你回家时选中的人才能看到。")
                            .font(.pf(.footnote)).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 36)
                    .position(x: center.x, y: center.y + size * 0.36)
                }

                ForEach(Array(shown.enumerated()), id: \.element.id) { i, c in
                    let p = position(i, count: shown.count, c: c, size: size, center: center)
                    BubbleView(connection: c, chosen: inEscort.contains(c.id), labelsAbove: p.y < center.y - 8)
                        .position(p)
                        .offset(dragging == c.id ? dragOffset : .zero)
                        .onTapGesture { onTap(c) }
                        .gesture(
                            LongPressGesture(minimumDuration: 0.4)
                                .sequenced(before: DragGesture())
                                .onChanged { v in
                                    if case .second(true, let drag?) = v {
                                        dragging = c.id
                                        dragOffset = drag.translation
                                    }
                                }
                                .onEnded { v in
                                    defer { dragging = nil; dragOffset = .zero }
                                    guard case .second(true, let drag?) = v else { return }
                                    let end = CGPoint(x: p.x + drag.translation.width, y: p.y + drag.translation.height)
                                    if hypot(end.x - center.x, end.y - center.y) > size * 0.5 { onDragOut(c) }
                                }
                        )
                }

                VStack(spacing: 6) {
                    AvatarView(name: me, size: Self.meSize, tint: Theme.accent)
                        .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 4))
                        .shadow(color: Theme.accent.opacity(0.25), radius: 14, y: 6)
                    Text("我").font(.pf(.subheadline, weight: .semibold))
                }
                .offset(y: 12)
                .position(center)

                if !split.rest.isEmpty {
                    Text("还有 \(split.rest.count) 人很久没一起回家，点上面的搜索能找到")
                        .font(.pf(.caption)).foregroundStyle(.secondary)
                        .position(x: center.x, y: geo.size.height - 10)
                }
            }
            }
        }
        .padding(.horizontal)
        .padding(.top, 14)
    }

    private func position(_ i: Int, count: Int, c: Connection, size: CGFloat, center: CGPoint) -> CGPoint {
        let d = HomePeople.days(c)
        let ring: CGFloat = (d <= 7 ? 0.64 : d <= 20 ? 0.7 : 0.76) + Self.ringJitter[i % 6]
        let angle = (Double(i) / Double(max(count, 1))) * 2 * .pi - .pi / 2 + Self.angleJitter[i % 6] * .pi / 180
        let r = size / 2 * ring
        return CGPoint(x: center.x + r * CGFloat(cos(angle)), y: center.y + r * CGFloat(sin(angle)))
    }
}

private struct BubbleView: View {
    let connection: Connection
    let chosen: Bool
    let labelsAbove: Bool
    var scale: CGFloat = 1
    var showDetail = true

    var body: some View {
        let c = connection
        let isGuardian = c.guardsMe != nil
        // 气泡大小表示亲疏：7 天内一起回过家最大，越久越小；还不能守护你的人再小一号
        let d = HomePeople.days(c)
        let base: CGFloat = d <= 7 ? 74 : d <= 20 ? 60 : 50
        let size: CGFloat = (isGuardian ? base : base * 0.8) * scale
        let faded = HomePeople.days(c) > 20
        ZStack(alignment: .topTrailing) {
            AvatarView(name: c.shownName, url: c.peer.avatarUrl, size: size)
                .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 3))
                .padding(3)
                .overlay(Circle().stroke(chosen ? Theme.accent : .clear, lineWidth: 3))
                .shadow(color: .black.opacity(0.10), radius: 10, y: 5)
            if c.guardsMe?.tier == .temporary {
                Image(systemName: "hourglass").font(.system(size: 10, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(Theme.temporary, in: Circle())
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
                    .foregroundStyle(.white)
            }
        }
        .overlay(alignment: labelsAbove ? .top : .bottom) {
            VStack(spacing: 1) {
                Text(c.shownName).font(.pf(.footnote, weight: .medium))
                if !showDetail {
                    EmptyView()
                } else if c.guardsMe?.tier == .temporary, c.guardsMe?.bindToEscort == true {
                    Text("到家后取消").font(.pf(.caption2)).foregroundStyle(Theme.temporary)
                } else if !isGuardian {
                    Text("还不能守护你").font(.pf(.caption2)).foregroundStyle(.secondary)
                } else if faded {
                    Text("\(Int(HomePeople.days(c) / 7)) 周没一起").font(.pf(.caption2)).foregroundStyle(.secondary)
                }
            }
            .fixedSize()
            .alignmentGuide(labelsAbove ? VerticalAlignment.top : VerticalAlignment.bottom) { d in
                labelsAbove ? d[.bottom] + 4 : d[.top] - 4
            }
        }
        .opacity(faded ? 0.55 : 1)
        .contentShape(Rectangle())
    }
}

// MARK: - B 分组列表

struct PeopleListView: View {
    let connections: [Connection]
    let inEscort: Set<String>
    let onTap: (Connection) -> Void
    let onRemove: (Connection) -> Void

    var body: some View {
        let guardians = connections.filter { $0.guardsMe != nil }
            .sorted { HomePeople.days($0) < HomePeople.days($1) }
        let friends = connections.filter { $0.guardsMe == nil }
            .sorted { HomePeople.days($0) < HomePeople.days($1) }
        List {
            if connections.isEmpty {
                ContentUnavailableView("还没有人守护你", systemImage: "person.2",
                                       description: Text("点右上角 + 加一个你信任的人。"))
            }
            if !guardians.isEmpty {
                Section {
                    ForEach(guardians) { c in row(c) }
                } header: {
                    Text("守护我的人")
                } footer: {
                    Text("回家时从这些人里选几个，他们会看到你到没到家。向左滑可以移出。")
                }
            }
            if !friends.isEmpty {
                Section {
                    ForEach(friends) { c in row(c) }
                } header: {
                    Text("好友")
                } footer: {
                    Text("好友还不能守护你，点进去可以请她守护你。")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func row(_ c: Connection) -> some View {
        let faded = HomePeople.days(c) > 20
        return Button { onTap(c) } label: {
            HStack(spacing: 12) {
                AvatarView(name: c.shownName, url: c.peer.avatarUrl, size: 44)
                VStack(alignment: .leading, spacing: 2) {
                    Text(c.shownName).font(.pf(.body)).foregroundStyle(.primary)
                    Text(HomePeople.detail(c))
                        .font(.pf(.footnote))
                        .foregroundStyle(c.guardsMe?.tier == .temporary && c.guardsMe?.bindToEscort == true ? Theme.temporary : .secondary)
                }
                Spacer(minLength: 8)
                if inEscort.contains(c.id) {
                    Label("正在守护", systemImage: "checkmark.circle.fill")
                        .labelStyle(.titleAndIcon)
                        .font(.pf(.caption, weight: .semibold))
                        .foregroundStyle(Theme.accent)
                } else if let g = c.guardsMe {
                    TierBadge(tier: g.tier)
                }
            }
            .opacity(faded ? 0.55 : 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if c.guardsMe != nil {
                Button("移出", role: .destructive) { onRemove(c) }
            }
        }
    }
}
