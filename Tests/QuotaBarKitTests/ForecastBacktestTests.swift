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

final class ForecastBacktestIntegrityTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func curve(reset: Date, _ percentAt: (Int) -> Double) -> [ForecastSample] {
        (0...59).map { index in
            ForecastSample(
                at: grid(reset: reset, at: index * 5),
                percent: percentAt(index),
                resetsAt: reset,
                origin: .network
            )
        }
    }

    /// Five-minute grid across the whole cycle.
    private func grid(reset: Date, at minuteOffset: Int) -> Date {
        reset.addingTimeInterval(-300 * 60).addingTimeInterval(Double(minuteOffset) * 60)
    }

    private func ramp(reset: Date, from: Double, to: Double, override: [Double: Double] = [:]) -> [ForecastSample] {
        (0...59).map { index in
            let at = grid(reset: reset, at: index * 5)
            let progress = Double(index) / 59.0
            let percent = override[Double(index * 5)] ?? (from + (to - from) * progress)
            return ForecastSample(at: at, percent: percent, resetsAt: reset, origin: .network)
        }
    }

    func testOngoingCycleIsCensoredNotNegative() {
        let reset = now.addingTimeInterval(600)
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: ramp(reset: reset, from: 0, to: 20), now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 0)
        XCTAssertEqual(group.counts.trueNegatives, 0)
        XCTAssertEqual(group.excluded.ongoingCycle, 1)
    }

    func testMissingCycleStartIsCensored() {
        let reset = now
        let all = ramp(reset: reset, from: 0, to: 40)
        let late = all.filter { $0.at.timeIntervalSince(reset.addingTimeInterval(-300 * 60)) >= 45 * 60 }
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: late, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 0)
        XCTAssertEqual(group.counts.nonCrossingCycles, 0)
        XCTAssertEqual(group.excluded.incompleteCycle, 1)
    }

    func testInternalGapIsCensored() {
        let reset = now
        let all = ramp(reset: reset, from: 0, to: 40)
        let withGap = all.filter { sample in
            let offset = sample.at.timeIntervalSince(reset.addingTimeInterval(-300 * 60)) / 60
            return !(offset >= 120 && offset <= 180)
        }
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: withGap, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 0)
        XCTAssertEqual(group.excluded.samplingGap, 1)
    }

    /// A crossing the engine never predicted is a miss, not an excluded cycle.
    func testRecallCountsCrossingsWhereEngineStayedSilent() {
        let reset = now
        // Slow first half, flat second half, then a late jump over the
        // threshold: no checkpoint with a useful lead ever predicts it.
        let points = curve(reset: reset) { index in
            index < 30 ? 50 * Double(index) / 29 : (index < 56 ? 50 : 100)
        }
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: points, now: now
        )
        XCTAssertEqual(group.counts.crossingCycles, 1)
        XCTAssertEqual(group.metrics.recallAt30m, 0)
        XCTAssertEqual(group.counts.truePositives, 0)
    }

    func testUnattributedObservationsAreReported() {
        let reset = now
        var points = ramp(reset: reset, from: 0, to: 40)
        points.append(ForecastSample(at: now.addingTimeInterval(-60), percent: 12,
                                     resetsAt: nil, origin: .network))
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: points, now: now
        )
        XCTAssertEqual(group.excluded.ambiguousReset, 1)
    }

    func testSufficientAccurateReplayCanPass() {
        var all: [ForecastSample] = []
        for cycle in 0..<20 {
            let reset = now.addingTimeInterval(-Double(cycle + 1) * 5 * 3_600)
            let target = cycle < 8 ? 100.0 : 40.0
            all += ramp(reset: reset, from: 0, to: target)
        }
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: all, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 20)
        XCTAssertGreaterThanOrEqual(group.counts.crossingCycles, 8)
        XCTAssertGreaterThanOrEqual(group.counts.nonCrossingCycles, 8)
        XCTAssertEqual(group.status, .pass, "metrics: \(group.metrics) counts: \(group.counts)")
    }

    func testWildlyInaccurateEtaFails() {
        var all: [ForecastSample] = []
        for cycle in 0..<20 {
            let reset = now.addingTimeInterval(-Double(cycle + 1) * 5 * 3_600)
            if cycle < 10 {
                // Fast early ramp invites an early ETA, then the cycle stalls and
                // crosses near the reset: predictions are directionally right but
                // hours off.
                all += curve(reset: reset) { index in
                    index < 12 ? 80 * Double(index) / 11 : (index >= 58 ? 100 : 80)
                }
            } else {
                all += ramp(reset: reset, from: 0, to: 40)
            }
        }
        let group = ForecastBacktest.evaluate(
            provider: .commandCode, windowID: "commandcode.5h", windowMinutes: 300,
            samples: all, now: now
        )
        XCTAssertEqual(group.counts.completeCycles, 20)
        XCTAssertEqual(group.status, .fail, "metrics: \(group.metrics) counts: \(group.counts)")
    }
}
