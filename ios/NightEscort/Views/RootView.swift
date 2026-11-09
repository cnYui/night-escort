import EscortKit
import SwiftUI
import UIKit

struct RootView: View {
    @EnvironmentObject var model: AppModel
    #if DEBUG
    @State private var demoPickPlace = false
    #endif

    /// 演示：地图选点直接当整页显示，用来分清是弹窗的问题还是地图本身的问题
    private static var demoPlacePage: Bool {
        #if DEBUG
        return DemoMode.scene == "pickplace-page"
        #else
        return false
        #endif
    }

    var body: some View {
        Group {
            if RootView.demoPlacePage {
                PlacePicker(title: "添加地点", initial: nil) { _ in }
            } else if model.signedIn {
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
        // 扫码、点链接、粘贴板里认出来的邀请：弹对方的名片（加好友）。没登录先不弹，登录后接着弹
        .sheet(item: Binding(get: { model.signedIn ? model.pendingInvite.map(IdentifiedRef.init) : nil }, set: { model.pendingInvite = $0?.ref })) { item in
            ConfirmInviteView(ref: item.ref)
                .environmentObject(model)
                // 直接全高：说明、关系、长期还是今晚临时和两个按钮一屏看全
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .safeAreaInset(edge: .top) {
            if !model.signedIn, model.pendingInvite != nil {
                Label("有人想加你为好友，登录后继续", systemImage: "person.badge.shield.checkmark")
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
            NavigationStack { MyCodeView() }
                .environmentObject(model)
        }
        // 地图选点：和「我的家」里点「添加地点」是同一个页面。界面出来以后再弹，启动那一刻就弹可能被系统丢掉
        .sheet(isPresented: $demoPickPlace) {
            PlacePicker(title: "添加地点", initial: nil) { _ in }
        }
        .task {
            if DemoMode.scene == "pickplace" {
                try? await Task.sleep(for: .seconds(1.5))
                demoPickPlace = true
            }
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
                .tabItem { Label("回家", systemImage: "house.fill") }
                .tag(0)
            GuardingView()
                .tabItem { Label("我守护的人", systemImage: "shield.lefthalf.filled") }
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
        case "me", "myhome", "pickplace", "mycode": return 2
        default: return 0
        }
        #else
        return 0
        #endif
    }
}
