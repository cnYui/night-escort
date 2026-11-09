import XCTest
@testable import EscortKit
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class HomeDetectorTests: XCTestCase {
    let home = HomePlace(name: "家", lat: 31.2304, lng: 121.4737, radiusM: 150)
    let t0 = Date(timeIntervalSince1970: 1_793_800_000)

    func fix(_ dLat: Double, _ minutes: Double, acc: Double = 20) -> Fix {
        Fix(lat: 31.2304 + dLat, lng: 121.4737, accuracyM: acc, at: t0.addingTimeInterval(minutes * 60))
    }

    func testNeedsTwoConsecutivePointsInside() {
        var d = HomeDetector(places: [home])
        XCTAssertEqual(d.feed(fix(0.0005, 0)), .none) // 约 55 米，第一个点
        XCTAssertEqual(d.feed(fix(0.0003, 0.5)), .ask(place: "家"))
    }

    func testAccuracyWorseThanRadiusDoesNotCount() {
        var d = HomeDetector(places: [home])
        XCTAssertEqual(d.feed(fix(0, 0, acc: 200)), .none)
        XCTAssertEqual(d.feed(fix(0, 1, acc: 200)), .none)
    }

    func testFarAwayNeverAsks() {
        var d = HomeDetector(places: [home])
        XCTAssertEqual(d.feed(fix(0.01, 0)), .none) // 约 1.1 公里
        XCTAssertEqual(d.feed(fix(0.01, 1)), .none)
    }

    func testIgnoredAsksAgainAfterFiveMinutesThenStops() {
        var d = HomeDetector(places: [home])
        _ = d.feed(fix(0, 0))
        XCTAssertEqual(d.feed(fix(0, 1)), .ask(place: "家"))
        XCTAssertEqual(d.feed(fix(0, 3)), .none)
        XCTAssertEqual(d.feed(fix(0, 6.5)), .ask(place: "家"))
        XCTAssertEqual(d.feed(fix(0, 12)), .none) // 问过两次就不再问，照常签到
        XCTAssertEqual(d.feed(fix(0, 30)), .none)
    }

    func testNotYetQuietsTwentyMinutesButLeavingAndComingBackAsksAgain() {
        var d = HomeDetector(places: [home])
        _ = d.feed(fix(0, 0))
        XCTAssertEqual(d.feed(fix(0, 1)), .ask(place: "家"))
        d.answeredNotYet(at: t0.addingTimeInterval(60))
        XCTAssertEqual(d.feed(fix(0, 10)), .none)
        XCTAssertEqual(d.feed(fix(0, 22)), .ask(place: "家"))
        d.answeredNotYet(at: t0.addingTimeInterval(22 * 60))
        // 离开再回来
        _ = d.feed(fix(0.01, 23))
        _ = d.feed(fix(0, 24))
        XCTAssertEqual(d.feed(fix(0, 24.5)), .ask(place: "家"))
    }

    func testTonightDestinationCounts() {
        let friend = HomePlace(name: "朋友家", lat: 31.3, lng: 121.5, radiusM: 100)
        var d = HomeDetector(places: [home], tonight: friend)
        _ = d.feed(Fix(lat: 31.3, lng: 121.5, accuracyM: 10, at: t0))
        XCTAssertEqual(d.feed(Fix(lat: 31.3, lng: 121.5, accuracyM: 10, at: t0.addingTimeInterval(30))), .ask(place: "朋友家"))
    }
}

final class SamplingPolicyTests: XCTestCase {
    func testPlans() {
        XCTAssertNil(SamplingPolicy.plan(status: nil, stage: nil, batteryPct: 80, stationaryFor: 0).minInterval)
        XCTAssertNil(SamplingPolicy.plan(status: .paused, stage: .waiting, batteryPct: 80, stationaryFor: 0).minInterval)
        XCTAssertEqual(SamplingPolicy.plan(status: .alerting, stage: .escalated, batteryPct: 3, stationaryFor: 0).minInterval, 10)
        XCTAssertEqual(SamplingPolicy.plan(status: .active, stage: .waiting, batteryPct: 10, stationaryFor: 0).minInterval, 120)
        XCTAssertEqual(SamplingPolicy.plan(status: .active, stage: .due, batteryPct: 80, stationaryFor: 600).uploadEvery, 0)
        XCTAssertEqual(SamplingPolicy.plan(status: .active, stage: .waiting, batteryPct: 80, stationaryFor: 200).minInterval, 180)
        let moving = SamplingPolicy.plan(status: .active, stage: .waiting, batteryPct: 80, stationaryFor: 0)
        XCTAssertEqual(moving.distanceFilterM, 50)
        XCTAssertEqual(moving.uploadEvery, 60)
    }

