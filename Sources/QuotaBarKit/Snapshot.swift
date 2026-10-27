import Foundation

// MARK: - Normalized quota domain
//
// One shape for every provider: a provider owns windows, each window has a
// stable identity, a percentage, and (when the provider tells us) a reset.
// Nothing here is provider specific, so cards and charts never branch on
// provider identity.

public enum ProviderID: String, CaseIterable, Sendable {
    case go = "opencode-go"
    case codex = "codex"

    public var displayName: String {
        switch self {
        case .go: return "OpenCode Go"
        case .codex: return "Codex"
        }
    }

    public var shortName: String {
        switch self {
        case .go: return "Go"
        case .codex: return "Cx"
        }
    }
}

public enum WindowKind: String, Sendable {
    case rolling, weekly, monthly, primary, secondary, review, additional
}

public struct QuotaWindow: Identifiable, Equatable, Sendable {
    public let id: String
    public let kind: WindowKind
    public let label: String
    public let percent: Double
    public let resetsAt: Date?
    public let windowMinutes: Int?
    public let isLimited: Bool

    public init(id: String, kind: WindowKind, label: String, percent: Double,
                resetsAt: Date?, windowMinutes: Int?, isLimited: Bool) {
        self.id = id
        self.kind = kind
        self.label = label
        self.percent = percent
        self.resetsAt = resetsAt
        self.windowMinutes = windowMinutes
        self.isLimited = isLimited
    }
}

public enum SnapshotOrigin: String, Sendable {
    case network
    case localLog
    case demo
}

public struct ProviderSnapshot: Identifiable, Equatable, Sendable {
    public let provider: ProviderID
    public let windows: [QuotaWindow]
    public let plan: String?
    /// Short non-reversible reference, never an email or account id.
    public let accountRef: String?
    public let origin: SnapshotOrigin
    /// Human readable provenance, safe to display (path or endpoint name).
    public let source: String
    public let observedAt: Date
    /// Provider facts that are not quota windows (reset credits, balance).
    public let facts: [String]

    public var id: ProviderID { provider }
    public init(provider: ProviderID, windows: [QuotaWindow], plan: String? = nil,
                accountRef: String? = nil, origin: SnapshotOrigin, source: String,
                observedAt: Date, facts: [String] = []) {
        self.provider = provider
        self.windows = windows
        self.plan = plan
        self.accountRef = accountRef
        self.origin = origin
        self.source = source
        self.observedAt = observedAt
        self.facts = facts
    }

    /// The most-consumed usable window, the only thing the menu bar needs.
    public var limiting: QuotaWindow? {
        windows
            .filter { $0.percent.isFinite && $0.percent >= 0 }
            .max { $0.percent < $1.percent }
    }

    public func window(id: String) -> QuotaWindow? {
        windows.first { $0.id == id }
    }
}

public enum HealthState: Equatable, Sendable {
    case ok
    case noCredentials
    case authFailed
    case entitlementMissing
    case rateLimited
    case providerDown
    case offline
    case badResponse

    public var isHealthy: Bool { self == .ok }
}

public struct ProviderHealth: Equatable, Sendable {
    public let state: HealthState
    public let message: String?
    public let attemptedAt: Date

    public init(state: HealthState, message: String? = nil, attemptedAt: Date = Date()) {
        self.state = state
        self.message = message
        self.attemptedAt = attemptedAt
    }
}

public struct SamplePoint: Identifiable, Equatable, Sendable {
    public let at: Date
    public let percent: Double
    public var id: Date { at }

    public init(at: Date, percent: Double) {
        self.at = at
        self.percent = percent
    }
}

// MARK: - Display helpers

/// "just now", "4m ago", "2h 10m ago", "3d ago". Never returns nil.
public func freshnessText(for date: Date, now: Date = Date()) -> String {
    let secs = max(0, Int(now.timeIntervalSince(date)))
    if secs < 45 { return "just now" }
    let mins = secs / 60
    if mins < 60 { return "\(max(1, mins))m ago" }
    let hours = mins / 60
    if hours < 24 {
        let m = mins % 60
        return m == 0 ? "\(hours)h ago" : "\(hours)h \(m)m ago"
    }
    return "\(hours / 24)d ago"
}

/// Signed change between the first and last point, if that is meaningful.
public func deltaPoints(_ points: [SamplePoint]) -> Double? {
    guard let first = points.first, let last = points.last, points.count > 1 else { return nil }
    return last.percent - first.percent
}

/// Keeps charts cheap: buckets points into at most `max` slots, keeping the
/// last value in each bucket and always the newest point.
public func downsample(_ points: [SamplePoint], max limit: Int = 240) -> [SamplePoint] {
    guard limit > 2, points.count > limit else { return points }
    let sorted = points.sorted { $0.at < $1.at }
    guard let first = sorted.first?.at, let last = sorted.last?.at, last > first else { return sorted }
    let bucket = (last.timeIntervalSince(first)) / Double(limit - 1)
    guard bucket > 0 else { return sorted }
    func bucketIndex(_ point: SamplePoint) -> Int {
        Int(point.at.timeIntervalSince(first) / bucket)
    }
    // Keep the first point of each bucket, then always append the newest point
    // so a chart never ends before "now".
    var out: [SamplePoint] = [sorted[0]]
    out.reserveCapacity(limit + 1)
    for point in sorted.dropFirst() {
        if let last = out.last, bucketIndex(last) == bucketIndex(point) { continue }
        out.append(point)
    }
    if let newest = sorted.last, out.last != newest { out.append(newest) }
    return out
}

public func windowLabel(forSeconds seconds: Int?) -> String {
    guard let s = seconds, s > 0 else { return "Window" }
    let mins = s / 60
    if mins == 10_080 { return "Weekly" }
    if mins >= 1440, mins % 1440 == 0 { return mins == 1440 ? "Daily" : "\(mins / 1440)-day" }
    if mins % 60 == 0 { return "\(mins / 60)-hour" }
    return "\(max(1, mins))m"
}
