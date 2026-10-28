import XCTest
@testable import QuotaBarKit

/// `--advise-json` is a contract for agents, so the serialized shape matters as
/// much as the values: stable keys, snake_case reason codes, ISO-8601 dates, and
/// no number a consumer could mistake for confidence.
final class AdviceDocumentTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func advice() -> Advice {
        let window = QuotaWindow(id: "go.rolling", kind: .rolling, label: "5-hour",
                                 percent: 20, resetsAt: now.addingTimeInterval(7200),
                                 windowMinutes: 300, isLimited: false)
        let state = ProviderState(
            provider: .go, generation: 3, observedAt: now, origin: .network,
            source: "api.opencode.ai", plan: "go", accountRef: "abc",
            completeness: .complete, probeState: .ok, probeMessage: nil, probeAt: now,
            windows: [window], facts: []
        )
        return Advisor.evaluate(states: [.go: state], now: now, taskMinutes: 60, providers: [.go])
    }

    func testEncodedShape() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(advice())
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(root["schemaVersion"] as? Int, 1)
        XCTAssertEqual(root["scope"] as? String, "provider")
        XCTAssertEqual(root["taskMinutes"] as? Int, 60)
        XCTAssertEqual(root["staleAfterSeconds"] as? Int, 900)
        XCTAssertNotNil(root["generatedAt"] as? String)
        XCTAssertNil(root["confidence"], "there is no confidence score, by design")

        let providers = try XCTUnwrap(root["providers"] as? [[String: Any]])
        XCTAssertEqual(providers.count, 1)
        XCTAssertEqual(providers[0]["id"] as? String, "opencode-go")
        XCTAssertEqual(providers[0]["eligibility"] as? String, "available")
        XCTAssertEqual(providers[0]["reasonCodes"] as? [String], ["eligible"])
        XCTAssertEqual(providers[0]["limitingWindowId"] as? String, "go.rolling")

        let recommendation = try XCTUnwrap(root["recommendation"] as? [String: Any])
        XCTAssertEqual(recommendation["status"] as? String, "ok")
        XCTAssertEqual(recommendation["providerId"] as? String, "opencode-go")
        XCTAssertEqual(recommendation["reasonCodes"] as? [String], ["single_eligible_provider"])
    }

    func testEncodedDocumentRoundTrips() throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let original = advice()
        let decoded = try decoder.decode(Advice.self, from: encoder.encode(original))
        XCTAssertEqual(decoded, original)
    }

    func testReasonCodesAreStableSnakeCase() {
        let expected: [AdviceReason: String] = [
            .noObservation: "no_observation",
            .probeFailed: "probe_failed",
            .stale: "stale",
            .localLogOnly: "local_log_only",
            .incompleteSnapshot: "incomplete_snapshot",
            .rateLimited: "rate_limited",
            .quotaExhausted: "quota_exhausted",
            .nearingLimit: "nearing_limit",
            .eligible: "eligible",
            .providerUnconfigured: "provider_unconfigured",
            .singleEligibleProvider: "single_eligible_provider",
            .multipleViableProviders: "multiple_viable_providers",
            .noEligibleProvider: "no_eligible_provider",
        ]
        for (reason, raw) in expected {
            XCTAssertEqual(reason.rawValue, raw)
        }
    }

    func testEligibilityAndStatusVocabulary() {
        XCTAssertEqual(Eligibility.available.rawValue, "available")
        XCTAssertEqual(Eligibility.constrained.rawValue, "constrained")
        XCTAssertEqual(Eligibility.exhausted.rawValue, "exhausted")
        XCTAssertEqual(Eligibility.unknown.rawValue, "unknown")
        XCTAssertEqual(RecommendationStatus.ok.rawValue, "ok")
        XCTAssertEqual(RecommendationStatus.conditional.rawValue, "conditional")
        XCTAssertEqual(RecommendationStatus.unknown.rawValue, "unknown")
    }
}
