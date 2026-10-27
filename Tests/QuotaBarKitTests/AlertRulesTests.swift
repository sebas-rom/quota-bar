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

final class RollingAlertTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)

    private func snapshot(
        percent: Double,
        reset: Date,
        limited: Bool = false,
        provider: ProviderID = .go,
        windowID: String = "go.rolling"
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: [QuotaWindow(
                id: windowID, kind: .rolling, label: "5-hour",
                percent: percent, resetsAt: reset, windowMinutes: 300, isLimited: limited
            )],
            origin: .network,
            source: "test",
            observedAt: now
        )
    }

    /// The release blocker: a sliding reset must never re-arm the warning.
    func testAdvancingResetFiresExactlyOneWarning() {
        var state = AlertState()
        var delivered: [AlertDecision] = []
        for step in 0..<3 {
            let reset = now.addingTimeInterval(3_600 + Double(step) * 300)
            delivered += AlertRules.evaluate(snapshot(percent: 93, reset: reset), state: &state, now: now)
        }
        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.kind, .warning)
    }

    func testRecoveryRearmsSlidingWarning() {
        var state = AlertState()
        let reset = now.addingTimeInterval(3_600)
        XCTAssertEqual(AlertRules.evaluate(snapshot(percent: 93, reset: reset), state: &state, now: now).count, 1)
        XCTAssertTrue(AlertRules.evaluate(snapshot(percent: 80, reset: reset), state: &state, now: now).isEmpty)
        XCTAssertEqual(AlertRules.evaluate(snapshot(percent: 91, reset: reset), state: &state, now: now).count, 1)
    }

    func testSlidingLimitFiresOnceAndIndependently() {
        var state = AlertState()
        let reset = now.addingTimeInterval(3_600)
        let warning = AlertRules.evaluate(snapshot(percent: 92, reset: reset), state: &state, now: now)
        XCTAssertEqual(warning.map(\.kind), [.warning])

        let first = AlertRules.evaluate(snapshot(percent: 100, reset: reset, limited: true), state: &state, now: now)
        XCTAssertEqual(first.map(\.kind), [.limit])
        let repeated = AlertRules.evaluate(
            snapshot(percent: 100, reset: reset.addingTimeInterval(300), limited: true),
            state: &state, now: now
        )
        XCTAssertTrue(repeated.isEmpty)
    }

    func testFixedCycleStillUsesResetKey() {
        var state = AlertState()
        let snapshot234 = ProviderSnapshot(
            provider: .commandCode,
            windows: [QuotaWindow(id: "commandcode.5h", kind: .primary, label: "5-hour",
                                  percent: 94, resetsAt: now.addingTimeInterval(3_600),
                                  windowMinutes: 300, isLimited: false)],
            origin: .network, source: "test", observedAt: now
        )
        XCTAssertEqual(AlertRules.evaluate(snapshot234, state: &state, now: now).count, 1)
        XCTAssertTrue(AlertRules.evaluate(snapshot234, state: &state, now: now).isEmpty)
    }

    func testLegacyStateWithoutRollingFieldsDecodes() {
        let legacy = #"{"warned":{"codex.primary":"r1"},"limitWarned":{}}"#
        let state = try? JSONDecoder().decode(AlertState.self, from: Data(legacy.utf8))
        XCTAssertEqual(state?.warned["codex.primary"], "r1")
        XCTAssertEqual(state?.rollingWarned, [])
    }
}

