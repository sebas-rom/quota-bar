import XCTest
@testable import QuotaBarKit

final class SnapshotTests: XCTestCase {
    func testLimitingIsMaxAcrossWindows() {
        let snapshot = ProviderSnapshot(
            provider: .go,
            windows: [
                QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour", percent: 85, resetsAt: nil, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "go.weekly", kind: .weekly, label: "Weekly", percent: 30, resetsAt: nil, windowMinutes: 10_080, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: Date()
        )
        XCTAssertEqual(snapshot.limiting?.id, "go.rolling")
        XCTAssertEqual(snapshot.window(id: "go.weekly")?.percent, 30)
    }

    func testLimitingIgnoresNonFinitePercent() {
        let snapshot = ProviderSnapshot(
            provider: .codex,
            windows: [
                QuotaWindow(id: "a", kind: .primary, label: "A", percent: .nan, resetsAt: nil, windowMinutes: nil, isLimited: false),
                QuotaWindow(id: "b", kind: .secondary, label: "B", percent: 12, resetsAt: nil, windowMinutes: nil, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: Date()
        )
        XCTAssertEqual(snapshot.limiting?.id, "b")
    }

    func testFreshnessCopy() {
        let now = Date()
        XCTAssertEqual(freshnessText(for: now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(freshnessText(for: now.addingTimeInterval(-5 * 60), now: now), "5m ago")
        XCTAssertEqual(freshnessText(for: now.addingTimeInterval(-3_700), now: now), "1h 1m ago")
        XCTAssertEqual(freshnessText(for: now.addingTimeInterval(-3 * 86_400), now: now), "3d ago")
        // Clock skew never produces a negative age.
        XCTAssertEqual(freshnessText(for: now.addingTimeInterval(60), now: now), "just now")
    }

    func testDeltaAndEmptySeries() {
        XCTAssertNil(deltaPoints([]))
        XCTAssertNil(deltaPoints([SamplePoint(at: Date(), percent: 10)]))
        let now = Date()
        let delta = deltaPoints([
            SamplePoint(at: now.addingTimeInterval(-3_600), percent: 10),
            SamplePoint(at: now, percent: 42),
        ])
        XCTAssertEqual(delta, 32)
    }

    func testDownsampleKeepsNewestAndCapsCount() {
        let now = Date()
        let points = (0..<1_000).map {
            SamplePoint(at: now.addingTimeInterval(Double($0) * 60), percent: Double($0) / 10)
        }
        let sampled = downsample(points, max: 240)
        XCTAssertLessThanOrEqual(sampled.count, 241)
        XCTAssertEqual(sampled.last, points.last)
        XCTAssertEqual(sampled.first, points.first)
        // Sorted ascending, never duplicated timestamps.
        XCTAssertEqual(sampled.map(\.at), sampled.map(\.at).sorted())
    }

    func testShortSeriesPassesThroughUnchanged() {
        let points = [SamplePoint(at: Date(), percent: 1)]
        XCTAssertEqual(downsample(points, max: 240), points)
    }

    func testWindowLabels() {
        XCTAssertEqual(windowLabel(forSeconds: 18_000), "5-hour")
        XCTAssertEqual(windowLabel(forSeconds: 604_800), "Weekly")
        XCTAssertEqual(windowLabel(forSeconds: 86_400), "Daily")
        XCTAssertEqual(windowLabel(forSeconds: 259_200), "3-day")
        XCTAssertEqual(windowLabel(forSeconds: nil), "Window")
        XCTAssertEqual(windowLabel(forSeconds: 0), "Window")
    }

    func testAccountRefIsStableAndNotRaw() {
        let raw = "923e6d72-8c3b-4155-a6b5-38365fd2579f"
        let ref = accountRef(raw)
        XCTAssertNotNil(ref)
        XCTAssertNotEqual(ref, raw)
        XCTAssertEqual(ref, accountRef(raw))
        XCTAssertNil(accountRef(nil))
        XCTAssertNil(accountRef(""))
    }
}
