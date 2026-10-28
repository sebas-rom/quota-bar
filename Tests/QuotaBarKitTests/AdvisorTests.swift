import XCTest
@testable import QuotaBarKit

/// Advisor rules. The product promise is narrow: report headroom, abstain when
/// the evidence cannot prove it, and never turn "I don't know" into a winner.
final class AdvisorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func windows(_ percents: [(String, Double)], limited: Set<String> = []) -> [QuotaWindow] {
        percents.map {
            QuotaWindow(id: $0.0, kind: .primary, label: $0.0, percent: $0.1,
                        resetsAt: now.addingTimeInterval(3600), windowMinutes: 300,
                        isLimited: limited.contains($0.0))
        }
    }

    private func state(
        _ provider: ProviderID = .codex,
        windows: [QuotaWindow],
        completeness: ObservationCompleteness = .complete,
        origin: SnapshotOrigin = .network,
        probeState: HealthState? = .ok,
        probeMessage: String? = nil,
        observedAt: Date? = nil
    ) -> ProviderState {
        ProviderState(
            provider: provider,
            generation: 1,
            observedAt: observedAt ?? now,
            origin: origin,
            source: "test",
            plan: "plus",
            accountRef: "acct",
            completeness: completeness,
            probeState: probeState,
            probeMessage: probeMessage,
            probeAt: now,
            windows: windows,
            facts: []
        )
    }

    // MARK: per-provider eligibility

    func testNoStateIsUnknown() {
        let advice = Advisor.evaluate(provider: .go, state: nil, now: now)
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.noObservation])
        XCTAssertNil(advice.limitingWindowId)
    }

    func testFailedProbeIsUnknownAndNeverZero() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 20)]), completeness: .failed,
                         probeState: .offline, probeMessage: "offline"),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.probeFailed])
        XCTAssertEqual(advice.headline, "offline")
    }

    func testMissingCredentialsAreNotJustAFailedProbe() {
        let advice = Advisor.evaluate(
            provider: .commandCode,
            state: state(.commandCode, windows: [], completeness: .failed,
                         probeState: .noCredentials, probeMessage: "No Command Code key"),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.providerUnconfigured])
    }

    func testLocalLogIsUnknown() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 20)]), completeness: .partial, origin: .localLog),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.localLogOnly])
    }

    func testPartialNetworkReadingIsUnknown() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 20)]), completeness: .partial),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.incompleteSnapshot])
        XCTAssertEqual(advice.headline, "Reading is missing a required window")
    }

    func testRateLimitedIsUnknownEvenWithNumbers() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 10)]), probeState: .rateLimited),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.rateLimited])
    }

    func testReadingAtTheStaleBoundaryIsUnknown() {
        let old = now.addingTimeInterval(-900)
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 10)]), observedAt: old),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.stale])
    }

    func testFreshReadingJustInsideTheBoundaryIsAvailable() {
        let fresh = now.addingTimeInterval(-899)
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 10)]), observedAt: fresh),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .available)
        XCTAssertEqual(advice.reasonCodes, [.eligible])
    }

    func testEmptyWindowsAreIncomplete() {
        let advice = Advisor.evaluate(provider: .codex, state: state(windows: []), now: now)
        XCTAssertEqual(advice.eligibility, .unknown)
        XCTAssertEqual(advice.reasonCodes, [.incompleteSnapshot])
    }

    func testNonFinitePercentIsIgnored() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", .nan)])),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .unknown)
    }

    func testHeadroomIsAvailable() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: windows([("codex.primary", 20), ("codex.secondary", 55)])),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .available)
        XCTAssertEqual(advice.limitingWindowId, "codex.secondary", "the most-used window is the limiter")
        XCTAssertTrue(advice.headline.contains("55%"))
    }

    func testNinetyPercentIsConstrained() {
        let advice = Advisor.evaluate(
            provider: .go,
            state: state(.go, windows: windows([("go.rolling", 89.9)])),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .available)

        let constrained = Advisor.evaluate(
            provider: .go,
            state: state(.go, windows: windows([("go.rolling", 90)])),
            now: now
        )
        XCTAssertEqual(constrained.eligibility, .constrained)
        XCTAssertEqual(constrained.reasonCodes, [.eligible, .nearingLimit])
    }

    func testLimitReachedIsExhausted() {
        let advice = Advisor.evaluate(
            provider: .go,
            state: state(.go, windows: windows([("go.rolling", 100)], limited: ["go.rolling"])),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .exhausted)
        XCTAssertEqual(advice.reasonCodes, [.quotaExhausted])
        XCTAssertFalse(advice.headline.lowercased().contains("blocked"))
    }

    func testFlaggedLimitWinsEvenBelowOneHundred() {
        let advice = Advisor.evaluate(
            provider: .commandCode,
            state: state(.commandCode, windows: windows([("commandcode.weekly", 99.5)], limited: ["commandcode.weekly"])),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .exhausted)
    }

    // MARK: recommendation

    func testSingleEligibleProviderIsRecommended() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
            .codex: state(.codex, windows: windows([("codex.primary", 100)], limited: ["codex.primary"])),
            .commandCode: state(.commandCode, windows: windows([("commandcode.5h", 100)], limited: ["commandcode.5h"])),
        ], now: now)
        XCTAssertEqual(advice.recommendation.status, .ok)
        XCTAssertEqual(advice.recommendation.providerId, "opencode-go")
        XCTAssertEqual(advice.recommendation.reasonCodes, [.singleEligibleProvider])
    }

    func testSingleViableWithUnknownAlternativeIsConditional() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
            .codex: state(windows: windows([("codex.primary", 100)], limited: ["codex.primary"])),
            // Configured, but its reading cannot be trusted.
            .commandCode: state(.commandCode, windows: windows([("commandcode.5h", 40)]),
                                completeness: .partial),
        ], now: now, providers: [.go, .codex, .commandCode])
        XCTAssertEqual(advice.recommendation.status, .conditional)
        XCTAssertEqual(advice.recommendation.providerId, "opencode-go")
        XCTAssertEqual(advice.recommendation.reasonCodes, [.singleEligibleProvider, .incompleteSnapshot])
    }

    func testUnconfiguredProviderDoesNotBlockAConfidentAnswer() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
            .commandCode: state(.commandCode, windows: [], completeness: .failed,
                                probeState: .noCredentials),
        ], now: now, providers: [.go, .commandCode])
        XCTAssertEqual(advice.recommendation.status, .ok)
        XCTAssertEqual(advice.recommendation.providerId, "opencode-go")
        XCTAssertEqual(advice.providers.last?.eligibility, .unknown, "still listed, still explained")
        XCTAssertEqual(advice.providers.last?.reasonCodes, [.providerUnconfigured])
    }

    func testConfiguredProviderWithAFailedProbeStillCountsAsUnresolved() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
            .codex: state(windows: [], completeness: .failed, probeState: .offline, probeMessage: "offline"),
        ], now: now, providers: [.go, .codex])
        XCTAssertEqual(advice.recommendation.status, .conditional)
        XCTAssertEqual(advice.recommendation.reasonCodes, [.singleEligibleProvider, .incompleteSnapshot])
    }

    func testNoReadingsAtAllIsNotEmptyButHonest() {
        let advice = Advisor.evaluate(states: [:], now: now)
        XCTAssertEqual(advice.recommendation.status, .unknown)
        XCTAssertEqual(advice.recommendation.summary, "No provider can be proven usable right now")
        XCTAssertEqual(advice.providers.count, ProviderID.allCases.count)
    }

    /// A provider with no state has not answered yet; it is unresolved, not
    /// absent. One fresh reading must not produce a confident answer while two
    /// cards are still checking.
    func testMissingProvidersAreUnresolvedNotAbsent() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 20), ("go.weekly", 30), ("go.monthly", 10)])),
        ], now: now)
        XCTAssertNotEqual(advice.recommendation.status, .ok)
        XCTAssertEqual(advice.recommendation.status, .conditional)
        XCTAssertEqual(advice.recommendation.providerId, "opencode-go")
        XCTAssertEqual(advice.recommendation.reasonCodes, [.singleEligibleProvider, .incompleteSnapshot])
    }

    /// The provider's own flag names the window; the highest percentage does
    /// not. A 95% window that was never flagged must not be called "limit
    /// reached" because a 70% window was.
    func testExhaustionNamesTheFlaggedWindowNotTheHighestOne() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: [
                QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour", percent: 70,
                            resetsAt: nil, windowMinutes: 300, isLimited: true),
                QuotaWindow(id: "codex.secondary", kind: .secondary, label: "Weekly", percent: 95,
                            resetsAt: nil, windowMinutes: 10_080, isLimited: false),
            ]),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .exhausted)
        XCTAssertEqual(advice.limitingWindowId, "codex.primary")
        XCTAssertEqual(advice.headline, "5-hour limit reached")
    }

    func testHundredPercentWithoutAFlagIsCapacityNotALimit() {
        let advice = Advisor.evaluate(
            provider: .codex,
            state: state(windows: [
                QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour", percent: 100,
                            resetsAt: nil, windowMinutes: 300, isLimited: false),
            ]),
            now: now
        )
        XCTAssertEqual(advice.eligibility, .exhausted)
        XCTAssertEqual(advice.headline, "5-hour at 100% used")
        XCTAssertFalse(advice.headline.lowercased().contains("limit reached"))
    }

    /// Command Code reports a 429 as a failed probe; the advice must say
    /// "rate limited", not "probe failed".
    func testRateLimitedWinsOverTheFailureBranch() {
        let advice = Advisor.evaluate(
            provider: .commandCode,
            state: state(.commandCode, windows: [], completeness: .failed, probeState: .rateLimited),
            now: now
        )
        XCTAssertEqual(advice.reasonCodes, [.rateLimited])
    }

    func testTwoViableProvidersIsUnknown() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
            .codex: state(windows: windows([("codex.primary", 30)])),
        ], now: now, providers: [.go, .codex])
        XCTAssertEqual(advice.recommendation.status, .unknown)
        XCTAssertNil(advice.recommendation.providerId)
        XCTAssertEqual(advice.recommendation.reasonCodes, [.multipleViableProviders])
    }

    func testNothingEligibleIsUnknown() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 100)], limited: ["go.rolling"])),
        ], now: now, providers: [.go])
        XCTAssertEqual(advice.recommendation.status, .unknown)
        XCTAssertEqual(advice.recommendation.reasonCodes, [.noEligibleProvider])
    }

    func testEmptyProviderListSaysSo() {
        let advice = Advisor.evaluate(states: [:], now: now, providers: [])
        XCTAssertEqual(advice.recommendation.status, .unknown)
        XCTAssertEqual(advice.recommendation.summary, "No providers configured")
    }

    func testDocumentCarriesNoScoresOrConfidence() {
        let advice = Advisor.evaluate(states: [
            .go: state(.go, windows: windows([("go.rolling", 30)])),
        ], now: now, taskMinutes: 60)
        XCTAssertEqual(advice.scope, "provider")
        XCTAssertEqual(advice.taskMinutes, 60)
        XCTAssertEqual(advice.schemaVersion, 1)
        let lowercased = advice.providers.map(\.headline).joined().lowercased()
        XCTAssertFalse(lowercased.contains("confidence"))
        XCTAssertFalse(lowercased.contains("best"))
        XCTAssertFalse(lowercased.contains("score"))
    }
}
