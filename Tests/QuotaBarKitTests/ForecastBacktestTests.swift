import XCTest
@testable import QuotaBarKit

final class ForecastBacktestTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func cycle(reset: Date, from: Double, to: Double, minutes: Int = 300) -> [ForecastSample] {
        let start = reset.addingTimeInterval(-Double(minutes) * 60)
        let count = max(2, minutes / 5)
        return (0..<count).map { index in
            let at = start.addingTimeInterval(Double(index) * 300)
            let progress = Double(index) / Double(count - 1)
            return ForecastSample(
                at: at,
                percent: from + (to - from) * progress,
                resetsAt: reset,
                origin: .network
            )
        }
    }

    func testCrossingCycleYieldsTruePositives() {
        let group = ForecastBacktest.evaluate(
            provider: .codex, windowID: "codex.primary", windowMinutes: 300,
            samples: cycle(reset: now, from: 0, to: 100), now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 1)
        XCTAssertEqual(group.counts.crossingCycles, 1)
        XCTAssertEqual(group.counts.nonCrossingCycles, 0)
        XCTAssertGreaterThan(group.counts.truePositives, 0)
        XCTAssertEqual(group.counts.falsePositives, 0)
        XCTAssertEqual(group.status, .insufficientData)
    }

    func testNonCrossingCycleYieldsTrueNegatives() {
        let group = ForecastBacktest.evaluate(
            provider: .codex, windowID: "codex.primary", windowMinutes: 300,
            samples: cycle(reset: now, from: 0, to: 40), now: now
        )
        XCTAssertEqual(group.counts.nonCrossingCycles, 1)
        XCTAssertGreaterThan(group.counts.trueNegatives, 0)
        XCTAssertEqual(group.counts.crossingCycles, 0)
        XCTAssertEqual(group.status, .insufficientData)
    }

    func testIncompleteCycleIsCensoredNotNegative() {
        let reset = now
        let samples = cycle(reset: reset, from: 0, to: 20).filter {
            $0.at <= reset.addingTimeInterval(-60 * 60)
        }
        let group = ForecastBacktest.evaluate(
            provider: .codex, windowID: "codex.primary", windowMinutes: 300,
            samples: samples, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 0)
        XCTAssertEqual(group.counts.trueNegatives, 0)
        XCTAssertEqual(group.excluded.incompleteCycle, 1)
    }

    func testSeparateResetsStaySeparateCycles() {
        let firstReset = now.addingTimeInterval(-5 * 3_600)
        let samples = cycle(reset: firstReset, from: 0, to: 30) + cycle(reset: now, from: 0, to: 20)
        let group = ForecastBacktest.evaluate(
            provider: .codex, windowID: "codex.primary", windowMinutes: 300,
            samples: samples, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 2)
        XCTAssertEqual(group.counts.crossingCycles, 0)
    }

    func testReportAggregatesInsufficientData() {
        let group = ForecastBacktest.evaluate(
            provider: .go, windowID: "go.rolling", windowMinutes: 300,
            samples: cycle(reset: now, from: 0, to: 50), now: now
        )
        let report = ForecastBacktest.report(groups: [group], now: now)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.status, .insufficientData)
        XCTAssertEqual(report.targetPercent, 95)
        XCTAssertEqual(report.checkpointMinutes, 30)
        XCTAssertEqual(report.groups.first?.provider, "opencode-go")
    }
}