    func testShouldKeepByTimeOrDistance() {
        let plan = SamplingPolicy.plan(status: .active, stage: .waiting, batteryPct: 80, stationaryFor: 0)
        let t = Date()
        let a = Fix(lat: 31, lng: 121, accuracyM: 10, at: t)
        XCTAssertFalse(SamplingPolicy.shouldKeep(Fix(lat: 31, lng: 121, accuracyM: 10, at: t.addingTimeInterval(10)), last: a, plan: plan))
        XCTAssertTrue(SamplingPolicy.shouldKeep(Fix(lat: 31.001, lng: 121, accuracyM: 10, at: t.addingTimeInterval(10)), last: a, plan: plan))
        XCTAssertTrue(SamplingPolicy.shouldKeep(Fix(lat: 31, lng: 121, accuracyM: 10, at: t.addingTimeInterval(31)), last: a, plan: plan))
    }
}

final class PointQueueTests: XCTestCase {
    func p(_ i: Int) -> PointUpload {
        PointUpload(recordedAt: Date(timeIntervalSince1970: Double(i)), lat: 31, lng: 121, hAccM: 10, speedMps: nil, batteryPct: 50, source: "phone")
    }

    func testFailedBatchIsResentWithSameKey() {
        var q = PointQueue()
        q.append(p(1)); q.append(p(2))
        var n = 0
        let b1 = q.nextBatch { n += 1; return "k\(n)" }!
        q.append(p(3))
        let again = q.nextBatch { n += 1; return "k\(n)" }!
        XCTAssertEqual(b1, again) // 没确认成功就重发同一批
        q.markUploaded(b1, at: Date())
        let b2 = q.nextBatch { n += 1; return "k\(n)" }!
        XCTAssertEqual(b2.idempotencyKey, "k2")
        XCTAssertEqual(b2.points.count, 1)
    }

    func testDue() {
        var q = PointQueue()
        let now = Date()
        XCTAssertFalse(q.isDue(now: now, uploadEvery: 60))
        q.append(p(1))
        XCTAssertTrue(q.isDue(now: now, uploadEvery: 60))
        let b = q.nextBatch()!
        q.markUploaded(b, at: now)
        q.append(p(2))
        XCTAssertFalse(q.isDue(now: now.addingTimeInterval(30), uploadEvery: 60))
        XCTAssertTrue(q.isDue(now: now.addingTimeInterval(30), uploadEvery: 0))
    }
}

final class InviteLinkTests: XCTestCase {
    let hosts: Set<String> = ["ye.example.com"]

    func testParse() {
        XCTAssertEqual(InviteLink.parse("https://ye.example.com/i/AbC_123-xyz0", allowedHosts: hosts), .token("AbC_123-xyz0"))
        XCTAssertEqual(InviteLink.parse("anquanhuijia://i/AbC_123-xyz0", allowedHosts: hosts), .token("AbC_123-xyz0"))
        // 不再有 6 位邀请码
        XCTAssertNil(InviteLink.parse(" 482913 ", allowedHosts: hosts))
        XCTAssertNil(InviteLink.parse("https://evil.example.com/i/AbC_123-xyz0", allowedHosts: hosts))
        XCTAssertNil(InviteLink.parse("https://ye.example.com/x/AbC_123-xyz0", allowedHosts: hosts))
        XCTAssertNil(InviteLink.parse("anquanhuijia://x/AbC_123-xyz0", allowedHosts: hosts))
        XCTAssertNil(InviteLink.parse("WIFI:S:home;T:WPA;P:secret;;", allowedHosts: hosts))
    }

    func testFindLinkInPastedText() {
        let shared = InviteLink.shareText(inviterName: "小林", kind: .standing, url: "https://ye.example.com/i/AbC_123-xyz0")
        XCTAssertEqual(InviteLink.find(in: shared, allowedHosts: hosts), .token("AbC_123-xyz0"))
        // 链接前后紧挨着中文和标点
        XCTAssertEqual(InviteLink.find(in: "快点这个https://ye.example.com/i/AbC_123-xyz0。谢谢", allowedHosts: hosts), .token("AbC_123-xyz0"))
        XCTAssertEqual(InviteLink.find(in: "先看 https://other.com/a 再看 https://YE.example.com/i/AbC_123-xyz0", allowedHosts: hosts), .token("AbC_123-xyz0"))
        XCTAssertNil(InviteLink.find(in: "邀请码 482913", allowedHosts: hosts))
        XCTAssertNil(InviteLink.find(in: "https://evil.example.com/i/AbC_123-xyz0", allowedHosts: hosts))
    }
}

final class DisplayTests: XCTestCase {
    func testCountdown() {
        let now = Date()
        XCTAssertEqual(Display.countdown(to: now.addingTimeInterval(725), now: now), "12:05")
        XCTAssertEqual(Display.countdown(to: now.addingTimeInterval(3723), now: now), "1:02:03")
        XCTAssertEqual(Display.countdown(to: now.addingTimeInterval(-5), now: now), "00:00")
    }

