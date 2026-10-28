import XCTest
@testable import QuotaBarKit

/// The atomic current-state transition rules. Every rule here protects one
/// failure mode the per-window history table cannot express: stitching windows
/// from two probes, relabelling another account's numbers, or turning a failed
/// probe into 0% usage.
final class ProviderStateTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(
        _ provider: ProviderID = .codex,
        windows: [(String, Double)] = [("codex.primary", 20), ("codex.secondary", 10)],
        origin: SnapshotOrigin = .network,
        account: String? = "acct-a",
        at date: Date? = nil
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: windows.map {
                QuotaWindow(id: $0.0, kind: .primary, label: $0.0, percent: $0.1,
                            resetsAt: nil, windowMinutes: 300, isLimited: false)
            },
            plan: "plus",
            accountRef: account,
            origin: origin,
            source: "test",
            observedAt: date ?? now,
            facts: ["2 reset credits"]
        )
    }

    func testSuccessfulNetworkProbeIsComplete() {
        let state = ProviderState.next(nil, result: .ok(snapshot()), provider: .codex, now: now)
        XCTAssertEqual(state.generation, 1)
        XCTAssertEqual(state.completeness, .complete)
        XCTAssertEqual(state.probeState, .ok)
        XCTAssertEqual(state.observedAt, now)
        XCTAssertEqual(state.windows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(state.facts, ["2 reset credits"])
    }

    func testLocalLogProbeIsPartialNotComplete() {
        let state = ProviderState.next(
            nil,
            result: .ok(snapshot(origin: .localLog)),
            provider: .codex,
            now: now
        )
        XCTAssertEqual(state.completeness, .partial, "a local log is not a live reading")
        XCTAssertEqual(state.origin, .localLog)
    }

    func testStaleProbeKeepsWindowsButRecordsTheNewOutcome() {
        let first = ProviderState.next(nil, result: .ok(snapshot()), provider: .codex, now: now)
        let later = now.addingTimeInterval(3600)
        let staleAt = now.addingTimeInterval(-1800)
        let state = ProviderState.next(
            first,
            result: .stale(snapshot(windows: [("codex.primary", 40)], at: staleAt), .offline, "no network"),
            provider: .codex,
            now: later
        )
        XCTAssertEqual(state.generation, 2)
        XCTAssertEqual(state.completeness, .partial)
        XCTAssertEqual(state.probeState, .offline)
        XCTAssertEqual(state.probeMessage, "no network")
        XCTAssertEqual(state.probeAt, later)
        XCTAssertEqual(state.observedAt, staleAt)
        XCTAssertEqual(state.windows.first?.percent, 40)
    }

    func testFailedProbeNeverInventsQuotaAndKeepsTheLastReading() {
        let first = ProviderState.next(nil, result: .ok(snapshot()), provider: .codex, now: now)
        let later = now.addingTimeInterval(600)
        let state = ProviderState.next(
            first,
            result: .failed(.authFailed, "token expired"),
            provider: .codex,
            now: later
        )
        XCTAssertEqual(state.completeness, .failed)
        XCTAssertEqual(state.probeState, .authFailed)
        XCTAssertEqual(state.windows.map(\.percent), [20, 10], "retained reading, not zeros")
        XCTAssertEqual(state.observedAt, now)
        XCTAssertEqual(state.plan, "plus")
    }

    func testFailedProbeWithNoHistoryStaysEmpty() {
        let state = ProviderState.next(
            nil,
            result: .failed(.noCredentials, "no token"),
            provider: .go,
            now: now
        )
        XCTAssertEqual(state.generation, 1)
        XCTAssertTrue(state.windows.isEmpty)
        XCTAssertNil(state.observedAt)
        XCTAssertEqual(state.completeness, .failed)
    }

    func testAccountChangeDropsThePreviousWindows() {
        let first = ProviderState.next(nil, result: .ok(snapshot(account: "acct-a")), provider: .codex, now: now)
        let later = now.addingTimeInterval(600)
        let state = ProviderState.next(
            first,
            result: .stale(snapshot(windows: [("codex.primary", 70)], account: "acct-b"), .offline, "offline"),
            provider: .codex,
            now: later
        )
        XCTAssertEqual(state.accountRef, "acct-b")
        XCTAssertTrue(state.windows.isEmpty, "another account's numbers must not be relabelled")
        XCTAssertTrue(state.facts.isEmpty)
    }

    func testSameAccountIsPreserved() {
        let first = ProviderState.next(nil, result: .ok(snapshot(account: "acct-a")), provider: .codex, now: now)
        let state = ProviderState.next(
            first,
            result: .stale(snapshot(account: "acct-a"), .offline, "offline"),
            provider: .codex,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(state.windows.map(\.percent), [20, 10])
    }

    func testMissingAccountsNeverCountAsAChange() {
        let first = ProviderState.next(nil, result: .ok(snapshot(account: nil)), provider: .codex, now: now)
        let state = ProviderState.next(
            first,
            result: .stale(snapshot(account: nil), .offline, "offline"),
            provider: .codex,
            now: now.addingTimeInterval(60)
        )
        XCTAssertEqual(state.windows.count, 2)
    }

    func testMissingRequiredWindowMakesANetworkReadingPartial() {
        let state = ProviderState.next(
            nil,
            result: .ok(snapshot(windows: [("codex.secondary", 30)])),
            provider: .codex,
            now: now
        )
        XCTAssertEqual(state.completeness, .partial, "no evidence about the 5-hour limit is not a complete reading")
        XCTAssertEqual(state.windows.map(\.id), ["codex.secondary"])

        let advice = Advisor.evaluate(provider: .codex, state: state, now: now)
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.incompleteSnapshot])
    }

    func testGoWithoutItsMonthlyWindowIsPartial() {
        let incomplete = ProviderSnapshot(
            provider: .go,
            windows: [
                QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour", percent: 20,
                            resetsAt: nil, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "go.weekly", kind: .weekly, label: "Weekly", percent: 30,
                            resetsAt: nil, windowMinutes: 10_080, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: now
        )
        let state = ProviderState.next(nil, result: .ok(incomplete), provider: .go, now: now)
        XCTAssertEqual(state.completeness, .partial, "no evidence about the monthly limit")

        let advice = Advisor.evaluate(provider: .go, state: state, now: now)
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.incompleteSnapshot])
    }

    func testGoWithAllThreeWindowsIsComplete() {
        let complete = ProviderSnapshot(
            provider: .go,
            windows: [
                QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour", percent: 20,
                            resetsAt: nil, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "go.weekly", kind: .weekly, label: "Weekly", percent: 30,
                            resetsAt: nil, windowMinutes: 10_080, isLimited: false),
                QuotaWindow(id: "go.monthly", kind: .monthly, label: "Monthly", percent: 45,
                            resetsAt: nil, windowMinutes: 43_200, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: now
        )
        let state = ProviderState.next(nil, result: .ok(complete), provider: .go, now: now)
        XCTAssertEqual(state.completeness, .complete)
        let advice = Advisor.evaluate(provider: .go, state: state, now: now)
        XCTAssertEqual(advice.eligibility, .available)
    }

    func testRequiredWindowsAreProviderSpecific() {
        XCTAssertEqual(ProviderWindows.requiredIDs(.go), ["go.rolling", "go.weekly", "go.monthly"])
        XCTAssertEqual(ProviderWindows.requiredIDs(.codex), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(ProviderWindows.requiredIDs(.commandCode), ["commandcode.5h", "commandcode.weekly"])

        let complete = ProviderSnapshot(
            provider: .commandCode,
            windows: [
                QuotaWindow(id: "commandcode.5h", kind: .primary, label: "5-hour", percent: 10,
                            resetsAt: nil, windowMinutes: 300, isLimited: false),
                QuotaWindow(id: "commandcode.weekly", kind: .weekly, label: "Weekly", percent: 5,
                            resetsAt: nil, windowMinutes: 10_080, isLimited: false),
            ],
            origin: .network, source: "test", observedAt: now
        )
        XCTAssertTrue(ProviderWindows.missing(in: complete).isEmpty)
        let state = ProviderState.next(nil, result: .ok(complete), provider: .commandCode, now: now)
        XCTAssertEqual(state.completeness, .complete)
    }

    func testMissingCredentialsMeansNotConfigured() {
        let missing = ProviderState.next(
            nil, result: .failed(.noCredentials, "no token"), provider: .commandCode, now: now
        )
        XCTAssertFalse(missing.isConfigured)

        let broken = ProviderState.next(
            nil, result: .failed(.offline, "offline"), provider: .commandCode, now: now
        )
        XCTAssertTrue(broken.isConfigured)

        let healthy = ProviderState.next(nil, result: .ok(snapshot()), provider: .codex, now: now)
        XCTAssertTrue(healthy.isConfigured)
    }

    func testGenerationIncreasesOnEveryTransition() {
        var state = ProviderState.next(nil, result: .ok(snapshot()), provider: .codex, now: now)
        for index in 1...3 {
            state = ProviderState.next(
                state,
                result: .failed(.offline, "down"),
                provider: .codex,
                now: now.addingTimeInterval(Double(index))
            )
            XCTAssertEqual(state.generation, index + 1)
        }
    }
}
