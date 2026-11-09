import EscortKit
import XCTest

/**
 第一版 MVP 端到端：模拟器里的 App 扮演「我」，测试进程里用 EscortKit 的 APIClient 扮演好友「阿珂」，
 两边连同一个真正跑着的后端和 PostgreSQL。每一步截图存进测试结果。

 后端要这样启动（ios/scripts/mvp-e2e.sh 会做）：
   SMS_TEST_NUMBERS=+86199000* SMS_TEST_CODE=246810 DEV_TOOLS=true PORT=8090
 运行时用 TEST_RUNNER_NE_API_BASE_URL 指定后端地址，默认 http://localhost:8090。
 */
@MainActor
final class MVPFlowTests: XCTestCase {
    private let base = URL(string: ProcessInfo.processInfo.environment["NE_API_BASE_URL"] ?? "http://localhost:8090")!
    private let code = ProcessInfo.processInfo.environment["NE_SMS_TEST_CODE"] ?? "246810"
    private var app: XCUIApplication!
    private var step = 0

    override func setUp() async throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-apiBaseURL", base.absoluteString,
            "-uiTestReset", "YES",
            "-locationNoteShown", "YES",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        // 系统权限弹窗（通知、定位）：一律允许
        addUIInterruptionMonitor(withDescription: "系统权限") { alert in
            for label in ["允许", "Allow", "使用 App 时允许", "使用App时允许", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    func testMVPWalkthrough() async throws {
        let run = String(format: "%04d", Int(Date().timeIntervalSince1970) % 10000)
        let myPhone = "199000\(run)1"
        let myName = "小林\(run)"
        let ke = Friend(base: base, code: code)
        try await ke.signup(phone: "199000\(run)2", name: "阿珂\(run)")

        // 1. 注册登录
        app.launch()
        let phoneField = app.textFields["手机号"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 20), "没看到登录页")
        shot("登录页")
        phoneField.tap()
        phoneField.typeText(myPhone)
        // 协议勾选是 Toggle，界面层级里是 Switch
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", "我已阅读并同意")).firstMatch.tap()
        app.buttons["获取验证码"].tap()
        let codeField = app.textFields["6 位验证码"]
        codeField.tap()
        codeField.typeText(code)
        app.buttons.matching(NSPredicate(format: "label == %@", "登录")).firstMatch.tap()

        let pwd = app.secureTextFields["至少 8 位，含字母和数字"]
        XCTAssertTrue(pwd.waitForExistence(timeout: 15), "新号码没进入设置密码")
        pwd.tap()
        pwd.typeText("night2026")
        let nameField = app.textFields["别人图谱里看到的名字"]
        nameField.tap()
        nameField.typeText(myName)
        shot("设置密码和昵称")
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["谁在守护我"].waitForExistence(timeout: 20), "注册后没进首页")
        poke()
        shot("首页（还没有好友）")

        // 2. 好友发来邀请链接，点开后加为好友（长期互相守护）
        let invite = try await ke.api.createInvite(kind: .standing)
        app.open(URL(string: "\(InviteLink.appScheme)://i/\(invite.token)")!)
        let add = app.buttons["加为好友"]
        XCTAssertTrue(add.waitForExistence(timeout: 15), "点邀请链接没弹出名片")
        shot("好友名片")
        add.tap()
        try await waitUntil("阿珂那边看到互相守护") {
            let c = try await ke.api.connections().first { $0.peer.displayName == myName }
            return c?.guardsMe != nil && c?.iGuard != nil
        }
        let me = try await ke.api.connections().first { $0.peer.displayName == myName }!.peer

        // 3. 在气泡里选阿珂，出发
        let bubble = labeled(ke.name)
        XCTAssertTrue(bubble.waitForExistence(timeout: 15), "首页没出现阿珂的气泡")
        bubble.tap()
        let goHome = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我要回家了")).firstMatch
        XCTAssertTrue(goHome.waitForExistence(timeout: 5), "选了人没出现「我要回家了」")
        shot("选好守着我的人")
        goHome.tap()
        let depart = app.buttons["出发"]
        XCTAssertTrue(depart.waitForExistence(timeout: 10))
        try await waitUntil("「出发」可以点") { depart.isEnabled }
        shot("开始页")
        depart.tap()
        poke()
        XCTAssertTrue(app.buttons["我没事"].waitForExistence(timeout: 15), "出发后没进入回家路上")
        shot("回家路上")
        try await waitUntil("阿珂的守护页里出现我") {
            try await ke.api.guarding().contains { $0.owner.id == me.id && $0.status == .active }
        }

        // 4. 报平安
        app.buttons["我没事"].tap()
        try await waitUntil("报平安后阿珂那边的下次时间往后推") {
            let card = try await ke.api.guarding().first { $0.owner.id == me.id }
            return (card?.nextDueAt ?? .distantPast) > Date().addingTimeInterval(14 * 60)
        }

        // 5. 漏报：时钟往前拨 28 分钟（15 分钟到点，再 10 分钟没回应才通知守护人），App 开着就该变成“需要你回应”，阿珂那边出现联系不上
        try await Dev(base: base).advance(minutes: 28)
        XCTAssertTrue(app.staticTexts["需要你回应"].waitForExistence(timeout: 20), "漏报后 App 没变成需要回应")
        shot("漏报后")
        let missed = try await waitFor("阿珂收到联系不上") {
            try await ke.api.guarding().first { $0.owner.id == me.id && $0.status == .alerting }?.incident
        }
        _ = try await ke.api.markSeen(incidentId: missed.id)
        _ = try await ke.api.confirmSafe(incidentId: missed.id, via: .phone, followup: .continue)
        XCTAssertTrue(app.staticTexts["回家路上"].waitForExistence(timeout: 20), "阿珂确认安全后 App 没回到回家路上")
        shot("阿珂确认安全后")

        // 6. 一键求救：长按 2 秒
        let sos = labeled("紧急求救")
        XCTAssertTrue(sos.waitForExistence(timeout: 5))
        sos.press(forDuration: 2.6)
        XCTAssertTrue(app.staticTexts["已发出求救"].waitForExistence(timeout: 15), "长按后没发出求救")
        shot("已发出求救")
        let sosInc = try await waitFor("阿珂收到求救") {
            try await ke.api.guarding().first { $0.owner.id == me.id && $0.incident?.kind == .sos }?.incident
        }
        _ = try await ke.api.markSeen(incidentId: sosInc.id)
        _ = try await ke.api.confirmSafe(incidentId: sosInc.id, via: .phone, followup: .continue)
        XCTAssertTrue(app.staticTexts["回家路上"].waitForExistence(timeout: 20))

        // 7. 结束我的这次回家
        app.buttons["结束"].tap()
        app.buttons["结束，不用再守了"].tap()
        try await waitUntil("我的回家结束了") { !app.buttons["我没事"].exists }
        shot("结束后回到首页")

        // 8. 反过来：阿珂回家选了我，她漏报，开着 App 的我直接弹出联系不上的框
        let opts = try await ke.api.startOptions()
        XCTAssertTrue(opts.candidates.contains { $0.id == me.id }, "阿珂开始页里选不到我")
        let keEscort = try await ke.api.startEscort(guardianIds: [me.id], intervalMin: 15, from: "phone")
        app.tabBars.buttons["我守护的人"].tap()
        XCTAssertTrue(labeled(ke.name).waitForExistence(timeout: 20), "我守护的人里没出现阿珂")
        shot("我守护的人")
        try await Dev(base: base).advance(minutes: 28)
        let safe = app.buttons["已联系上，她安全"]
        XCTAssertTrue(safe.waitForExistence(timeout: 25), "阿珂漏报后我这边没弹出提醒框")
        shot("请尝试联系阿珂")
        safe.tap()
        let keep = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "继续护航")).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 10))
        shot("确认安全")
        keep.tap()
        try await waitUntil("提醒框收起") { !safe.exists }
        try await waitUntil("阿珂回到回家路上") { try await ke.api.currentEscort()?.status == .active }
        _ = try await ke.api.endEscort(escortId: keEscort.id)
        shot("全部走完")
    }

    // MARK: 工具

    /// 按显示的文字找元素，不管它是按钮、文字还是气泡
    private func labeled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    private func shot(_ name: String) {
        step += 1
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = String(format: "%02d-%@", step, name)
        a.lifetime = .keepAlways
        add(a)
    }

    /// 让系统权限弹窗的监听生效：监听只在和 App 交互时触发
    private func poke() {
        app.swipeUp(velocity: .slow)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 20, _ cond: () async throws -> Bool) async throws {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if (try? await cond()) == true { return }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("等了 \(Int(timeout)) 秒：\(what)")
        throw CancellationError()
    }

    private func waitFor<T>(_ what: String, timeout: TimeInterval = 20, _ get: () async throws -> T?) async throws -> T {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = try? await get() { return v }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("等了 \(Int(timeout)) 秒：\(what)")
        throw CancellationError()
    }
}

