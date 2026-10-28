import Foundation

// MARK: - Subscription advisor
//
// Answers one narrow question: **which provider currently has headroom for
// another task?** It is deliberately not a score, a ranking or a prediction.
//
// The units are not comparable across providers — Go reports percent of a
// per-model monthly allowance, Command Code reports credit-value units against
// a 5-hour and a weekly cap, Codex reports plan- and model-dependent buckets —
// so the advisor never claims "X is better than Y". It only claims:
//
//   * available  — a fresh, complete network observation with headroom
//   * constrained — available, but the limiting window is close to its cap
//   * exhausted  — a window reports the limit reached (authoritative)
//   * unknown    — anything we cannot prove (stale, partial, local log,
//                  failed probe, no observation, missing windows)
//
// A recommendation is emitted only in the one case the evidence supports:
// exactly one provider is eligible and every alternative is positively
// ineligible. Two viable providers produce "unknown", not an arbitrary winner.

public enum Eligibility: String, Codable, Equatable, Sendable {
    case available
    case constrained
    case exhausted
    case unknown
}

public enum AdviceReason: String, Codable, Equatable, Sendable {
    // data quality
    case noObservation = "no_observation"
    case probeFailed = "probe_failed"
    case stale
    case localLogOnly = "local_log_only"
    case incompleteSnapshot = "incomplete_snapshot"
    case rateLimited = "rate_limited"
    // eligibility
    case quotaExhausted = "quota_exhausted"
    case nearingLimit = "nearing_limit"
    case eligible
    case providerUnconfigured = "provider_unconfigured"
    // selection
    case singleEligibleProvider = "single_eligible_provider"
    case multipleViableProviders = "multiple_viable_providers"
    case noEligibleProvider = "no_eligible_provider"
}

public struct ProviderAdvice: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let eligibility: Eligibility
    public let limitingWindowId: String?
    public let reasonCodes: [AdviceReason]
    /// Compact human sentence. Never a promise; it restates the numbers.
    public let headline: String
}

public enum RecommendationStatus: String, Codable, Equatable, Sendable {
    case ok
    case conditional
    case unknown
}

public struct AdviceRecommendation: Codable, Equatable, Sendable {
    public let status: RecommendationStatus
    public let providerId: String?
    public let reasonCodes: [AdviceReason]
    public let summary: String
}

public struct Advice: Codable, Equatable, Sendable {
    /// Versioned independently of `--status-json` (which stays at 1).
    public let schemaVersion: Int
    public let generatedAt: Date
    /// `provider` scope: the decision is about account headroom, not about
    /// whether one specific model is routed to that provider. Model-level
    /// eligibility is not observable today and is never inferred.
    public let scope: String
    public let staleAfterSeconds: Int
    public let taskMinutes: Int?
    public let providers: [ProviderAdvice]
    public let recommendation: AdviceRecommendation

    public static let currentSchemaVersion = 1
}

public enum Advisor {
    /// A window this close to its cap is still usable, but worth flagging.
    public static let constrainedThreshold: Double = 90

    public static func evaluate(
        states: [ProviderID: ProviderState],
        now: Date = Date(),
        staleAfter: TimeInterval = 900,
        taskMinutes: Int? = nil,
        providers: [ProviderID] = ProviderID.allCases
    ) -> Advice {
        let advice = providers.map { provider in
            evaluate(provider: provider, state: states[provider], now: now, staleAfter: staleAfter)
        }
        // A provider that is explicitly unconfigured is listed but is not an
        // alternative. A provider with no state at all is *unresolved*, not
        // absent: it may simply not have answered yet, and "the only provider
        // with quota" would otherwise be said while two cards are still
        // checking.
        let participating = Set(
            providers.filter { states[$0]?.isConfigured ?? true }.map(\.rawValue)
        )
        return Advice(
            schemaVersion: Advice.currentSchemaVersion,
            generatedAt: now,
            scope: "provider",
            staleAfterSeconds: Int(staleAfter),
            taskMinutes: taskMinutes,
            providers: advice,
            recommendation: recommend(advice, participating: participating)
        )
    }

