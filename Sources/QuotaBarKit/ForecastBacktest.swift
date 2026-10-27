import Foundation

// MARK: - Forecast replay
//
// Deterministic, read-only backtest of the 5-hour forecast. Predictions at a
// checkpoint may only use observations available at that checkpoint; outcomes
// are used solely for scoring. Incomplete, ongoing or ambiguous cycles are
// censored — never counted as a successful negative.

public struct BacktestCounts: Codable, Equatable, Sendable {
    public let completeCycles: Int
    public let crossingCycles: Int
    public let nonCrossingCycles: Int
    public let eligibleCheckpoints: Int
    public let classifiableCheckpoints: Int
    public let abstentions: Int
    public let excludedCheckpoints: Int
    public let truePositives: Int
    public let falsePositives: Int
    public let trueNegatives: Int
    public let falseNegatives: Int
}

public struct BacktestExcluded: Codable, Equatable, Sendable {
    /// The cycle had not reset yet at evaluation time.
    public let ongoingCycle: Int
    /// Reset happened, but start/end coverage or continuity was insufficient.
    public let incompleteCycle: Int
    public let samplingGap: Int
    /// Observations that could not be attributed to a cycle (missing reset).
    public let ambiguousReset: Int
    /// A crossing that no below-threshold observation brackets, so its time is
    /// interval-censored and the ETA is unknowable.
    public let unknownOutcome: Int
}

public struct BacktestMetrics: Codable, Equatable, Sendable {
    public let precision: Double?
    public let falsePositiveRate: Double?
    public let recallAt30m: Double?
    public let coverage: Double?
    public let etaMaeMinutes: Double?
    public let etaP90Minutes: Double?
}

public enum BacktestStatus: String, Codable, Sendable {
    case pass
    case fail
    case insufficientData = "insufficient_data"
}

public struct BacktestGroup: Codable, Equatable, Sendable {
    public let provider: String
    public let windowId: String
    public let status: BacktestStatus
    public let counts: BacktestCounts
    public let excluded: BacktestExcluded
    public let metrics: BacktestMetrics
}

public struct BacktestNotEvaluated: Codable, Equatable, Sendable {
    public let provider: String
    public let windowId: String
    public let reason: String

    public init(provider: String, windowId: String, reason: String) {
        self.provider = provider
        self.windowId = windowId
        self.reason = reason
    }
}

public struct BacktestReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let targetPercent: Double
    public let checkpointMinutes: Int
    public let status: BacktestStatus
    public let groups: [BacktestGroup]
    /// Windows the report deliberately does not score (sliding 5-hour windows).
    public let notEvaluated: [BacktestNotEvaluated]
}

public enum ForecastBacktest {
    public static let target: Double = 95
    public static let checkpoint: TimeInterval = 30 * 60
    public static let resetTolerance: TimeInterval = 120
    public static let nearEndTolerance: TimeInterval = 15 * 60
    /// The first observation of a cycle must arrive within this window of the
    /// cycle start, otherwise the earlier usage is unknown.
    public static let startTolerance: TimeInterval = 30 * 60
    public static let maximumCycleGap: TimeInterval = 30 * 60
    /// Lead time required for a crossing to count as a useful prediction.
    public static let usefulLead: TimeInterval = 30 * 60

