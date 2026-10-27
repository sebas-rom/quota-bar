import XCTest
@testable import QuotaBarKit

final class ForecastTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    /// Samples every 5 minutes for `count` points ending at `now`.
    private func series(
        from start: Double,
        to end: Double,
        count: Int = 13,
        reset: Date,
        origin: SnapshotOrigin = .network,
        skipGapAt: Int? = nil
    ) -> [ForecastSample] {
        (0..<count).map { index in
            let t = now.addingTimeInterval(Double(index - (count - 1)) * 300)
            let progress = Double(index) / Double(max(1, count - 1))
            let percent = start + (end - start) * progress
            let at = (skipGapAt == index) ? t.addingTimeInterval(-1_200) : t
            return ForecastSample(at: at, percent: percent, resetsAt: reset, origin: origin)
        }
    }

    private func forecast(_ samples: [ForecastSample], current: Double, reset: Date?, window: Int = 300) -> ForecastState {
        ForecastEngine.forecast(samples: samples, now: now, currentPercent: current, resetAt: reset, windowMinutes: window)
    }

    func testApproachingWhenRateReachesThresholdBeforeReset() {
        let reset = now.addingTimeInterval(180 * 60)
        let samples = series(from: 40, to: 70, reset: reset)
        let state = forecast(samples, current: 70, reset: reset)
        guard case let .approaching95(minutes, resetMinutes) = state else {
            return XCTFail("expected approaching95, got \(state)")
        }
        XCTAssertEqual(minutes, 50, accuracy: 1)
        XCTAssertEqual(resetMinutes, 180, accuracy: 1)
        XCTAssertEqual(
            ForecastCopy.line(for: state),
            "At recent pace · 95% in ~50m"
        )
    }

    func testBelowWhenRateMissesReset() {
        let reset = now.addingTimeInterval(60 * 60)
        let samples = series(from: 55, to: 70, reset: reset) // 15 pts/hour -> ~100m to 95
        let state = forecast(samples, current: 70, reset: reset)
        guard case let .below95(resetMinutes) = state else {
            return XCTFail("expected below95, got \(state)")
        }
        XCTAssertEqual(resetMinutes, 60, accuracy: 1)
        XCTAssertEqual(ForecastCopy.line(for: state), "At recent pace · below 95% by reset")
    }

    func testSlowRateStillSaysBelowUntilReset() {
        // Command Code at ~26% with a 3.8-point rise over 56 minutes: ETA is far
        // beyond two hours, but it still will not hit 95% before an 86m reset.
        let reset = now.addingTimeInterval(86 * 60)
        let samples = series(from: 22.6, to: 26.4, count: 12, reset: reset)
        let state = forecast(samples, current: 26.4, reset: reset)
        guard case let .below95(resetMinutes) = state else {
            return XCTFail("expected below95, got \(state)")
        }
        XCTAssertEqual(resetMinutes, 86, accuracy: 1)
    }

    func testAlreadyAboveThreshold() {
        let reset = now.addingTimeInterval(45 * 60)
        let samples = series(from: 90, to: 96, reset: reset)
        let state = forecast(samples, current: 96, reset: reset)
        guard case let .already95(resetMinutes) = state else {
            return XCTFail("expected already95, got \(state)")
        }
        XCTAssertEqual(resetMinutes, 45, accuracy: 1)
        XCTAssertEqual(ForecastCopy.line(for: state), "95% reached · resets in 45m")
    }

    func testFlatWindowAbstains() {
        let reset = now.addingTimeInterval(180 * 60)
        let samples = series(from: 60, to: 60.5, reset: reset)
        XCTAssertEqual(forecast(samples, current: 60.5, reset: reset), .collecting)
        XCTAssertNil(ForecastCopy.line(for: .collecting))
    }

    func testStaleDataAbstains() {
        let reset = now.addingTimeInterval(120 * 60)
        let samples = series(from: 40, to: 70, reset: reset)
            .map { ForecastSample(at: $0.at.addingTimeInterval(-11 * 60), percent: $0.percent, resetsAt: $0.resetsAt, origin: $0.origin) }
        guard case let .unavailable(reason) = forecast(samples, current: 70, reset: reset) else {
            return XCTFail("expected unavailable")
        }
        XCTAssertEqual(reason, "stale")
    }

    func testGapAbstains() {
        let reset = now.addingTimeInterval(180 * 60)
        let minutesAgo = [58, 53, 48, 43, 38, 33, 8, 3, 0]
        let samples = minutesAgo.enumerated().map { index, ago in
            ForecastSample(
                at: now.addingTimeInterval(-Double(ago) * 60),
                percent: 40 + Double(index) * 3,
                resetsAt: reset,
                origin: .network
            )
        }
        guard case let .unavailable(reason) = forecast(samples, current: 64, reset: reset) else {
            return XCTFail("expected unavailable, got \(forecast(samples, current: 64, reset: reset))")
        }
        XCTAssertEqual(reason, "sampling gap")
    }

    func testResetTooCloseAbstains() {
        let reset = now.addingTimeInterval(10 * 60)
        let samples = series(from: 40, to: 70, reset: reset)
        guard case .unavailable = forecast(samples, current: 70, reset: reset) else {
            return XCTFail("expected unavailable")
        }
    }

    func testLocalLogOriginsAreIgnored() {
        let reset = now.addingTimeInterval(180 * 60)
        let samples = series(from: 40, to: 70, reset: reset, origin: .localLog)
        XCTAssertEqual(forecast(samples, current: 70, reset: reset), .collecting)
    }

    func testResetBoundaryChangeDropsOldSamples() {
        let resetA = now.addingTimeInterval(180 * 60)
        let resetB = now.addingTimeInterval(300 * 60)
        var samples = series(from: 40, to: 55, reset: resetA)
        samples += series(from: 0, to: 8, count: 3, reset: resetB)
        // Only 3 samples belong to the new boundary: collect, don't guess.
        XCTAssertEqual(forecast(samples, current: 8, reset: resetB), .collecting)
    }

    func testCloseCallAbstains() {
        let reset = now.addingTimeInterval(60 * 60)
        let samples = series(from: 40, to: 70, reset: reset) // eta 50m vs reset 60m: within 15m margin
        guard case .unavailable = forecast(samples, current: 70, reset: reset) else {
            return XCTFail("expected unavailable, got \(forecast(samples, current: 70, reset: reset))")
        }
    }

    func testDurationFormatting() {
        XCTAssertEqual(ForecastCopy.duration(45), "45m")
        XCTAssertEqual(ForecastCopy.duration(60), "1h")
        XCTAssertEqual(ForecastCopy.duration(125), "2h 5m")
        XCTAssertEqual(ForecastCopy.duration(60 * 30), "1d")
    }
}

