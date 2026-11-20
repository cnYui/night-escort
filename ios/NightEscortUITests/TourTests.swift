import EscortKit
import XCTest

/**
 录「使用视频」用的双机演示：两台 iPhone 模拟器同时跑，连同一个真正的后端，按人看得清的节奏操作。
 - testXiaolin：小林（回家的人）。注册、加阿珂和妈妈为好友、选她们守着出发、报平安、漏报、求救、结束。
 - testAke：阿珂（守护小林的人）。登录后等小林加她，小林漏报和求救时在自己手机上收到提醒框，点「已联系上，她安全」。
 妈妈只用接口扮演（第三个人，收到提醒后标记“已看到”）。

 两个测试必须同时在两台模拟器上跑，由 ios/scripts/record-tour.sh 启动并录屏。
 没有 NE_TOUR_RUN（4 位数字，两边一样）时直接跳过，所以平常跑 NightEscortUITests 不受影响。
 */
@MainActor
final class TourTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment
    private var base: URL { URL(string: env["NE_API_BASE_URL"] ?? "http://localhost:8090")! }
    private var code: String { env["NE_SMS_TEST_CODE"] ?? "246810" }
    private var run: String { env["NE_TOUR_RUN"] ?? "" }
    /// 节奏倍数：1 = 正常，0.3 = 快速试跑
    private var pace: Double { Double(env["NE_TOUR_PACE"] ?? "") ?? 1 }
    private var app: XCUIApplication!

    private var xiaolinPhone: String { "199000\(run)1" }
    private var akePhone: String { "199000\(run)2" }
    private var momPhone: String { "199000\(run)3" }
    private let password = "night2026"

    override func setUp() async throws {
        try XCTSkipIf(run.count != 4, "只在 record-tour.sh 里跑（要 NE_TOUR_RUN）")
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [
            "-apiBaseURL", base.absoluteString,
            "-uiTestReset", UUID().uuidString,
            "-locationNoteShown", "YES",
            "-AppleLanguages", "(zh-Hans)",
            "-AppleLocale", "zh_CN",
        ]
        addUIInterruptionMonitor(withDescription: "系统权限") { alert in
            for label in ["允许", "Allow", "使用 App 时允许", "使用App时允许", "Allow While Using App"] where alert.buttons[label].exists {
                alert.buttons[label].tap()
                return true
            }
            return false
        }
    }

    // MARK: 小林

    func testXiaolin() async throws {
        // 阿珂、妈妈的账号先用接口建好；阿珂那台手机等账号出现后自己登录
        let ake = TourPeer(base: base, code: code, name: "阿珂")
        let mom = TourPeer(base: base, code: code, name: "妈妈")
        try await ake.signup(phone: akePhone, password: password)
        try await mom.signup(phone: momPhone, password: password)

        // 1. 注册
        app.launch()
        let phoneField = app.textFields["手机号"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 30), "没看到登录页")
        await pause(3)
        phoneField.tap()
        phoneField.typeText(xiaolinPhone)
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", "我已阅读并同意")).firstMatch.tap()
        await pause(0.8)
        app.buttons["获取验证码"].tap()
        let codeField = app.textFields["6 位验证码"]
        codeField.tap()
        codeField.typeText(code)
        await pause(0.8)
        app.buttons.matching(NSPredicate(format: "label == %@", "登录")).firstMatch.tap()

        let pwd = app.secureTextFields["至少 8 位，含字母和数字"]
        XCTAssertTrue(pwd.waitForExistence(timeout: 20), "新号码没进入设置密码")
        await pause(1)
        pwd.tap()
        pwd.typeText(password)
        let nameField = app.textFields["别人图谱里看到的名字"]
        nameField.tap()
        nameField.typeText("小林")
        await pause(1.5)
        app.buttons["完成"].tap()
        XCTAssertTrue(app.staticTexts["谁在守护我"].waitForExistence(timeout: 20), "注册后没进首页")
        poke()
        await pause(2.5)

        // 2. 阿珂、妈妈发来邀请链接，点开加为好友
        for peer in [ake, mom] {
            let invite = try await peer.api.createInvite(kind: .standing)
            XCUIDevice.shared.system.open(URL(string: "\(InviteLink.appScheme)://i/\(invite.token)")!)
            let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            for label in ["打开", "Open"] where springboard.buttons[label].waitForExistence(timeout: 2) {
                springboard.buttons[label].tap(); break
            }
            let add = app.buttons["加为好友"]
            XCTAssertTrue(add.waitForExistence(timeout: 15), "点\(peer.name)的邀请链接没弹出名片")
            await pause(3)
            add.tap()
            try await waitUntil("\(peer.name)那边看到互相守护") {
                let c = try await peer.api.connections().first { $0.peer.displayName == "小林" }
                return c?.guardsMe != nil && c?.iGuard != nil
            }
            await pause(2)
        }
        let me = try await ake.api.connections().first { $0.peer.displayName == "小林" }!.peer

        // 3. 点气泡选妈妈和阿珂，我要回家了
        for name in ["妈妈", "阿珂"] {
            let bubble = labeled(name)
            XCTAssertTrue(bubble.waitForExistence(timeout: 20), "首页没出现\(name)的气泡")
            bubble.tap()
            await pause(1.2)
        }
        let goHome = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "我要回家了")).firstMatch
        XCTAssertTrue(goHome.waitForExistence(timeout: 5), "选了人没出现「我要回家了」")
        await pause(2)
        goHome.tap()
        let depart = app.buttons["出发"]
        XCTAssertTrue(depart.waitForExistence(timeout: 10))
        try await waitUntil("「出发」可以点", timeout: 60) { depart.isEnabled }
        await pause(3)
        depart.tap()
        poke()
        XCTAssertTrue(app.buttons["我没事"].waitForExistence(timeout: 15), "出发后没进入回家路上")
        try await waitUntil("阿珂的守护页里出现小林") {
            try await ake.api.guarding().contains { $0.owner.id == me.id && $0.status == .active }
        }
        await pause(6)

        // 4. 报平安
        app.buttons["我没事"].tap()
        try await waitUntil("报平安后下次时间往后推") {
            let card = try await ake.api.guarding().first { $0.owner.id == me.id }
            return (card?.nextDueAt ?? .distantPast) > Date().addingTimeInterval(14 * 60)
        }
        await pause(4)

        // 5. 漏报：先拨到报平安时间刚过（只提醒她自己），再过 10 分钟还没回应才通知妈妈和阿珂
        let dev = Dev(base: base)
        let due = try await ake.api.guarding().first { $0.owner.id == me.id }?.nextDueAt
        let left = try await dev.minutes(until: try XCTUnwrap(due))
        try await dev.advance(minutes: left + 1)
        await pause(5)
        try await dev.advance(minutes: 11)
        XCTAssertTrue(app.staticTexts["需要你回应"].waitForExistence(timeout: 30), "漏报后 App 没变成需要回应")
        let missed = try await waitFor("妈妈收到联系不上") {
            try await mom.api.guarding().first { $0.owner.id == me.id && $0.status == .alerting }?.incident
        }
        await pause(3)
        _ = try? await mom.api.markSeen(incidentId: missed.id)
        // 阿珂在她的手机上点「已联系上，她安全」
        XCTAssertTrue(app.staticTexts["回家路上"].waitForExistence(timeout: 240), "阿珂确认安全后没回到回家路上")
        await pause(4)

        // 6. 一键求救：长按
        let sos = labeled("紧急求救")
        XCTAssertTrue(sos.waitForExistence(timeout: 10))
        await pause(1)
        sos.press(forDuration: 2.6)
        XCTAssertTrue(app.staticTexts["已发出求救"].waitForExistence(timeout: 20), "长按后没发出求救")
        let sosInc = try await waitFor("妈妈收到求救") {
            try await mom.api.guarding().first { $0.owner.id == me.id && $0.incident?.kind == .sos }?.incident
        }
        await pause(2)
        _ = try? await mom.api.markSeen(incidentId: sosInc.id)
        XCTAssertTrue(app.staticTexts["回家路上"].waitForExistence(timeout: 240), "阿珂确认安全后没回到回家路上")
        await pause(4)

        // 7. 到家，结束
        app.buttons["结束"].tap()
        await pause(1.5)
        app.buttons["结束，不用再守了"].tap()
        try await waitUntil("这次回家结束了") { !app.buttons["我没事"].exists }
        await pause(5)
    }

    // MARK: 阿珂

    func testAke() async throws {
        app.launch()
        let phoneField = app.textFields["手机号"]
        XCTAssertTrue(phoneField.waitForExistence(timeout: 30), "没看到登录页")
        // 等小林那边把阿珂的账号建好
        let probe = TourPeer(base: base, code: code, name: "阿珂")
        try await waitUntil("阿珂的账号建好", timeout: 300) {
            try await probe.login(phone: akePhone, password: password)
        }
        await pause(1)

        // 1. 验证码登录（老账号直接进首页）
        phoneField.tap()
        phoneField.typeText(akePhone)
        app.switches.matching(NSPredicate(format: "label CONTAINS %@", "我已阅读并同意")).firstMatch.tap()
        app.buttons["获取验证码"].tap()
        let codeField = app.textFields["6 位验证码"]
        codeField.tap()
        codeField.typeText(code)
        app.buttons.matching(NSPredicate(format: "label == %@", "登录")).firstMatch.tap()
        XCTAssertTrue(app.staticTexts["谁在守护我"].waitForExistence(timeout: 30), "阿珂登录后没进首页")
        poke()

        // 2. 小林加了她、出发后，去「我守护的人」看着
        try await waitUntil("小林出发，选了阿珂", timeout: 400) {
            try await probe.api.guarding().contains { $0.owner.displayName == "小林" && $0.status == .active }
        }
        await pause(1.5)
        app.tabBars.buttons["我守护的人"].tap()
        XCTAssertTrue(labeled("小林").waitForExistence(timeout: 30), "我守护的人里没出现小林")

        // 3. 小林漏报：手机弹出「请尝试联系小林」，打过电话后确认安全
        try await confirmSafe(what: "漏报提醒")
        // 4. 小林求救：再弹一次，同样处理
        try await confirmSafe(what: "求救提醒")

        // 5. 小林到家结束
        try await waitUntil("小林结束了这次回家", timeout: 240) {
            let cards = try await probe.api.guarding()
            return !cards.contains { $0.owner.displayName == "小林" && $0.status != .ended }
        }
        await pause(5)
    }

    private func confirmSafe(what: String) async throws {
        let safe = app.buttons["已联系上，她安全"]
        XCTAssertTrue(safe.waitForExistence(timeout: 400), "阿珂没收到\(what)")
        await pause(5)
        safe.tap()
        let phone = labeled("电话")
        if phone.waitForExistence(timeout: 5) {
            await pause(1)
            phone.tap()
        }
        await pause(1.5)
        let keep = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "继续护航")).firstMatch
        XCTAssertTrue(keep.waitForExistence(timeout: 20))
        keep.tap()
        try await waitUntil("提醒框收起", timeout: 30) { !safe.exists }
        await pause(3)
    }

    // MARK: 工具

    private func pause(_ seconds: Double) async {
        try? await Task.sleep(for: .milliseconds(Int(seconds * pace * 1000)))
    }

    private func labeled(_ label: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

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

    private func waitFor<T>(_ what: String, timeout: TimeInterval = 30, _ get: () async throws -> T?) async throws -> T {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if let v = try? await get() { return v }
            try await Task.sleep(for: .milliseconds(500))
        }
        XCTFail("等了 \(Int(timeout)) 秒：\(what)")
        throw CancellationError()
    }
}

/// 演示里只用接口出场的人（阿珂的账号、妈妈），名字不带随机后缀
final class TourPeer {
    let api: APIClient
    let code: String
    let name: String

    init(base: URL, code: String, name: String) {
        api = APIClient(baseURL: base, tokens: MemoryTokenStore(), device: DeviceInfo(kind: .iphone, appVersion: "tour"))
        self.code = code
        self.name = name
    }

    func signup(phone: String, password: String) async throws {
        try await api.sendSmsCode(phone: phone)
        let first = try await api.loginWithSms(phone: phone, code: code)
        let done = try await api.signup(ticket: first.signupTicket ?? "", password: password, displayName: name)
        XCTAssertEqual(done.status, .ok)
        try await api.updateDevice(.init(appVersion: "tour", notifAllowed: true, opened: true))
    }

    /// 账号已经存在就登录成功（返回 true）
    func login(phone: String, password: String) async throws -> Bool {
        let r = try await api.loginWithPassword(phone: phone, password: password)
        return r.status == .ok
    }
}