    public static func evaluate(
        provider: ProviderID,
        windowID: String,
        windowMinutes: Int,
        samples: [ForecastSample],
        now: Date = Date()
    ) -> BacktestGroup {
        var complete = 0
        var crossingCycles = 0
        var nonCrossingCycles = 0
        var eligible = 0
        var classifiable = 0
        var abstentions = 0
        var excludedCheckpoints = 0
        var tp = 0, fp = 0, tn = 0, fn = 0
        var etaErrors: [Double] = []
        var crossingWithOpportunity = 0
        var crossingDetected30 = 0
        var ongoing = 0, incomplete = 0, gaps = 0, ambiguous = 0, unknown = 0

        let network = samples
            .filter { $0.origin == .network && $0.at <= now }
            .sorted { $0.at < $1.at }
        // An observation with no reset cannot be attributed to any cycle; it is
        // reported as ambiguous rather than silently dropped.
        ambiguous += network.filter { $0.resetsAt == nil }.count

        // Reset grouping uses a tolerance scan, not fixed-width buckets.
        var clusters: [(reset: Date, samples: [ForecastSample])] = []
        for sample in network {
            guard let reset = sample.resetsAt else { continue }
            if let index = clusters.lastIndex(where: { abs($0.reset.timeIntervalSince(reset)) <= resetTolerance }) {
                clusters[index].samples.append(sample)
            } else {
                clusters.append((reset, [sample]))
            }
        }

        for cluster in clusters {
            let reset = cluster.reset
            // A cycle that has not reset yet cannot be scored: a crossing is
            // still possible.
            guard reset <= now else {
                ongoing += 1
                continue
            }
            let start = reset.addingTimeInterval(-Double(windowMinutes) * 60)
            let cycleSamples = cluster.samples
                .filter { $0.at >= start && $0.at < reset }
                .sorted { $0.at < $1.at }

            guard cycleSamples.count >= 2, let first = cycleSamples.first, let last = cycleSamples.last else {
                incomplete += 1
                continue
            }
            var hasGap = false
            for (a, b) in zip(cycleSamples, cycleSamples.dropFirst()) where b.at.timeIntervalSince(a.at) > maximumCycleGap {
                hasGap = true
            }
            if hasGap {
                gaps += 1
                continue
            }
            // Both ends must be observed: a late first sample means the early
            // cycle is unknown, so a "did not cross" verdict would be a guess.
            let startCovered = first.at.timeIntervalSince(start) <= startTolerance
            let endCovered = last.at.timeIntervalSince(reset) >= -nearEndTolerance
            if !startCovered || !endCovered {
                incomplete += 1
                continue
            }

            let crossingIndex = cycleSamples.firstIndex { $0.percent >= target }
            var crossingTime: Date?
            if let crossingIndex {
                // A crossing must be bracketed by a below-threshold observation;
                // otherwise its time is interval-censored and ETA is undefined.
                guard crossingIndex > 0, cycleSamples[crossingIndex - 1].percent < target else {
                    unknown += 1
                    continue
                }
                crossingTime = cycleSamples[crossingIndex].at
                crossingCycles += 1
            } else {
                nonCrossingCycles += 1
            }
            complete += 1

            var cycleHadOpportunity = false
            var cycleDetected30 = false

            var checkpointAt = start.addingTimeInterval(checkpoint)
            while checkpointAt <= reset.addingTimeInterval(-checkpoint) {
                defer { checkpointAt = checkpointAt.addingTimeInterval(checkpoint) }
                let available = cycleSamples.filter { $0.at <= checkpointAt }
                guard let latest = available.last else {
                    excludedCheckpoints += 1
                    continue
                }
                let lead = crossingTime.map { $0.timeIntervalSince(checkpointAt) }
                if let lead, lead <= 0 {
                    // Already crossed; retrospective state, not a prediction.
                    excludedCheckpoints += 1
                    continue
                }

                eligible += 1
                if lead == nil || lead! >= usefulLead { cycleHadOpportunity = true }

                let analysis = ForecastEngine.analyze(
                    samples: available,
                    now: checkpointAt,
                    currentPercent: latest.percent,
                    resetAt: reset,
                    windowMinutes: windowMinutes
                )

                switch analysis.state {
                case let .approaching95(minutes, _):
                    classifiable += 1
                    if let lead {
                        tp += 1
                        etaErrors.append(abs(Double(minutes) - lead / 60))
                        if lead >= usefulLead { cycleDetected30 = true }
                    } else {
                        fp += 1
                    }
                case .below95:
                    classifiable += 1
                    if lead != nil {
                        fn += 1
                    } else {
                        tn += 1
                    }
                case .already95:
                    // Observed condition, not a prospective prediction.
                    eligible -= 1
                    excludedCheckpoints += 1
                case .collecting, .unavailable:
                    abstentions += 1
                }
            }

            if crossingTime != nil, cycleHadOpportunity {
                crossingWithOpportunity += 1
                if cycleDetected30 { crossingDetected30 += 1 }
            }
        }

        let precision = ratio(tp, tp + fp)
        let fpr = ratio(fp, fp + tn)
        let coverage = ratio(classifiable, classifiable + abstentions)
        let mae = etaErrors.isEmpty ? nil : etaErrors.reduce(0, +) / Double(etaErrors.count)
        let p90 = etaErrors.isEmpty ? nil : percentile(etaErrors, 0.9)
        // Recall is opportunity-based: every crossing cycle that offered a
        // usable checkpoint counts, whether or not the engine spoke.
        let recall = ratio(crossingDetected30, crossingWithOpportunity)

        let counts = BacktestCounts(
            completeCycles: complete,
            crossingCycles: crossingCycles,
            nonCrossingCycles: nonCrossingCycles,
            eligibleCheckpoints: eligible,
            classifiableCheckpoints: classifiable,
            abstentions: abstentions,
            excludedCheckpoints: excludedCheckpoints,
            truePositives: tp, falsePositives: fp,
            trueNegatives: tn, falseNegatives: fn
        )
        let excluded = BacktestExcluded(
            ongoingCycle: ongoing,
            incompleteCycle: incomplete,
            samplingGap: gaps,
            ambiguousReset: ambiguous,
            unknownOutcome: unknown
        )
        let metrics = BacktestMetrics(
            precision: precision,
            falsePositiveRate: fpr,
            recallAt30m: recall,
            coverage: coverage,
            etaMaeMinutes: mae,
            etaP90Minutes: p90
        )

        let enoughEvidence = complete >= 20
            && crossingCycles >= 8
            && nonCrossingCycles >= 8
            && classifiable >= 50
            && (tp + fp) >= 15
            && (tn + fn) >= 15

        let status: BacktestStatus
        if !enoughEvidence {
            status = .insufficientData
        } else if let precision, precision >= 0.85,
                  let fpr, fpr <= 0.10,
                  let recall, recall >= 0.5,
                  let mae, mae <= 20,
                  let p90, p90 <= 45 {
            status = .pass
        } else {
            status = .fail
        }

        return BacktestGroup(
            provider: provider.rawValue,
            windowId: windowID,
            status: status,
            counts: counts,
            excluded: excluded,
            metrics: metrics
        )
    }

    public static func report(
        groups: [BacktestGroup],
        notEvaluated: [BacktestNotEvaluated] = [],
        now: Date = Date()
    ) -> BacktestReport {
        let status: BacktestStatus
        if groups.isEmpty {
            status = .insufficientData
        } else if groups.contains(where: { $0.status == .fail }) {
            status = .fail
        } else if groups.contains(where: { $0.status == .insufficientData }) {
            status = .insufficientData
        } else {
            status = .pass
        }
        return BacktestReport(
            schemaVersion: 1,
            generatedAt: now,
            targetPercent: target,
            checkpointMinutes: Int(checkpoint / 60),
            status: status,
            groups: groups,
            notEvaluated: notEvaluated
        )
    }

    private static func ratio(_ numerator: Int, _ denominator: Int) -> Double? {
        guard denominator > 0 else { return nil }
        return Double(numerator) / Double(denominator)
    }

    private static func percentile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let index = min(sorted.count - 1, max(0, Int((Double(sorted.count - 1) * p).rounded())))
        return sorted[index]
    }
}
