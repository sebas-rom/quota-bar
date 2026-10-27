import XCTest
@testable import QuotaBarKit

final class AlertRulesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func snapshot(
        percent: Double,
        limited: Bool = false,
        reset: Date?,
        provider: ProviderID = .codex,
        origin: SnapshotOrigin = .network,
        label: String = "5-hour"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: [QuotaWindow(
                id: "\(provider.rawValue).test", kind: .rolling, label: label,
                percent: percent, resetsAt: reset, windowMinutes: 300, isLimited: limited
            )],
            origin: origin,
            source: "test",
            observedAt: now
        )
    }

    func testWarningFiresOncePerCycle() {
        let reset = now.addingTimeInterval(48 * 60)
        var state = AlertState()
        let first = AlertRules.evaluate(snapshot(percent: 92, reset: reset), state: &state, now: now)
        XCTAssertEqual(first.count, 1)
        XCTAssertEqual(first.first?.kind, .warning)
        XCTAssertEqual(first.first?.message, "Codex 5-hour quota is 92% used. Resets in 48m.")

        let second = AlertRules.evaluate(snapshot(percent: 93, reset: reset), state: &state, now: now)
        XCTAssertTrue(second.isEmpty, "same cycle must not repeat")
    }

    func testLimitEscalatesAfterWarning() {
        let reset = now.addingTimeInterval(30 * 60)
        var state = AlertState()
        _ = AlertRules.evaluate(snapshot(percent: 91, reset: reset), state: &state, now: now)

        let limit = AlertRules.evaluate(snapshot(percent: 100, limited: true, reset: reset), state: &state, now: now)
        XCTAssertEqual(limit.count, 1)
        XCTAssertEqual(limit.first?.kind, .limit)
        XCTAssertEqual(limit.first?.message, "Codex 5-hour limit reached. Resets in 30m.")

        let again = AlertRules.evaluate(snapshot(percent: 100, limited: true, reset: reset), state: &state, now: now)
        XCTAssertTrue(again.isEmpty)
    }

    func testLimitAloneFires() {
        var state = AlertState()
        let decisions = AlertRules.evaluate(
            snapshot(percent: 100, limited: true, reset: now.addingTimeInterval(600)),
            state: &state, now: now
        )
        XCTAssertEqual(decisions.map(\.kind), [.limit])
    }

    func testBelowThresholdIsSilent() {
        var state = AlertState()
        XCTAssertTrue(AlertRules.evaluate(snapshot(percent: 89.9, reset: now.addingTimeInterval(600)),
                                          state: &state, now: now).isEmpty)
    }

    func testNonNetworkOriginsNeverNotify() {
        for origin in [SnapshotOrigin.localLog, .demo] {
            var state = AlertState()
            XCTAssertTrue(AlertRules.evaluate(
                snapshot(percent: 99, limited: true, reset: now.addingTimeInterval(600), origin: origin),
                state: &state, now: now
            ).isEmpty, "\(origin) must not notify")
        }
    }

    func testNewCycleRearms() {
        var state = AlertState()
        let first = now.addingTimeInterval(600)
        let next = first.addingTimeInterval(5 * 3_600)
        _ = AlertRules.evaluate(snapshot(percent: 92, reset: first), state: &state, now: now)
        let second = AlertRules.evaluate(snapshot(percent: 92, reset: next), state: &state, now: now)
        XCTAssertEqual(second.count, 1, "a new reset boundary is a new cycle")
    }

    func testWeeklyLabelIsLowercasedInCopy() {
        var state = AlertState()
        let decisions = AlertRules.evaluate(
            snapshot(percent: 92, reset: now.addingTimeInterval(2 * 86_400), provider: .go, label: "Weekly"),
            state: &state, now: now
        )
        XCTAssertEqual(decisions.first?.message, "OpenCode Go weekly quota is 92% used. Resets in 2d.")
    }

    func testMissingResetCopy() {
        var state = AlertState()
        let decisions = AlertRules.evaluate(snapshot(percent: 93, reset: nil), state: &state, now: now)
        XCTAssertEqual(decisions.first?.message, "Codex 5-hour quota is 93% used. Reset time unavailable.")
    }

    func testWindowsAreIndependent() {
        let snapshot = ProviderSnapshot(
            provider: .go,
            windows: [
                QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour", percent: 95,
                            resetsAt: now.addingTimeInterval(600), windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "go.weekly", kind: .weekly, label: "Weekly", percent: 96,
                            resetsAt: now.addingTimeInterval(86_400), windowMinutes: 10_080, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: now
        )
        var state = AlertState()
        let decisions = AlertRules.evaluate(snapshot, state: &state, now: now)
        XCTAssertEqual(Set(decisions.map(\.windowID)), ["go.rolling", "go.weekly"])
    }

    func testAlertStateRoundTripsThroughJSON() throws {
        var state = AlertState()
        _ = AlertRules.evaluate(snapshot(percent: 95, reset: now.addingTimeInterval(600)), state: &state, now: now)
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(AlertState.self, from: data)
        XCTAssertEqual(decoded, state)
    }
}

final class AlertCoalescerTests: XCTestCase {
    private func decision(_ kind: AlertKind, percent: Double, id: String) -> AlertDecision {
        AlertDecision(provider: .codex, windowID: id, kind: kind, message: id,
                      identifier: id, percent: percent)
    }

    func testLimitBeatsWarning() {
        let batch = AlertCoalescer.best([
            decision(.warning, percent: 97, id: "a"),
            decision(.limit, percent: 100, id: "b"),
            decision(.warning, percent: 91, id: "c"),
        ])
        XCTAssertEqual(batch?.decision.identifier, "b")
        XCTAssertEqual(batch?.additionalCount, 2)
    }

    func testHighestPercentWithinSameKind() {
        let batch = AlertCoalescer.best([
            decision(.warning, percent: 91, id: "low"),
            decision(.warning, percent: 96, id: "high"),
        ])
        XCTAssertEqual(batch?.decision.identifier, "high")
    }

    func testEmptyBatch() {
        XCTAssertNil(AlertCoalescer.best([]))
    }
}
