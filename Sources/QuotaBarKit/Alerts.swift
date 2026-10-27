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
}

public struct AlertState: Codable, Equatable, Sendable {
    /// window id -> cycle key that was already warned
    public var warned: [String: String] = [:]
    /// window id -> cycle key that already got the limit escalation
    public var limitWarned: [String: String] = [:]

    public init() {}
}

public enum AlertRules {
    public static let warningThreshold: Double = 90

    public static func evaluate(
        _ snapshot: ProviderSnapshot,
        state: inout AlertState,
        now: Date = Date()
    ) -> [AlertDecision] {
        // Never notify from stale/local/backfill/demo observations.
        guard snapshot.origin == .network else { return [] }

        var decisions: [AlertDecision] = []
        for window in snapshot.windows where window.percent.isFinite {
            let cycle = cycleKey(for: window, snapshot: snapshot)
            let id = window.id

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

    /// Stable for the lifetime of a window: reset timestamps are bucketed so
    /// provider jitter does not re-fire, and change when the window rolls.
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
            identifier: "\(window.id).\(kind.rawValue).\(cycle)"
        )
    }
}