    public static func evaluate(
        provider: ProviderID,
        state: ProviderState?,
        now: Date = Date(),
        staleAfter: TimeInterval = 900
    ) -> ProviderAdvice {
        func unknown(_ code: AdviceReason, _ headline: String) -> ProviderAdvice {
            ProviderAdvice(
                id: provider.rawValue, name: provider.displayName,
                eligibility: .unknown, limitingWindowId: nil,
                reasonCodes: [code], headline: headline
            )
        }

        guard let state else {
            return unknown(.noObservation, "No reading yet")
        }
        if state.probeState == .rateLimited {
            // A 429 says "not now", which is evidence about the provider, not
            // about the remaining quota. Never turn it into 0%. Checked before
            // the failure branch because a 429 arrives as a failed probe.
            return unknown(.rateLimited, "Provider is rate limiting requests")
        }
        if state.completeness == .failed {
            if state.probeState == .noCredentials {
                // Distinct from a transient failure: the provider is not set up
                // at all, so "retry" is the wrong suggestion.
                return unknown(.providerUnconfigured, state.probeMessage ?? "No credentials")
            }
            return unknown(.probeFailed, state.probeMessage ?? "Last reading failed")
        }
        guard state.completeness == .complete, state.origin == .network else {
            if state.origin == .localLog {
                return unknown(.localLogOnly, "Local log only — not a live reading")
            }
            if state.origin == .network {
                return unknown(.incompleteSnapshot, "Reading is missing a required window")
            }
            return unknown(.incompleteSnapshot, "Reading is not a live network sample")
        }
        guard let observedAt = state.observedAt else {
            return unknown(.noObservation, "No reading yet")
        }
        let age = now.timeIntervalSince(observedAt)
        if age < 0 || age >= staleAfter {
            return unknown(.stale, "Reading is \(freshnessText(for: observedAt, now: now))")
        }
        let usable = state.windows.filter { $0.percent.isFinite && $0.percent >= 0 }
        guard !usable.isEmpty else {
            return unknown(.incompleteSnapshot, "No usable quota windows")
        }
        guard let limiting = usable.max(by: { $0.percent < $1.percent }) else {
            return unknown(.incompleteSnapshot, "No usable quota windows")
        }

        // Exhaustion has two strengths. A provider-reported flag is
        // authoritative and names the window it applies to; a computed 100% is
        // "at capacity", which must not borrow the provider's words.
        let flagged = usable.filter { $0.isLimited }
        let atCapacity = usable.filter { $0.percent >= 100 }
        let exhausted = (flagged.isEmpty ? atCapacity : flagged)
            .max { lhs, rhs in
                lhs.percent == rhs.percent ? lhs.id > rhs.id : lhs.percent < rhs.percent
            }

        let percent = Int(limiting.percent.rounded())
        let reset = remainingText(until: limiting.resetsAt, now: now).map { " · \($0)" } ?? ""

        if let exhausted {
            let exhaustedReset = remainingText(until: exhausted.resetsAt, now: now).map { " · \($0)" } ?? ""
            return ProviderAdvice(
                id: provider.rawValue, name: provider.displayName,
                eligibility: .exhausted, limitingWindowId: exhausted.id,
                reasonCodes: [.quotaExhausted],
                headline: exhausted.isLimited
                    ? "\(exhausted.label) limit reached\(exhaustedReset)"
                    : "\(exhausted.label) at 100% used\(exhaustedReset)"
            )
        }
        if limiting.percent >= constrainedThreshold {
            return ProviderAdvice(
                id: provider.rawValue, name: provider.displayName,
                eligibility: .constrained, limitingWindowId: limiting.id,
                reasonCodes: [.eligible, .nearingLimit],
                headline: "\(limiting.label) \(percent)% used\(reset)"
            )
        }
        return ProviderAdvice(
            id: provider.rawValue, name: provider.displayName,
            eligibility: .available, limitingWindowId: limiting.id,
            reasonCodes: [.eligible],
            headline: "\(limiting.label) \(percent)% used\(reset)"
        )
    }

    /// Selection rule: a recommendation needs one eligible provider and no
    /// unresolved alternative. Everything else is `unknown`.
    ///
    /// `participating` restricts the rule to providers that are part of the
    /// user's setup; a provider that was never configured cannot be an
    /// alternative, and must not force every answer into `conditional`.
    public static func recommend(
        _ providers: [ProviderAdvice],
        participating: Set<String>? = nil
    ) -> AdviceRecommendation {
        let candidates = participating.map { ids in
            providers.filter { ids.contains($0.id) }
        } ?? providers
        let viable = candidates.filter { $0.eligibility == .available || $0.eligibility == .constrained }
        let unresolved = candidates.filter { $0.eligibility == .unknown }
        let ineligible = candidates.filter { $0.eligibility == .exhausted }

        if viable.isEmpty {
            let summary: String
            if providers.isEmpty {
                summary = "No providers configured"
            } else if candidates.isEmpty {
                summary = "No provider is set up with a current reading"
            } else {
                summary = "No provider can be proven usable right now"
            }
            return AdviceRecommendation(
                status: .unknown, providerId: nil,
                reasonCodes: [.noEligibleProvider], summary: summary
            )
        }
        if viable.count > 1 {
            // "Still has quota" rather than "has headroom": a provider at 93%
            // is viable but not roomy, and the line must not oversell it.
            return AdviceRecommendation(
                status: .unknown, providerId: nil,
                reasonCodes: [.multipleViableProviders],
                summary: "\(viable.count) providers still have quota — pick by model or habit"
            )
        }
        let only = viable[0]
        if unresolved.isEmpty {
            let suffix = ineligible.isEmpty
                ? ""
                : " (\(ineligible.count) out of quota)"
            return AdviceRecommendation(
                status: .ok, providerId: only.id,
                reasonCodes: [.singleEligibleProvider],
                summary: "\(only.name) is the only provider with quota left\(suffix)"
            )
        }
        return AdviceRecommendation(
            status: .conditional, providerId: only.id,
            reasonCodes: [.singleEligibleProvider, .incompleteSnapshot],
            summary: "\(only.name) has headroom; \(unresolved.count) provider reading\(unresolved.count == 1 ? " is" : "s are") unknown"
        )
    }
}
