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
        // 扫码或点链接进来的邀请
        .sheet(item: Binding(get: { model.pendingInvite.map(IdentifiedRef.init) }, set: { model.pendingInvite = $0?.ref })) { item in
            ConfirmInviteView(ref: item.ref)
                .environmentObject(model)
        }
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
    var id: String {
        switch ref {
        case .token(let t): return "t:\(t)"
        case .code(let c): return "c:\(c)"
        }
    }
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
