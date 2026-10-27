import XCTest
@testable import QuotaBarKit

final class CommandCodeTests: XCTestCase {
    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    private let creditsFixture = """
    {
      "credits": {"belowThreshold": false, "creditThreshold": 0, "monthlyCredits": 68.711166654,
                  "purchasedCredits": 0, "freeCredits": 0},
      "windowLimits": {
        "limited": true, "exceeded": null,
        "fiveHour": {"used": 1.288833346, "cap": 14, "exceeded": false, "resetAt": 1793118319125},
        "weekly": {"used": 1.288833346, "cap": 35, "exceeded": false, "resetAt": 1793705119125}
      },
      "sandboxAccess": true,
      "sandboxMinutes": {"usedMinutes": 0, "limitMinutes": 0, "overageUsd": 0, "resetAt": 1793491200000}
    }
    """

    private let subscriptionFixture = """
    {"success": true, "data": {
      "id": "sub_test", "status": "active", "userId": "user-123", "orgId": null,
      "priceId": "price_test", "quantity": 1, "cancelAtPeriodEnd": false,
      "currentPeriodStart": "2026-10-27T11:21:55.000Z",
      "currentPeriodEnd": "2026-11-27T11:21:55.000Z",
      "planId": "individual-goat", "renewalPending": null
    }}
    """

    func testDecodesCreditsAndWindows() throws {
        let credits = try CommandCode.decodeCredits(json(creditsFixture))
        XCTAssertEqual(credits.monthlyRemaining, 68.711166654, accuracy: 0.0001)
        XCTAssertEqual(credits.fiveHourCap, 14)
        XCTAssertEqual(credits.weeklyCap, 35)
        XCTAssertFalse(credits.fiveHourExceeded)

        let sub = try CommandCode.decodeSubscription(json(subscriptionFixture))
        let windows = CommandCode.windows(credits, subscription: sub)

        XCTAssertEqual(windows.count, 3)
        let five = try XCTUnwrap(windows.first { $0.id == "commandcode.5h" })
        XCTAssertEqual(five.percent, 9.2059, accuracy: 0.001)
        XCTAssertEqual(five.label, "5-hour")
        XCTAssertEqual(five.windowMinutes, 300)
        XCTAssertEqual(five.resetsAt, Date(timeIntervalSince1970: 1_793_118_319.125))

        let weekly = try XCTUnwrap(windows.first { $0.id == "commandcode.weekly" })
        XCTAssertEqual(weekly.percent, 3.6824, accuracy: 0.001)

        let monthly = try XCTUnwrap(windows.first { $0.id == "commandcode.monthly" })
        XCTAssertEqual(monthly.percent, 1.8412, accuracy: 0.001)
        XCTAssertEqual(monthly.resetsAt, sub.periodEnd)
        XCTAssertFalse(monthly.isLimited)
    }

    func testSubscriptionFactsUseRealBillingPeriod() throws {
        let credits = try CommandCode.decodeCredits(json(creditsFixture))
        let sub = try CommandCode.decodeSubscription(json(subscriptionFixture))
        XCTAssertEqual(sub.planId, "individual-goat")
        XCTAssertEqual(sub.status, "active")
        XCTAssertFalse(sub.cancelAtPeriodEnd)

        let facts = CommandCode.facts(credits, subscription: sub)
        XCTAssertEqual(facts.first, "68.7 of 70 credits left")
        let renewal = try XCTUnwrap(facts.last)
        XCTAssertTrue(renewal.hasPrefix("Renews "), renewal)
        XCTAssertTrue(renewal.contains("27"), renewal)
        XCTAssertEqual(CommandCode.planName(for: sub.planId), "GOAT")
    }

    func testCanceledSubscriptionCopy() throws {
        var sub = try CommandCode.decodeSubscription(json(subscriptionFixture))
        sub = CommandCodeSubscription(planId: sub.planId, status: "active", periodEnd: sub.periodEnd,
                                      cancelAtPeriodEnd: true, userId: sub.userId)
        XCTAssertEqual(CommandCode.renewalFact(sub).map { $0.hasPrefix("Ends ") }, true)
    }

    func testUnknownPlanStillShowsRemainingCredits() throws {
        let credits = try CommandCode.decodeCredits(json(creditsFixture))
        let windows = CommandCode.windows(credits, subscription: nil)
        XCTAssertEqual(windows.count, 2, "monthly needs a plan total")
        XCTAssertEqual(CommandCode.facts(credits, subscription: nil), ["68.7 credits left"])
    }

    func testExceededWindowIsMarked() throws {
        let data = json("""
        {"credits":{"monthlyCredits":10},
         "windowLimits":{"fiveHour":{"used":14,"cap":14,"exceeded":true,"resetAt":1793118319125},
                         "weekly":{"used":10,"cap":35,"exceeded":false,"resetAt":1793705119125}}}
        """)
        let credits = try CommandCode.decodeCredits(data)
        let five = try XCTUnwrap(CommandCode.windows(credits, subscription: nil).first)
        XCTAssertTrue(five.isLimited)
    }

    func testMalformedPayloadsThrow() {
        XCTAssertThrowsError(try CommandCode.decodeCredits(json("{}")))
        XCTAssertThrowsError(try CommandCode.decodeCredits(json("{\"credits\":{}}")))
        XCTAssertThrowsError(try CommandCode.decodeSubscription(json("{}")))
    }

    func testKeyDiscoveryPrefersEnvironmentAndReadsOpencodeConfig() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cc-key-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let config = dir.appendingPathComponent("opencode.json")
        try json("""
        {"providers":{"commandcode":{"settings":{"apiKey":"from-config"}},
                      "opencode-go":{"settings":{"apiKey":"other"}}}}
        """).write(to: config)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }

        XCTAssertEqual(CommandCode.discoverKey(environment: [:], configURLs: [config]), "from-config")
        XCTAssertEqual(CommandCode.discoverKey(environment: ["COMMANDCODE_API_KEY": "from-env"],
                                               configURLs: [config]), "from-env")
        XCTAssertNil(CommandCode.discoverKey(environment: ["COMMANDCODE_API_KEY": "{env:COMMANDCODE_API_KEY}"],
                                             configURLs: []))
    }
}