    func testTemporarySummaryMatchesDesignDoc() {
        XCTAssertEqual(Display.temporarySummary(name: "小周", template: .default), "小周只会在你失联时收到通知和最后位置，你到家后她从你的列表里消失。")
    }
}

/// 假的网络层：按顺序返回预设响应，并记录请求
final class StubTransport: HTTPTransport, @unchecked Sendable {
    var responses: [(Int, String)]
    var requests: [URLRequest] = []
    init(_ responses: [(Int, String)]) { self.responses = responses }
    func send(_ request: URLRequest) async throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let (status, body) = responses.removeFirst()
        return (Data(body.utf8), HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!)
    }
}

final class APIClientTests: XCTestCase {
    let tokens = #"{"access_token":"new","refresh_token":"r2","access_expires_in":900,"device_id":"d1"}"#

    func testDecodesEscortFromServerJSON() async throws {
        let body = #"""
        {"escort":{"id":"e1","status":"active","stage":"waiting","interval_min":30,"started_at":"2026-11-04T15:52:00.000Z",
        "started_from":"watch","destination_label":null,"next_due_at":"2026-11-04T16:22:00.000Z","paused_until":null,
        "near_home_at":null,"ended_at":null,"end_reason":null,
        "guardians":[{"id":"g1","display_name":"妈妈","avatar_url":null,"tier":"standing","can_see":"全程看到位置","last_viewed_at":null}],
        "incident":null,"intervention":null}}
        """#
        let stub = StubTransport([(200, body)])
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: MemoryTokenStore(), device: .init(kind: .iphone), transport: stub)
        let e = try await api.currentEscort()
        XCTAssertEqual(e?.guardians.first?.displayName, "妈妈")
        XCTAssertEqual(e?.intervalMin, 30)
        XCTAssertNotNil(e?.nextDueAt)
    }

    func testRefreshesOnceOn401() async throws {
        let store = MemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "r1", accessExpiresIn: 900, deviceId: "d1"))
        let stub = StubTransport([
            (401, #"{"error":{"code":"unauthorized","message":"登录已过期"}}"#),
            (200, tokens),
            (200, #"{"cards":[]}"#),
        ])
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: store, device: .init(kind: .iphone), transport: stub)
        let cards = try await api.guarding()
        XCTAssertEqual(cards.count, 0)
        XCTAssertEqual(store.load()?.accessToken, "new")
        XCTAssertEqual(stub.requests.last?.value(forHTTPHeaderField: "authorization"), "Bearer new")
    }

    func testSignedOutWhenRefreshFails() async {
        let store = MemoryTokenStore(TokenPair(accessToken: "old", refreshToken: "r1", accessExpiresIn: 900, deviceId: "d1"))
        let stub = StubTransport([
            (401, #"{"error":{"code":"unauthorized","message":"登录已过期"}}"#),
            (401, #"{"error":{"code":"unauthorized","message":"登录已过期，请重新登录"}}"#),
        ])
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: store, device: .init(kind: .iphone), transport: stub)
        do {
            _ = try await api.guarding()
            XCTFail("应该失败")
        } catch let e as APIError {
            XCTAssertEqual(e.status, 401)
        } catch {
            XCTFail("\(error)")
        }
        XCTAssertNil(store.load())
    }

    func testServerErrorMessageSurfaces() async {
        let stub = StubTransport([(409, #"{"error":{"code":"guardians_not_ready","message":"选中的人都可能收不到通知"}}"#)])
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: MemoryTokenStore(), device: .init(kind: .iphone), transport: stub)
        do {
            _ = try await api.startEscort(guardianIds: ["g"], intervalMin: 30, from: "phone")
            XCTFail("应该失败")
        } catch let e as APIError {
            XCTAssertEqual(e.code, "guardians_not_ready")
            XCTAssertEqual(e.localizedDescription, "选中的人都可能收不到通知")
        } catch {
            XCTFail("\(error)")
        }
    }

    func testEncodesSnakeCaseBody() async throws {
        let stub = StubTransport([(200, #"{"id":"i1","kind":"temporary","token":"tok12345","code":"123456","url":"https://x/i/tok12345","expires_at":"2026-11-04T16:10:00.000Z","template":{"expires":"escort","location_scope":"alert_only","on_expire":"remove"}}"#)])
        let api = APIClient(baseURL: URL(string: "https://api.example.com")!, tokens: MemoryTokenStore(), device: .init(kind: .iphone), transport: stub)
        let inv = try await api.createInvite(kind: .temporary, template: .default)
        XCTAssertEqual(inv.template?.locationScope, .alertOnly)
        let sent = String(data: stub.requests[0].httpBody!, encoding: .utf8)!
        XCTAssertTrue(sent.contains(#""location_scope":"alert_only""#))
    }
}
