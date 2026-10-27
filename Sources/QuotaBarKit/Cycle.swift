import Foundation

// MARK: - Quota cycles
//
// A cycle is the observation frame the user actually cares about: from the
// start of the current quota window to its reset. Boundaries are either exact
// (provider-supplied billing period), derived from a known duration and reset,
// or estimated (a monthly window inferred from its 30-day length).

public enum CycleProvenance: String, Sendable {
    case exact
    case derived
    case estimated
}

public struct QuotaCycle: Identifiable, Equatable, Sendable {
    public let provider: ProviderID
    public let windowID: String
    public let start: Date
    public let end: Date
    public let provenance: CycleProvenance
    public let isCurrent: Bool

    public var id: String { "\(windowID)|\(Int(end.timeIntervalSince1970))" }

    public init(provider: ProviderID, windowID: String, start: Date, end: Date,
                provenance: CycleProvenance, isCurrent: Bool) {
        self.provider = provider
        self.windowID = windowID
        self.start = start
        self.end = end
        self.provenance = provenance
        self.isCurrent = isCurrent
    }

    public var durationMinutes: Int { max(1, Int(end.timeIntervalSince(start) / 60)) }
}