final class ProviderPresentationTests: XCTestCase {
    func testNoSnapshotNoHealthIsChecking() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: false, health: nil), .checking)
    }

    func testMissingCredentialsIsUnconfigured() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: false, health: .noCredentials), .unconfigured)
    }

    func testSnapshotWithOKIsAvailable() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: true, health: .ok), .available)
    }

    func testSnapshotWithAuthFailureStaysVisibleAsDegraded() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: true, health: .authFailed), .degraded)
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: true, health: nil), .degraded)
    }

    func testLocalSnapshotWithoutCredentialsStaysVisible() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: true, health: .noCredentials), .degraded)
    }

    func testFailureWithoutSnapshotNeedsAttention() {
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: false, health: .providerDown), .needsAttention)
        XCTAssertEqual(ProviderPresentation.resolve(hasSnapshot: false, health: .offline), .needsAttention)
    }

    func testRollingClassificationIsShared() {
        let go = QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour",
                             percent: 10, resetsAt: nil, windowMinutes: 300, isLimited: false)
        let codex = QuotaWindow(id: "codex.primary", kind: .primary, label: "Primary",
                                percent: 10, resetsAt: nil, windowMinutes: 300, isLimited: false)
        let cc = QuotaWindow(id: "commandcode.5h", kind: .primary, label: "5-hour",
                             percent: 10, resetsAt: nil, windowMinutes: 300, isLimited: false)
        XCTAssertTrue(WindowSemantics.isRolling(provider: .go, window: go))
        XCTAssertTrue(WindowSemantics.isRolling(provider: .codex, window: codex))
        XCTAssertFalse(WindowSemantics.isRolling(provider: .commandCode, window: cc))
    }
}

final class AlertPersistenceTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_793_100_000)
    private var stored: Data?
    private var writes = 0

    override func setUp() {
        super.setUp()
        stored = nil
        writes = 0
    }

    private func load() -> AlertState {
        guard let stored, let state = try? JSONDecoder().decode(AlertState.self, from: stored) else {
            return AlertState()
        }
        return state
    }

    private func persist(_ state: AlertState) {
        writes += 1
        stored = try? JSONEncoder().encode(state)
    }

    /// Every observation starts from the persisted document, exactly like a
    /// sequence of independent refreshes (or an app relaunch).
    private func observe(percent: Double, resetOffset: TimeInterval = 3_600, limited: Bool = false) -> [AlertDecision] {
        let snapshot = ProviderSnapshot(
            provider: .go,
            windows: [QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour",
                                  percent: percent,
                                  resetsAt: now.addingTimeInterval(resetOffset),
                                  windowMinutes: 300, isLimited: limited)],
            origin: .network, source: "test", observedAt: now
        )
        var state = load()
        return AlertEngine.run(snapshot, state: &state, now: now, persist: persist)
    }

    func testRecoverySurvivesThePersistenceBoundary() {
        XCTAssertEqual(observe(percent: 93).map(\.kind), [.warning])
        XCTAssertTrue(observe(percent: 80).isEmpty)
        XCTAssertEqual(writes, 2, "recovery must be persisted even without an alert")
        XCTAssertEqual(observe(percent: 91).map(\.kind), [.warning], "crossing after recovery re-arms")
        XCTAssertTrue(observe(percent: 92).isEmpty)
    }

    func testLimitEscalationSurvivesRelaunch() {
        XCTAssertEqual(observe(percent: 92).map(\.kind), [.warning])
        XCTAssertEqual(observe(percent: 100, limited: true).map(\.kind), [.limit])
        // Simulated relaunch: decode the stored document again.
        XCTAssertTrue(observe(percent: 100, limited: true).isEmpty)
    }

    func testUnchangedObservationDoesNotWrite() {
        _ = observe(percent: 40)
        let after = writes
        _ = observe(percent: 41)
        XCTAssertEqual(writes, after, "no state transition means no write")
    }

    func testFixedCycleStillSuppressesAcrossBoundary() {
        let snapshot = ProviderSnapshot(
            provider: .commandCode,
            windows: [QuotaWindow(id: "commandcode.5h", kind: .primary, label: "5-hour",
                                  percent: 94, resetsAt: now.addingTimeInterval(3_600),
                                  windowMinutes: 300, isLimited: false)],
            origin: .network, source: "test", observedAt: now
        )
        var state = load()
        XCTAssertEqual(AlertEngine.run(snapshot, state: &state, now: now, persist: persist).count, 1)
        state = load()
        XCTAssertTrue(AlertEngine.run(snapshot, state: &state, now: now, persist: persist).isEmpty)
    }
}