final class ForecastProjectionTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func series(from: Double, to: Double, reset: Date) -> [ForecastSample] {
        (0..<13).map { index in
            let at = now.addingTimeInterval(Double(index - 12) * 300)
            let progress = Double(index) / 12
            return ForecastSample(at: at, percent: from + (to - from) * progress,
                                  resetsAt: reset, origin: .network)
        }
    }

    func testProjectionIsCappedAtHorizonAndLimit() {
        let reset = now.addingTimeInterval(180 * 60)
        let samples = series(from: 40, to: 70, reset: reset)
        let projection = ForecastEngine.projection(
            samples: samples, now: now, currentPercent: 70,
            resetAt: reset, windowMinutes: 300
        )
        let p = projection
        XCTAssertNotNil(p)
        XCTAssertEqual(p?.from, samples.last?.at)
        XCTAssertEqual(p?.fromPercent, 70)
        XCTAssertLessThanOrEqual(p?.toPercent ?? 999, 100)
        XCTAssertLessThanOrEqual(p?.to ?? .distantFuture, now.addingTimeInterval(2 * 60 * 60 + 1))
    }

    func testNoProjectionWhenIneligible() {
        let reset = now.addingTimeInterval(180 * 60)
        let flat = series(from: 60, to: 60.2, reset: reset)
        XCTAssertNil(ForecastEngine.projection(
            samples: flat, now: now, currentPercent: 60.2,
            resetAt: reset, windowMinutes: 300
        ))
    }
}
