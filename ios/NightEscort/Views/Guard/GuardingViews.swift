import EscortKit
import MapKit
import SwiftUI

/// 我守护的人：别人回家时选了我，我在这里看她们的状态。每人一张卡，联系不上 > 护航中 > 暂停 > 已结束
struct GuardingView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationStack {
            List {
                if model.cards.isEmpty {
                    ContentUnavailableView("现在没人需要你守护", systemImage: "moon.zzz", description: Text("朋友回家时选了你，她就会出现在这里。"))
                }
                if !model.cards.isEmpty {
                    Section {
                        ForEach(model.cards) { c in
                            NavigationLink {
                                GuardDetailView(card: c)
                            } label: {
                                GuardCardRow(card: c)
                            }
                        }
                    } header: {
                        Text("她们回家时选了你")
                    } footer: {
                        Text("这里是你在守护的人，不是守护你的人。她们出事或联系不上时，你会马上收到提醒。守护你的人在「回家」页。")
                    }
                }
            }
            .navigationTitle("我守护的人")
            .refreshable { await model.refreshGuarding() }
            .task { await model.refreshGuarding() }
        }
    }
}

struct GuardCardRow: View {
    let card: GuardCard
    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { ctx in
            HStack(spacing: 12) {
                AvatarView(name: card.owner.displayName, url: card.owner.avatarUrl, size: 44,
                           tint: card.status == .alerting ? Theme.danger : Theme.monogram)
                VStack(alignment: .leading, spacing: 3) {
                    HStack { Text(card.owner.displayName).font(.pf(.headline)); TierBadge(tier: card.myTier) }
                    Text(Display.guardianLine(card, now: ctx.date))
                        .font(.pf(.subheadline))
                        .foregroundStyle(card.status == .alerting ? Theme.danger : .secondary)
                }
                Spacer()
                if card.canViewLocation { Image(systemName: "location.fill").foregroundStyle(Theme.accent) }
            }
        }
    }
}

/// 卡片详情：能看位置时显示实时地图（WebSocket），否则只显示状态；联系不上时可以进入联系流程
struct GuardDetailView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var realtime = RealtimeClient()
    let card: GuardCard
    @State private var position: MapCameraPosition = .automatic

    var body: some View {
        VStack(spacing: 0) {
            if card.canViewLocation && !realtime.revoked {
                Map(position: $position) {
                    if let p = realtime.point {
                        Annotation(card.owner.displayName, coordinate: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng)) {
                            AvatarView(name: card.owner.displayName, size: 36)
                                .overlay(Circle().stroke(.white, lineWidth: 2))
                        }
                        MapCircle(center: CLLocationCoordinate2D(latitude: p.lat, longitude: p.lng), radius: max(p.hAccM, 20))
                            .foregroundStyle(Theme.accent.opacity(0.12))
                    }
                }
                .onChange(of: realtime.point) { _, p in
                    if let p { position = .region(MKCoordinateRegion(center: .init(latitude: p.lat, longitude: p.lng), latitudinalMeters: 1200, longitudinalMeters: 1200)) }
                }
            } else {
                VStack(spacing: 10) {
                    Image(systemName: "location.slash").font(.largeTitle).foregroundStyle(.secondary)
                    Text(card.status == .ended ? "她已经结束了，看不到位置" : "她在回家路上，下次报平安前你看不到她的位置")
                        .foregroundStyle(.secondary)
                    Text("她没响应时会通知你").font(.pf(.footnote)).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text(Display.guardianLine(card, now: Date())).font(.pf(.headline))
                if let p = realtime.point {
                    Text("位置更新于 \(Display.hhmm(p.recordedAt))\(p.batteryPct.map { "，电量 \($0)%" } ?? "")")
                        .font(.pf(.footnote)).foregroundStyle(.secondary)
                }
                if card.status == .alerting, let inc = card.incident {
                    Button { Task { await model.openIncident(id: inc.id) } } label: {
                        Text("去联系她").font(.pf(.headline)).frame(maxWidth: .infinity)
                    }
                    .glassProminentButton(tint: Theme.danger)
                    .controlSize(.large)
                }
                if card.status != .ended {
                    Button("不再守护她", role: .destructive) {
                        Task {
                            if let g = try? await model.api.grantsToMe().first(where: { $0.owner.id == card.owner.id }) {
                                try? await model.api.revokeGrant(id: g.id)
                                await model.refreshGuarding()
                            }
                        }
                    }
                    .font(.pf(.footnote))
                }
            }
            .padding()
        }
        .navigationTitle(card.owner.displayName)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if card.canViewLocation { realtime.subscribe(ownerId: card.owner.id, api: model.api) } }
        .onDisappear { realtime.unsubscribe() }
    }
}

/**
 联系不上的常驻框（3.5）：“请尝试联系小林”，最后位置和时间、打电话给她、去微信找她、
 “已联系上，她安全”、“联系不上”。结果出来前关不掉，手机持续震动；音量键暂停 5 分钟。
 */
