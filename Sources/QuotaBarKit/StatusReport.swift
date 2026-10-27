import Foundation

// MARK: - Machine-readable status
//
// Read-only view of the latest persisted observation per provider/window.
// No credentials, prompts or account identities; freshness is explicit.

public struct StatusWindow: Codable, Equatable, Sendable {
    public let id: String
    public let label: String
    public let percentUsed: Double
    public let resetsAt: Date?
    public let observedAt: Date
    public let origin: String
    public let ageSeconds: Int
    public let stale: Bool
}

public struct StatusProvider: Codable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let plan: String?
    public let windows: [StatusWindow]
}

public struct StatusReport: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let generatedAt: Date
    public let staleAfterSeconds: Int
    public let fresh: Bool
    public let providers: [StatusProvider]

    public static func build(
        from observations: [TelemetryStore.LatestObservation],
        now: Date = Date(),
        staleAfter: TimeInterval = 900
    ) -> StatusReport {
        var grouped: [ProviderID: (plan: String?, windows: [StatusWindow])] = [:]
        for observation in observations {
            guard let provider = ProviderID(rawValue: observation.provider) else { continue }
            let age = max(0, Int(now.timeIntervalSince(observation.observedAt).rounded()))
            let stale = Double(age) >= staleAfter
            let window = StatusWindow(
                id: observation.windowID,
                label: observation.label,
                percentUsed: observation.percent,
                resetsAt: observation.resetsAt,
                observedAt: observation.observedAt,
                origin: observation.origin,
                ageSeconds: age,
                stale: stale
            )
            var entry = grouped[provider] ?? (nil, [])
            if entry.plan == nil, let plan = observation.plan { entry.plan = plan }
            entry.windows.append(window)
            grouped[provider] = entry
        }

        let providers = ProviderID.allCases.compactMap { provider -> StatusProvider? in
            guard let entry = grouped[provider] else { return nil }
            return StatusProvider(
                id: provider.rawValue,
                name: provider.displayName,
                plan: entry.plan,
                windows: entry.windows.sorted { $0.id < $1.id }
            )
        }
        let fresh = providers.contains { $0.windows.contains { !$0.stale } }
        return StatusReport(
            schemaVersion: 1,
            generatedAt: now,
            staleAfterSeconds: Int(staleAfter),
            fresh: fresh,
            providers: providers
        )
    }
}
