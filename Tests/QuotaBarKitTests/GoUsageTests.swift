import XCTest
@testable import QuotaBarKit

final class GoUsageTests: XCTestCase {
    func json(_ s: String) -> Data { s.data(using: .utf8)! }

    func testThreeWindowsAndLimitingIsMax() throws {
        let usage = try decodeGoUsage(json("""
        {"usage":{"rolling":{"status":"ok","percent":85,"resetsAt":"2026-10-26T20:00:00Z"},
        "weekly":{"status":"ok","percent":30,"resetsAt":"2026-10-30T00:00:00Z"},
        "monthly":{"status":"ok","percent":60,"resetsAt":"2026-11-15T00:00:00Z"}}}
        """))
        XCTAssertEqual(usage.rolling?.percent, 85)
        XCTAssertEqual(usage.weekly?.percent, 30)
        XCTAssertEqual(usage.monthly?.percent, 60)
        let lim = try XCTUnwrap(usage.limiting)
        XCTAssertEqual(lim.label, "5h")
        XCTAssertEqual(lim.window.percent, 85)
        XCTAssertNotNil(lim.window.resetsAt)
    }

    func testHalfPercentIsNotAFraction() throws {
        let usage = try decodeGoUsage(json("""
        {"usage":{"weekly":{"status":"ok","percent":0.5,"resetsAt":"2026-10-30T00:00:00Z"}}}
        """))
        // 0.5 must stay 0.5% — a /100 normalizer would turn it into 0.005.
        XCTAssertEqual(usage.weekly?.percent ?? -1, 0.5, accuracy: 0.0001)
    }

    func testRateLimitedIsValidAndIncluded() throws {
        let usage = try decodeGoUsage(json("""
        {"usage":{"rolling":{"status":"rate-limited","percent":92,"resetsAt":"2026-10-26T20:00:00Z"},
        "weekly":{"status":"ok","percent":30,"resetsAt":"2026-10-30T00:00:00Z"}}}
        """))
        XCTAssertEqual(usage.rolling?.isRateLimited, true)
        let lim = try XCTUnwrap(usage.limiting)
        XCTAssertEqual(lim.window.percent, 92) // most-consumed wins, even when rate-limited
    }

    func testUnknownStatusWindowDroppedOthersPreserved() throws {
        let usage = try decodeGoUsage(json("""
        {"usage":{"rolling":{"status":"weird","percent":10,"resetsAt":"2026-10-26T20:00:00Z"},
        "weekly":{"status":"ok","percent":30,"resetsAt":"2026-10-30T00:00:00Z"}}}
        """))
        XCTAssertNil(usage.rolling)
        XCTAssertEqual(usage.weekly?.percent, 30)
    }

    func testMissingWindowIsPartialNotZero() throws {
        let usage = try decodeGoUsage(json("""
        {"usage":{"weekly":{"status":"ok","percent":25,"resetsAt":"2026-10-30T00:00:00Z"}}}
        """))
        XCTAssertNil(usage.rolling)
        XCTAssertNil(usage.monthly)
        XCTAssertEqual(usage.available.count, 1)
        XCTAssertEqual(usage.limiting?.label, "7d")
    }

    func testMalformedThrows() {
        XCTAssertThrowsError(try decodeGoUsage(json("{}")))
        XCTAssertThrowsError(try decodeGoUsage(json("{\"usage\":{}}")))
        XCTAssertThrowsError(try decodeGoUsage(json("not json")))
    }

    func testStatusTaxonomy() {
        XCTAssertNil(goStateForStatus(200))
        XCTAssertEqual(goStateForStatus(401), .authFailed)
        XCTAssertEqual(goStateForStatus(403), .subscriptionUnavailable)
        XCTAssertEqual(goStateForStatus(429), .rateLimitedHTTP)
        XCTAssertEqual(goStateForStatus(500), .providerDown)
        XCTAssertEqual(goStateForStatus(503), .providerDown)
        if case .unexpected = goStateForStatus(418) {} else { XCTFail("418 should be unexpected") }
    }

    func testResetText() {
        let now = Date()
        XCTAssertEqual(resetText(until: now.addingTimeInterval(30), now: now), "resets in 30s")
        XCTAssertEqual(resetText(until: now.addingTimeInterval(20 * 60), now: now), "resets in 20m")
        XCTAssertEqual(resetText(until: now.addingTimeInterval(2 * 3600 + 14 * 60), now: now), "resets in 2h 14m")
        XCTAssertEqual(resetText(until: now.addingTimeInterval(3 * 86400), now: now), "resets in 3d")
        XCTAssertNil(resetText(until: nil))
    }

    func testUsageColorThresholds() {
        XCTAssertEqual(usageColorName(for: 0), "green")
        XCTAssertEqual(usageColorName(for: 49.9), "green")
        XCTAssertEqual(usageColorName(for: 50), "yellow")
        XCTAssertEqual(usageColorName(for: 83), "orange")
        XCTAssertEqual(usageColorName(for: 90), "red")
        XCTAssertEqual(usageColorName(for: 100), "red")
    }

    func testEmptyUsageHasNoLimitingWindow() {
        let usage = GoUsage(rolling: nil, weekly: nil, monthly: nil)
        XCTAssertTrue(usage.available.isEmpty)
        XCTAssertNil(usage.limiting)
    }
}
