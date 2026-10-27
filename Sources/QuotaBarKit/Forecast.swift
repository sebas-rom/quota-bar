import Foundation

// MARK: - Forecast
//
// A deliberately conservative 5-hour-window forecast. It answers one question:
// "at the recent net rate, will this window reach 95% before it resets?"
//
// Guards exist so the UI can abstain instead of guessing: fresh network data,
// enough samples and span, no large gaps, a stable reset boundary, a measurable
// positive rate, a 15-minute reset margin, and a two-hour horizon.

public struct ForecastSample: Equatable, Sendable {
    public let at: Date
    public let percent: Double
    public let resetsAt: Date?
    public let origin: SnapshotOrigin

    public init(at: Date, percent: Double, resetsAt: Date?, origin: SnapshotOrigin) {
        self.at = at
        self.percent = percent
        self.resetsAt = resetsAt
        self.origin = origin
    }
}

public enum ForecastState: Equatable, Sendable {
    case unavailable(String)
    case collecting
    case approaching95(minutes: Int, resetMinutes: Int)
    case below95(resetMinutes: Int)
    case already95(resetMinutes: Int)
}

public enum ForecastEngine {
    public static let threshold: Double = 95
    public static let lookback: TimeInterval = 60 * 60
    public static let minimumSamples = 7
    public static let minimumSpan: TimeInterval = 30 * 60
    public static let maximumGap: TimeInterval = 12 * 60
    public static let maximumAge: TimeInterval = 10 * 60
    public static let minimumNetRise: Double = 2
    public static let minimumResetMargin: TimeInterval = 15 * 60
    public static let maximumHorizon: TimeInterval = 2 * 60 * 60
    public static let resetStability: TimeInterval = 120

    public static func forecast(
        samples: [ForecastSample],
        now: Date,
        currentPercent: Double,
        resetAt: Date?,
        windowMinutes: Int
    ) -> ForecastState {
        guard let resetAt else { return .unavailable("reset time unknown") }
        let resetRemaining = resetAt.timeIntervalSince(now)
        guard resetRemaining >= minimumResetMargin else {
            return .unavailable("too close to reset")
        }

        let network = samples
            .filter { $0.origin == .network && $0.at <= now }
            .sorted { $0.at < $1.at }
        guard let latest = network.last else { return .collecting }
        guard now.timeIntervalSince(latest.at) <= maximumAge else {
            return .unavailable("stale")
        }

        // Only samples belonging to this reset boundary.
        let inCycle = network.filter { sample in
            guard let sampleReset = sample.resetsAt else { return false }
            return abs(sampleReset.timeIntervalSince(resetAt)) <= resetStability
                && sample.at >= now.addingTimeInterval(-lookback)
        }
        guard inCycle.count >= minimumSamples, let first = inCycle.first, let last = inCycle.last else {
            return .collecting
        }
        guard last.at.timeIntervalSince(first.at) >= minimumSpan else { return .collecting }

        for (a, b) in zip(inCycle, inCycle.dropFirst()) {
            if b.at.timeIntervalSince(a.at) > maximumGap {
                return .unavailable("sampling gap")
            }
        }

        let minutes = last.at.timeIntervalSince(first.at) / 60
        guard minutes > 0 else { return .collecting }
        let net = last.percent - first.percent
        guard net >= minimumNetRise else {
            // Not enough recent activity to say anything useful; a flat or
            // falling window must not produce a reassuring "won't hit" claim.
            return .collecting
        }
        let rate = net / minutes // percentage points per minute
        guard rate > 0 else { return .collecting }

        let percent = max(currentPercent, last.percent)
        if percent >= threshold {
            return .already95(resetMinutes: Int(resetRemaining / 60))
        }

        let etaSeconds = (threshold - percent) / rate * 60
        let margin = minimumResetMargin

        // A slow but real rate can still answer the useful question: it will not
        // reach 95% before this reset. The two-hour horizon only limits positive
        // "approaching" claims, not the negative one.
        if etaSeconds > resetRemaining + margin {
            return .below95(resetMinutes: Int(resetRemaining / 60))
        }
        if etaSeconds <= resetRemaining - margin {
            guard etaSeconds <= maximumHorizon else {
                return .unavailable("beyond horizon")
            }
            return .approaching95(
                minutes: max(1, Int((etaSeconds / 60).rounded())),
                resetMinutes: Int(resetRemaining / 60)
            )
        }
        return .unavailable("close to reset")
    }
}

public enum ForecastCopy {
    /// One subdued line under the 5-hour row. Collecting/unavailable states are
    /// intentionally silent: they belong in diagnostics, not in the popover.
    public static func line(for state: ForecastState, now: Date = Date()) -> String? {
        switch state {
        case let .approaching95(minutes, resetMinutes):
            return "At recent pace: ~\(duration(minutes)) to 95% · resets in \(duration(resetMinutes))"
        case let .below95(resetMinutes):
            return "At recent pace: below 95% until reset (~\(duration(resetMinutes)))"
        case let .already95(resetMinutes):
            return "95% reached · resets in \(duration(resetMinutes))"
        case .collecting, .unavailable:
            return nil
        }
    }

    static func duration(_ minutes: Int) -> String {
        if minutes < 60 { return "\(minutes)m" }
        let h = minutes / 60
        let m = minutes % 60
        if h >= 24 {
            let d = h / 24
            return "\(d)d"
        }
        return m == 0 ? "\(h)h" : "\(h)h \(m)m"
    }
}
