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

public struct ForecastProjection: Equatable, Sendable {
    public let from: Date
    public let fromPercent: Double
    public let to: Date
    public let toPercent: Double
}

public struct ForecastAnalysis: Equatable, Sendable {
    public let state: ForecastState
    public let ratePerMinute: Double?
    public let lastAt: Date?
    public let lastPercent: Double?
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
        analyze(
            samples: samples, now: now, currentPercent: currentPercent,
            resetAt: resetAt, windowMinutes: windowMinutes
        ).state
    }

    public static func projection(
        samples: [ForecastSample],
        now: Date,
        currentPercent: Double,
        resetAt: Date?,
        windowMinutes: Int
    ) -> ForecastProjection? {
        let analysis = analyze(
            samples: samples, now: now, currentPercent: currentPercent,
            resetAt: resetAt, windowMinutes: windowMinutes
        )
        guard let resetAt,
              let rate = analysis.ratePerMinute,
              let lastAt = analysis.lastAt,
              let lastPercent = analysis.lastPercent else { return nil }
        switch analysis.state {
        case .approaching95, .below95:
            break
        default:
            return nil
        }

        let horizonEnd = now.addingTimeInterval(maximumHorizon)
        let end = min(resetAt, horizonEnd)
        guard end > lastAt else { return nil }
        let projected = lastPercent + rate * (end.timeIntervalSince(lastAt) / 60)
        return ForecastProjection(
            from: lastAt,
            fromPercent: lastPercent,
            to: end,
            toPercent: min(100, max(lastPercent, projected))
        )
    }

    public static func analyze(
        samples: [ForecastSample],
        now: Date,
        currentPercent: Double,
        resetAt: Date?,
        windowMinutes: Int
    ) -> ForecastAnalysis {
        func result(_ state: ForecastState, rate: Double? = nil, last: ForecastSample? = nil) -> ForecastAnalysis {
            ForecastAnalysis(state: state, ratePerMinute: rate, lastAt: last?.at, lastPercent: last?.percent)
        }
        guard let resetAt else { return result(.unavailable("reset time unknown")) }
        let resetRemaining = resetAt.timeIntervalSince(now)
        guard resetRemaining >= minimumResetMargin else {
            return result(.unavailable("too close to reset"))
        }

        let network = samples
            .filter { $0.origin == .network && $0.at <= now }
            .sorted { $0.at < $1.at }
        guard let latest = network.last else { return result(.collecting) }
        guard now.timeIntervalSince(latest.at) <= maximumAge else {
            return result(.unavailable("stale"))
        }

        let inCycle = network.filter { sample in
            guard let sampleReset = sample.resetsAt else { return false }
            return abs(sampleReset.timeIntervalSince(resetAt)) <= resetStability
                && sample.at >= now.addingTimeInterval(-lookback)
        }
        guard inCycle.count >= minimumSamples, let first = inCycle.first, let last = inCycle.last else {
            return result(.collecting)
        }
        guard last.at.timeIntervalSince(first.at) >= minimumSpan else { return result(.collecting) }

        for (a, b) in zip(inCycle, inCycle.dropFirst()) {
            if b.at.timeIntervalSince(a.at) > maximumGap {
                return result(.unavailable("sampling gap"))
            }
        }

        let minutes = last.at.timeIntervalSince(first.at) / 60
        guard minutes > 0 else { return result(.collecting) }
        let net = last.percent - first.percent
        guard net >= minimumNetRise else { return result(.collecting) }
        let rate = net / minutes
        guard rate > 0 else { return result(.collecting) }

        let percent = max(currentPercent, last.percent)
        if percent >= threshold {
            return result(.already95(resetMinutes: Int(resetRemaining / 60)), rate: rate, last: last)
        }

        let etaSeconds = (threshold - percent) / rate * 60
        let margin = minimumResetMargin

        if etaSeconds > resetRemaining + margin {
            return result(.below95(resetMinutes: Int(resetRemaining / 60)), rate: rate, last: last)
        }
        if etaSeconds <= resetRemaining - margin {
            guard etaSeconds <= maximumHorizon else {
                return result(.unavailable("beyond horizon"), rate: rate, last: last)
            }
            return result(
                .approaching95(
                    minutes: max(1, Int((etaSeconds / 60).rounded())),
                    resetMinutes: Int(resetRemaining / 60)
                ),
                rate: rate, last: last
            )
        }
        return result(.unavailable("close to reset"), rate: rate, last: last)
    }
}

public enum ForecastCopy {
    /// One subdued line under the 5-hour row. Collecting/unavailable states are
    /// intentionally silent: they belong in diagnostics, not in the popover.
    public static func line(for state: ForecastState, now: Date = Date()) -> String? {
        switch state {
        case let .approaching95(minutes, _):
            return "Estimated at recent pace · 95% in ~\(duration(minutes))"
        case .below95:
            return "Estimated at recent pace · below 95% at reset"
        case let .already95(resetMinutes):
            return "95% reached · resets in \(duration(resetMinutes))"
        case .collecting, .unavailable:
            return nil
        }
    }

    /// Popover variant: reassurance ("below 95% at reset") is noise on a glance
    /// surface. Only projected risk earns a line; History keeps the full copy.
    public static func riskLine(for state: ForecastState) -> String? {
        switch state {
        case let .approaching95(minutes, _):
            return "Estimated at recent pace · 95% in ~\(duration(minutes))"
        case let .already95(resetMinutes):
            return "95% reached · resets in \(duration(resetMinutes))"
        case .below95, .collecting, .unavailable:
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
