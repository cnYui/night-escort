import EscortKit
import SwiftUI

/// 搜索：名字、拼音首字母、关系；选人直接进图谱小卡
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let onPick: (Connection) -> Void
    @State private var q = ""

    static func initials(_ s: String) -> String {
        let latin = s.applyingTransform(.toLatin, reverse: false)?.applyingTransform(.stripDiacritics, reverse: false) ?? s
        return latin.split(separator: " ").compactMap { $0.first.map(String.init) }.joined().lowercased()
    }

    var results: [Connection] {
        let k = q.trimmingCharacters(in: .whitespaces).lowercased()
        guard !k.isEmpty else { return model.connections }
        return model.connections.filter { c in
            c.shownName.lowercased().contains(k)
                || Self.initials(c.shownName).hasPrefix(k)
                || (c.relation ?? "").contains(k)
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section("常驻") { rows(results.filter { $0.guardsMe?.tier == .standing }) }
                Section("临时") { rows(results.filter { $0.guardsMe?.tier == .temporary }) }
                Section("仅连接") { rows(results.filter { $0.guardsMe == nil }) }
            }
            .searchable(text: $q, placement: .navigationBarDrawer(displayMode: .always), prompt: "名字、拼音首字母或关系")
            .navigationTitle("联系人")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("关闭") { dismiss() } } }
        }
    }

    @ViewBuilder
    private func rows(_ list: [Connection]) -> some View {
        ForEach(list) { c in
            Button {
                dismiss()
                onPick(c)
            } label: {
                HStack {
                    AvatarView(name: c.shownName, url: c.peer.avatarUrl, size: 36)
                    VStack(alignment: .leading) {
                        Text(c.shownName)
                        if let r = c.relation { Text(r).font(.pf(.caption)).foregroundStyle(.secondary) }
                    }
                    Spacer()
                    if let g = c.guardsMe { TierBadge(tier: g.tier) }
                }
            }
            .buttonStyle(.plain)
        }
    }
}

/// 点图谱头像浮出的小卡（3.8）：名字、等级、她现在能看什么；改级 / 移出担保人 / 解除连接
struct ContactCard: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let connection: Connection
    @State private var confirmDisconnect = 0
    @State private var changingToTemporary = false
    @State private var template = TemporaryTemplate.default

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        AvatarView(name: connection.shownName, url: connection.peer.avatarUrl, size: 56)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(connection.shownName).font(.pf(.title3, weight: .semibold))
                            if let g = connection.guardsMe {
                                HStack { TierBadge(tier: g.tier); Text(g.canSee).font(.pf(.footnote)).foregroundStyle(.secondary) }
                            } else {
                                Text("仅连接：不能被选进护航，看不到你的位置").font(.pf(.footnote)).foregroundStyle(.secondary)
                            }
                            if connection.iGuard != nil {
                                Text("你也在守护她").font(.pf(.caption)).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
                if let g = connection.guardsMe {
                    Section {
                        if g.tier == .standing {
                            Button("改为临时") { changingToTemporary = true }
                        } else {
                            AsyncButton {
                                _ = try await model.api.changeTier(grantId: g.grantId, to: .standing)
                                await finish()
                            } label: { Text("改为常驻") }
                        }
                        AsyncButton {
                            try await model.api.revokeGrant(id: g.grantId)
                            await finish()
                        } label: { Text("移出担保人").foregroundStyle(Theme.danger) }
                    } footer: {
                        Text("移出只影响“她守护我”，你仍然是她的担保人，除非她也移出你。")
                    }
                } else {
                    Section {
                        AsyncButton {
                            _ = try await model.api.createGrant(guardianId: connection.peer.id, tier: .standing)
                            await finish()
                        } label: { Text("让她长期守护我") }
                    }
                }
                Section {
                    Button(confirmDisconnect == 0 ? "解除连接" : "再点一次确认解除") {
                        if confirmDisconnect == 0 { confirmDisconnect = 1; return }
                        Task {
                            try? await model.api.removeConnection(peerId: connection.peer.id)
                            await finish()
                        }
                    }
                    .foregroundStyle(Theme.danger)
                } footer: {
                    Text("解除后双方的守护一起作废，两边图谱都会移除。")
                }
            }
            .navigationTitle("联系人")
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $changingToTemporary) {
                NavigationStack {
                    TemporaryPermissionForm(name: connection.shownName, template: $template)
                        .toolbar {
                            ToolbarItem(placement: .confirmationAction) {
                                AsyncButton {
                                    if let g = connection.guardsMe {
                                        _ = try await model.api.changeTier(grantId: g.grantId, to: .temporary, template: template)
                                    }
                                    changingToTemporary = false
                                    await finish()
                                } label: { Text("确定") }
                            }
                        }
                }
                .environmentObject(model)
            }
        }
    }

    private func finish() async {
        await model.refreshAll()
        dismiss()
    }
}

/// 临时权限卡（3.3）：三行，每行都已经选好保守的默认值
struct TemporaryPermissionForm: View {
    let name: String
    @Binding var template: TemporaryTemplate

    var body: some View {
        Form {
            Section("什么时候失效") {
                Picker("失效", selection: $template.expires) {
                    ForEach(TempExpiry.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("\(name)能看到你的位置吗") {
                Picker("位置", selection: $template.locationScope) {
                    Text("只在你没响应时").tag(LocationScope.alertOnly)
                    Text("护航全程").tag(LocationScope.live)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section("失效后") {
                Picker("失效后", selection: $template.onExpire) {
                    Text("自动解除连接").tag(OnExpire.remove)
                    Text("保留为联系人").tag(OnExpire.keep)
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Section {
                Text(Display.temporarySummary(name: name, template: template))
                    .font(.pf(.footnote))
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle("今晚临时一起的人")
        .navigationBarTitleDisplayMode(.inline)
    }
}