struct IncidentAlertView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.openURL) private var openURL
    let incident: IncidentView
    @State private var confirming = false
    @State private var via: ConfirmVia = .wechat
    @State private var snoozedUntil: Date?

    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 46))
                .foregroundStyle(Theme.danger)
                .padding(.top, 12)
            if incident.isSOS {
                Label { Text("求救").font(.pf(.subheadline, weight: .semibold)) } icon: { Image(systemName: "sos") }
                    .foregroundStyle(Theme.danger)
                    .padding(.horizontal, 12).padding(.vertical, 5)
                    .background(Theme.danger.opacity(0.12), in: Capsule())
            }
            Text(incident.isSOS ? "\(incident.owner.displayName)发起了求救" : "请尝试联系\(incident.owner.displayName)")
                .font(.pf(.title, weight: .semibold))
                .multilineTextAlignment(.center)
            Text(subtitle).font(.pf(.subheadline)).foregroundStyle(.secondary).multilineTextAlignment(.center)
            if let p = incident.lastLocation {
                Map(initialPosition: .region(MKCoordinateRegion(center: .init(latitude: p.lat, longitude: p.lng), latitudinalMeters: 800, longitudinalMeters: 800))) {
                    Marker(incident.owner.displayName, coordinate: .init(latitude: p.lat, longitude: p.lng))
                }
                .frame(height: 180)
                .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                .allowsHitTesting(false)
            }
            HStack(spacing: 10) {
                // 拨号和打开微信都要担保人自己点，不需要接运营商服务
                if let tel = incident.callURL {
                    Button {
                        openURL(tel)
                        Task { try? await model.api.markCalled(incidentId: incident.id) }
                    } label: {
                        Label { Text("打电话给她").font(.pf(.headline)) } icon: { Image(systemName: "phone.fill") }
                            .frame(maxWidth: .infinity)
                    }
                    .glassProminentButton()
                    .controlSize(.large)
                }
                Button { openURL(URL(string: "weixin://")!) } label: {
                    Label { Text("去微信找她").font(.pf(.headline)) } icon: { Image(systemName: "message.fill") }
                        .frame(maxWidth: .infinity)
                }
                .glassButton()
                .controlSize(.large)
            }
            Spacer(minLength: 0)
            Button { confirming = true } label: { Text("已联系上，她安全").font(.pf(.headline)).frame(maxWidth: .infinity) }
                .glassButton()
                .controlSize(.large)
            AsyncButton {
                _ = try await model.api.markUnreachable(incidentId: incident.id)
                AlarmPlayer.shared.start()
            } label: { Text("联系不上").font(.pf(.headline)).foregroundStyle(Theme.danger).frame(maxWidth: .infinity) }
            .glassButton()
            .controlSize(.large)
            Group {
                if let s = snoozedUntil, s > Date() {
                    Text("已静音到 \(Display.hhmm(s))，到时没结果会重新响").foregroundStyle(.secondary)
                } else {
                    Button("静音 5 分钟（也可以按音量键）") {
                        Task {
                            await model.snoozeAlert()
                            snoozedUntil = Date().addingTimeInterval(AlarmPlayer.snoozeDuration)
                        }
                    }
                }
            }
            .font(.pf(.footnote))
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemBackground))
        .sheet(isPresented: $confirming) {
            ConfirmSafeSheet(incident: incident)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
        }
        .task {
            // 别人确认了或她自己报了平安：框自动关掉
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(5))
                if let v = try? await model.api.incident(id: incident.id), !v.isOpen {
                    model.closeAlert()
                    await model.refreshGuarding()
                    return
                }
            }
        }
    }

    private var subtitle: String {
        var parts: [String] = []
        if let n = incident.lastUnreachableBy { parts.append("\(n)联系不上她") }
        if let p = incident.lastLocation {
            parts.append("最后位置 \(Display.hhmm(p.recordedAt))\(p.batteryPct.map { "，电量 \($0)%" } ?? "")")
        }
        if let h = incident.nearHomeAt { parts.append("\(Display.hhmm(h)) 已到家附近") }
        if parts.isEmpty { return incident.isSOS ? "她主动按了求救，请马上联系她" : "她 10 分钟没响应" }
        return parts.joined(separator: "\n")
    }
}

/// “已联系上，她安全”之后：怎么确认的 + 继续护航 / 暂停到明早 8:00 / 帮她结束（后两项只有常驻担保人有）
struct ConfirmSafeSheet: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let incident: IncidentView
    @State private var via: ConfirmVia = .wechat

    var body: some View {
        NavigationStack {
            Form {
                Section("怎么确认的") {
                    Picker("方式", selection: $via) {
                        ForEach(ConfirmVia.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.inline)
                    .labelsHidden()
                }
                Section {
                    choice("继续护航", detail: "签到从现在重新计时", .continue)
                    if incident.canPauseOrEnd {
                        choice("她在别处过夜，暂停到明早 8:00", detail: "暂停期间不签到、不上报位置，早上轻提醒她一句", .pause)
                        choice("帮她结束护航", detail: "其他担保人会收到一条不响铃的通知", .end)
                    }
                } footer: {
                    if !incident.canPauseOrEnd {
                        Text("临时担保人只能确认安全，不能暂停或结束她的护航。")
                    }
                }
            }
            .navigationTitle("已联系上")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func choice(_ title: String, detail: String, _ f: ConfirmFollowup) -> some View {
        AsyncButton {
            _ = try await model.api.confirmSafe(incidentId: incident.id, via: via, followup: f)
            dismiss()
            model.closeAlert()
            await model.refreshGuarding()
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).foregroundStyle(.primary)
                Text(detail).font(.pf(.caption)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
