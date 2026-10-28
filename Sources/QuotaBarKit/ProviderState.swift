import Foundation

// MARK: - Current provider state
//
// The history table answers "how did I get here?" by storing one row per
// window. That shape cannot answer "what is true right now?": windows from two
// different probes — or two different accounts — could be stitched together by
// a reader that takes the newest row per window.
//
// A ProviderState is the opposite: one atomic record per provider, written
// whole or not at all, carrying everything a decision needs (origin, age,
// completeness, probe outcome, plan, account). History is untouched; this is an
// additive projection used by the advisor and only by the advisor.

public enum ObservationCompleteness: String, Codable, Equatable, Sendable {
    /// A single probe answered with the windows this provider exposes.
    case complete
    /// We have numbers, but they are not a live reading (stale or local-log).
    case partial
    /// The last probe failed; any windows shown are a retained older reading.
    case failed
}

/// The windows a provider must expose for a reading to be usable as evidence.
///
/// "Complete" cannot mean "the adapter returned something": every adapter drops
/// windows it cannot parse, so a reply that lost its 5-hour bucket but kept the
/// weekly one would otherwise look complete and could be read as headroom on a
/// limit we never saw. Plan-dependent extras (Codex additional buckets, Command
/// Code's monthly percentage) are not required; every window that can be the
/// limiting one on a normal plan is.
public enum ProviderWindows {
    public static func requiredIDs(_ provider: ProviderID) -> [String] {
        switch provider {
        // Go's monthly allowance can be the limiting window on its own (the
        // live reading on this machine is exhausted exactly there), so it is
        // required evidence, not an optional extra.
        case .go: return ["go.rolling", "go.weekly", "go.monthly"]
        case .codex: return ["codex.primary", "codex.secondary"]
        case .commandCode: return ["commandcode.5h", "commandcode.weekly"]
        }
    }

    public static func missing(in snapshot: ProviderSnapshot) -> [String] {
        let present = Set(snapshot.windows.map(\.id))
        return requiredIDs(snapshot.provider).filter { !present.contains($0) }
    }
}

public struct ProviderState: Codable, Equatable, Sendable {
    public let provider: ProviderID
    /// Monotonic per provider, bumped on every write. Two records with
    /// different generations are never comparable, and a reader can tell that
    /// the windows in a record were written together.
    public let generation: Int
    /// When the windows were observed. Nil when nothing was ever observed.
    public let observedAt: Date?
    public let origin: SnapshotOrigin?
    public let source: String?
    public let plan: String?
    public let accountRef: String?
    public let completeness: ObservationCompleteness
    /// Result of the most recent probe attempt (success or failure), which is
    /// not the same thing as the age of the windows above.
    public let probeState: HealthState?
    public let probeMessage: String?
    public let probeAt: Date?
    public let windows: [QuotaWindow]
    public let facts: [String]

    public init(
        provider: ProviderID,
        generation: Int,
        observedAt: Date?,
        origin: SnapshotOrigin?,
        source: String?,
        plan: String?,
        accountRef: String?,
        completeness: ObservationCompleteness,
        probeState: HealthState?,
        probeMessage: String?,
        probeAt: Date?,
        windows: [QuotaWindow],
        facts: [String]
    ) {
        self.provider = provider
        self.generation = generation
        self.observedAt = observedAt
        self.origin = origin
        self.source = source
        self.plan = plan
        self.accountRef = accountRef
        self.completeness = completeness
        self.probeState = probeState
        self.probeMessage = probeMessage
        self.probeAt = probeAt
        self.windows = windows
        self.facts = facts
    }

    /// Whether this provider is part of the user's setup at all. A missing
    /// credential is not an alternative to weigh: nothing is installed to use.
    /// A configured provider whose probe failed for any other reason still
    /// counts, because the user expects it to be usable.
    public var isConfigured: Bool {
        !(completeness == .failed && probeState == .noCredentials)
    }

    /// Next state after a probe result. Pure, so the transition rules are
    /// testable without a store, a network or a clock.
    ///
    /// - A successful probe replaces the record; a network reading that lost a
    ///   required window is `partial`, never `complete`.
    /// - A stale probe keeps its numbers but is marked `partial`.
    /// - A failed probe never invents quota: it keeps the previous windows
    ///   verbatim, marks the record `failed`, and records the new probe outcome.
    /// - An account change drops the previous windows entirely: they belong to
    ///   someone else and must not be relabelled.
    public static func next(
        _ previous: ProviderState?,
        result: ProbeResult,
        provider: ProviderID,
        now: Date
    ) -> ProviderState {
        let generation = (previous?.generation ?? 0) + 1
        switch result {
        case let .ok(snapshot):
            let missing = ProviderWindows.missing(in: snapshot)
            return ProviderState(
                provider: provider,
                generation: generation,
                observedAt: snapshot.observedAt,
                origin: snapshot.origin,
                source: snapshot.source,
                plan: snapshot.plan,
                accountRef: snapshot.accountRef,
                completeness: snapshot.origin == .network && missing.isEmpty ? .complete : .partial,
                probeState: .ok,
                probeMessage: nil,
                probeAt: now,
                windows: snapshot.windows,
                facts: snapshot.facts
            )
        case let .stale(snapshot, health, message):
            let accountChanged = differs(previous?.accountRef, snapshot.accountRef)
            return ProviderState(
                provider: provider,
                generation: generation,
                observedAt: snapshot.observedAt,
                origin: snapshot.origin,
                source: snapshot.source,
                plan: snapshot.plan,
                accountRef: snapshot.accountRef,
                completeness: .partial,
                probeState: health,
                probeMessage: message,
                probeAt: now,
                windows: accountChanged ? [] : snapshot.windows,
                facts: accountChanged ? [] : snapshot.facts
            )
        case let .failed(health, message):
            return ProviderState(
                provider: provider,
                generation: generation,
                observedAt: previous?.observedAt,
                origin: previous?.origin,
                source: previous?.source,
                plan: previous?.plan,
                accountRef: previous?.accountRef,
                completeness: .failed,
                probeState: health,
                probeMessage: message,
                probeAt: now,
                windows: previous?.windows ?? [],
                facts: previous?.facts ?? []
            )
        }
    }

    static func differs(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        return lhs != rhs
    }
}
