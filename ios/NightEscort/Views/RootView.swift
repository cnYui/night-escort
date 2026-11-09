import EscortKit
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            if model.signedIn {
                MainTabs()
            } else {
                LoginView()
            }
        }
        .tint(Theme.accent)
        // 担保人：联系不上的常驻框，结果出来前关不掉
        .fullScreenCover(item: $model.alertIncident) { inc in
            IncidentAlertView(incident: inc)
                .environmentObject(model)
                .interactiveDismissDisabled()
        }
        // 扫码、点链接、粘贴板里认出来的邀请：弹“成为担保人”。没登录先不弹，登录后接着弹
        .sheet(item: Binding(get: { model.signedIn ? model.pendingInvite.map(IdentifiedRef.init) : nil }, set: { model.pendingInvite = $0?.ref })) { item in
            ConfirmInviteView(ref: item.ref)
                .environmentObject(model)
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .safeAreaInset(edge: .top) {
            if !model.signedIn, model.pendingInvite != nil {
                Label("有人邀请你当担保人，登录后继续", systemImage: "person.badge.shield.checkmark")
                    .font(.pf(.subheadline, weight: .medium))
                    .foregroundStyle(Theme.accent)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .glassBackground(in: Capsule())
                    .padding(.top, 4)
            }
        }
        #if DEBUG
        .sheet(isPresented: .constant(DemoMode.scene == "invite")) {
            NavigationStack { InviteView(kind: .standing, template: nil) }
                .environmentObject(model)
        }
        #endif
        // 求救没发出去：给一个直接拨 110 的出口
        .alert("求救没发出去", isPresented: Binding(get: { model.sosError != nil }, set: { if !$0 { model.sosError = nil } })) {
            Button("拨打 110") {
                if let u = URL(string: "tel://110") { UIApplication.shared.open(u) }
            }
            Button("好", role: .cancel) {}
        } message: {
            Text(model.sosError ?? "")
        }
        // 到家提醒
        .alert("检测到你已经到\(model.homePrompt ?? "家")", isPresented: Binding(get: { model.homePrompt != nil }, set: { if !$0 { model.homePrompt = nil } })) {
            Button("到家了，结束护航") { Task { await model.answerHome(arrived: true) } }
            Button("还没，继续", role: .cancel) { Task { await model.answerHome(arrived: false) } }
        } message: {
            Text("安全到家了吗？")
        }
        .overlay(alignment: .top) {
            if let t = model.toast {
                ToastView(text: t)
                    .onTapGesture { model.toast = nil }
                    .task {
                        try? await Task.sleep(for: .seconds(3))
                        model.toast = nil
                    }
            }
        }
    }
}

struct IdentifiedRef: Identifiable {
    let ref: InviteRef
    var id: String { ref.token }
}

struct MainTabs: View {
    @EnvironmentObject var model: AppModel
    @State private var tab = MainTabs.initialTab

    var body: some View {
        TabView(selection: $tab) {
            HomeView()
                .tabItem { Label("首页", systemImage: "person.3.fill") }
                .tag(0)
            GuardingView()
                .tabItem { Label("守护", systemImage: "shield.lefthalf.filled") }
                .badge(model.cards.filter { $0.status == .alerting }.count)
                .tag(1)
            SettingsView()
                .tabItem { Label("我的", systemImage: "person.crop.circle") }
                .tag(2)
        }
    }

    private static var initialTab: Int {
        #if DEBUG
        switch DemoMode.scene {
        case "guarding", "incident": return 1
        case "me": return 2
        default: return 0
        }
        #else
        return 0
        #endif
    }
}