/// 测试进程里的好友：直接调后端接口
final class Friend {
    let api: APIClient
    let code: String
    private(set) var name = ""

    init(base: URL, code: String) {
        api = APIClient(baseURL: base, tokens: MemoryTokenStore(), device: DeviceInfo(kind: .iphone, appVersion: "uitest"))
        self.code = code
    }

    func signup(phone: String, name: String) async throws {
        self.name = name
        try await api.sendSmsCode(phone: phone)
        let first = try await api.loginWithSms(phone: phone, code: code)
        let done = try await api.signup(ticket: first.signupTicket ?? "", password: "night2026", displayName: name)
        XCTAssertEqual(done.status, .ok)
        // 开了通知、刚打开过 App：开始页里才算“收得到通知”
        try await api.updateDevice(.init(appVersion: "uitest", notifAllowed: true, opened: true))
    }
}

/// 联调接口：拨时钟
struct Dev {
    let base: URL

    func advance(minutes: Int) async throws {
        var req = URLRequest(url: base.appendingPathComponent("/v1/dev/clock/advance"))
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: ["minutes": minutes])
        let (_, res) = try await URLSession.shared.data(for: req)
        guard (res as? HTTPURLResponse)?.statusCode == 200 else {
            throw NSError(domain: "dev", code: 1, userInfo: [NSLocalizedDescriptionKey: "拨时钟失败，后端要带 DEV_TOOLS=true 启动"])
        }
    }
}
