import Foundation

// MARK: - Quota alerts
//
// Deliberately small: one 90%-used warning per window cycle, plus one
// limit-reached escalation. No 75/97 tiers, no reset pings, no cross-provider
// suggestions, no quiet-hours engine (macOS Focus owns interruption).
//
// Only fresh, successful network snapshots are evaluated. Stale local-log
// fallbacks, history backfills and demo data never notify.

public enum AlertKind: String, Codable, Sendable {
    case warning
    case limit
}

public struct AlertDecision: Equatable, Sendable {
    public let provider: ProviderID
    public let windowID: String
    public let kind: AlertKind
    public let message: String
    public let identifier: String
    public let percent: Double
}

public struct AlertBatch: Equatable, Sendable {
    public let decision: AlertDecision
    public let additionalCount: Int
}

public enum AlertCoalescer {
    /// One panel/notification for a batch: limit beats warning, then the
    /// highest percentage. The remaining decisions are counted, not dropped
    /// (their dedupe state was persisted separately).
    public static func best(_ decisions: [AlertDecision]) -> AlertBatch? {
        guard !decisions.isEmpty else { return nil }
        let sorted = decisions.sorted { a, b in
            if a.kind != b.kind { return a.kind == .limit }
            return a.percent > b.percent
        }
        return AlertBatch(decision: sorted[0], additionalCount: decisions.count - 1)
    }
}

public struct AlertState: Codable, Equatable, Sendable {
    /// window id -> cycle key that was already warned (fixed-cycle windows)
    public var warned: [String: String] = [:]
    /// window id -> cycle key that already got the limit escalation
    public var limitWarned: [String: String] = [:]
    /// Sliding windows have no stable cycle key: they use a threshold episode
    /// that ends only on meaningful recovery, never on a moving reset.
    public var rollingWarned: Set<String> = []
    public var rollingLimited: Set<String> = []

    public init() {}

    // v0.9 persisted only `warned`/`limitWarned`; keep decoding those files.
    private enum CodingKeys: String, CodingKey {
        case warned, limitWarned, rollingWarned, rollingLimited
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        warned = try container.decodeIfPresent([String: String].self, forKey: .warned) ?? [:]
        limitWarned = try container.decodeIfPresent([String: String].self, forKey: .limitWarned) ?? [:]
        rollingWarned = try container.decodeIfPresent(Set<String>.self, forKey: .rollingWarned) ?? []
        rollingLimited = try container.decodeIfPresent(Set<String>.self, forKey: .rollingLimited) ?? []
    }
}

public enum AlertRules {
    public static let warningThreshold: Double = 90
    /// A sliding window re-arms only after it actually recovers; a reset
    /// timestamp that advances must never re-fire an alert.
    public static let recoveryThreshold: Double = 85

    public static func evaluate(
        _ snapshot: ProviderSnapshot,
        state: inout AlertState,
        now: Date = Date()
    ) -> [AlertDecision] {
        // Never notify from stale/local/backfill/demo observations.
        guard snapshot.origin == .network else { return [] }

        var decisions: [AlertDecision] = []
        for window in snapshot.windows where window.percent.isFinite {
            let id = window.id

            if WindowSemantics.isRolling(provider: snapshot.provider, window: window) {
                if window.percent < recoveryThreshold {
                    state.rollingWarned.remove(id)
                    state.rollingLimited.remove(id)
                    continue
                }
                if window.isLimited, !state.rollingLimited.contains(id) {
                    decisions.append(decision(snapshot, window, .limit, "e", now))
                    state.rollingLimited.insert(id)
                    state.rollingWarned.insert(id)
                    continue
                }
                if window.percent >= warningThreshold, !state.rollingWarned.contains(id) {
                    decisions.append(decision(snapshot, window, .warning, "e", now))
                    state.rollingWarned.insert(id)
                }
                continue
            }

            let cycle = cycleKey(for: window, snapshot: snapshot)

            if window.isLimited, state.limitWarned[id] != cycle {
                decisions.append(decision(snapshot, window, .limit, cycle, now))
                state.limitWarned[id] = cycle
                // The limit implies the warning is satisfied for this cycle.
                state.warned[id] = cycle
                continue
            }

            if window.percent >= warningThreshold, state.warned[id] != cycle {
                decisions.append(decision(snapshot, window, .warning, cycle, now))
                state.warned[id] = cycle
            }
        }
        return decisions
    }

    public static func message(
        provider: ProviderID,
        window: QuotaWindow,
        kind: AlertKind,
        now: Date = Date()
    ) -> String {
        let name = "\(provider.displayName) \(window.label.lowercased())"
        let reset = resetPhrase(window.resetsAt, now: now)
        switch kind {
        case .warning:
            return "\(name) quota is \(Int(window.percent.rounded()))% used. \(reset)"
        case .limit:
            return "\(name) limit reached. \(reset)"
        }
    }

    public static func resetPhrase(_ reset: Date?, now: Date = Date()) -> String {
        guard let reset, let text = resetText(until: reset, now: now) else {
            return "Reset time unavailable."
        }
        return text.prefix(1).uppercased() + text.dropFirst() + "."
    }

    /// Fixed cycles only. Reset timestamps are bucketed so provider jitter does
    /// not re-fire, and change when the window rolls. Sliding windows never use
    /// this key — their reset advances continuously (see `evaluate`).
    static func cycleKey(for window: QuotaWindow, snapshot: ProviderSnapshot) -> String {
        if let reset = window.resetsAt {
            return "r\(Int(reset.timeIntervalSince1970 / 300))"
        }
        // No reset information: fall back to a coarse bucket so a stuck reading
        // cannot spam. Missing resets are rare in practice.
        return "n\(Int(snapshot.observedAt.timeIntervalSince1970 / 21_600))"
    }

    private static func decision(
        _ snapshot: ProviderSnapshot,
        _ window: QuotaWindow,
        _ kind: AlertKind,
        _ cycle: String,
        _ now: Date
    ) -> AlertDecision {
        AlertDecision(
            provider: snapshot.provider,
            windowID: window.id,
            kind: kind,
            message: message(provider: snapshot.provider, window: window, kind: kind, now: now),
            identifier: "\(window.id).\(kind.rawValue).\(cycle)",
            percent: window.percent
        )
    }
}
