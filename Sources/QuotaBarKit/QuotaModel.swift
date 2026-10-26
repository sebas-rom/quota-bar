import Foundation
import Combine

// MARK: - Model
//
// Keeps the last good snapshot per provider, writes observations to the local
// store, and serves history to the UI. A failed probe never erases what we
// already know: the snapshot stays and its age is shown instead.

@MainActor
public final class QuotaModel: ObservableObject {
    @Published public private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    @Published public private(set) var health: [ProviderID: ProviderHealth] = [:]
    @Published public private(set) var refreshing = false
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var historyRevision = 0
    @Published public private(set) var storeIssue: String?
    @Published public private(set) var historyCount = 0

    public let isDemo: Bool
    public let store: TelemetryStore?

    private let probes: QuotaProbes
    private var timer: Timer?
    private var trendCache: [String: [SamplePoint]] = [:]
    private var lastPrune = Date.distantPast

    public init(probes: QuotaProbes = QuotaProbes(), store: TelemetryStore? = nil, isDemo: Bool = false) {
        self.probes = probes
        self.store = store
        self.isDemo = isDemo
    }

    /// Production instance: opens the on-disk store, degrading to memory-less
    /// mode (quota still works) if the store cannot be opened.
    public static func live() -> QuotaModel {
        do {
            let store = try TelemetryStore(path: TelemetryStore.defaultPath())
            let model = QuotaModel(store: store)
            model.historyCount = store.count()
            return model
        } catch {
            let model = QuotaModel()
            model.storeIssue = "History is off: \(error)."
            return model
        }
    }

    // MARK: lifecycle

    public func start() {
        seedFromLocalCodex()
        runCodexBackfillIfNeeded()
        Task { await refresh() }
        let timer = Timer(timeInterval: 300, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    public func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: refresh

    public func refresh() async {
        guard !refreshing else { return }
        refreshing = true
        defer { refreshing = false }

        async let goResult = probes.go()
        async let codexResult = probes.codex()
        let (go, codex) = await (goResult, codexResult)

        apply(go, provider: .go)
        apply(codex, provider: .codex)
        lastRefresh = Date()
        pruneIfNeeded()
        invalidateHistory()
    }

    private func apply(_ result: ProbeResult, provider: ProviderID) {
        switch result {
        case let .ok(snapshot):
            snapshots[provider] = snapshot
            health[provider] = ProviderHealth(state: .ok, attemptedAt: Date())
            store?.insert(snapshot)
        case let .stale(snapshot, state, message):
            snapshots[provider] = snapshot
            health[provider] = ProviderHealth(state: state, message: message, attemptedAt: Date())
            store?.insert(snapshot)
        case let .failed(state, message):
            // Keep the last good snapshot on purpose.
            health[provider] = ProviderHealth(state: state, message: message, attemptedAt: Date())
        }
    }

    private func pruneIfNeeded() {
        guard let store, Date().timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = Date()
        store.prune(olderThan: Date().addingTimeInterval(-90 * 86_400))
        historyCount = store.count()
    }

    // MARK: history

    public func invalidateHistory() {
        trendCache.removeAll()
        historyCount = store?.count() ?? 0
        historyRevision &+= 1
    }

    public func trend(provider: ProviderID, windowID: String, hours: Int = 24) -> [SamplePoint] {
        let key = "\(provider.rawValue)|\(windowID)|\(hours)"
        if let cached = trendCache[key] { return cached }
        guard let store else { return [] }
        let since = Date().addingTimeInterval(-Double(hours) * 3_600)
        let points = downsample(store.series(provider: provider, windowID: windowID, since: since), max: 240)
        trendCache[key] = points
        return points
    }

    public func historyWindowIDs(provider: ProviderID) -> [String] {
        store?.observedWindowIDs(provider: provider) ?? []
    }

    public func clearHistory() {
        store?.reset()
        // Keep the cleared state: a one-time Codex backfill must not resurrect
        // history the user just deleted.
        store?.setMeta("codex_backfill_v1", "cleared")
        invalidateHistory()
        lastPrune = Date()
    }

    // MARK: local Codex seeding + backfill

    /// Codex writes rate-limit snapshots into its own session log. Use the most
    /// recent one so the card is populated before the first network round-trip.
    private func seedFromLocalCodex() {
        guard snapshots[.codex] == nil, let local = CodexLocalLog.latest() else { return }
        let snapshot = ProviderSnapshot(
            provider: .codex,
            windows: local.windows,
            plan: local.plan,
            origin: .localLog,
            source: "Codex local session log",
            observedAt: local.observedAt
        )
        snapshots[.codex] = snapshot
        store?.insert(snapshot)
    }

    /// One-time import of the last 14 days of Codex rate-limit snapshots.
    /// Idempotent (primary key) and recorded in meta so it runs once.
    public func runCodexBackfillIfNeeded() {
        guard let store else { return }
        let marker = store.meta("codex_backfill_v1")
        guard marker == nil || marker == "running" else { return }
        store.setMeta("codex_backfill_v1", "running")
        Task.detached(priority: .utility) {
            let since = Date().addingTimeInterval(-14 * 86_400)
            let observations = CodexLocalLog.observations(since: since)
            for observation in observations {
                let snapshot = ProviderSnapshot(
                    provider: .codex,
                    windows: observation.windows,
                    plan: observation.plan,
                    origin: .localLog,
                    source: "Codex local session log",
                    observedAt: observation.observedAt
                )
                store.insert(snapshot)
            }
            store.setMeta("codex_backfill_v1", "\(observations.count)")
            await MainActor.run { [weak self] in
                self?.invalidateHistory()
            }
        }
    }

    // MARK: presentation

    public var barText: String {
        var parts: [String] = []
        for provider in ProviderID.allCases {
            if let limiting = snapshots[provider]?.limiting {
                parts.append("\(provider.shortName) \(Int(limiting.percent.rounded()))%")
            } else if health[provider]?.state == .noCredentials {
                continue
            } else {
                parts.append("\(provider.shortName) …")
            }
        }
        return parts.isEmpty ? "○" : parts.joined(separator: " · ")
    }

    public func staleness(for provider: ProviderID, now: Date = Date()) -> String? {
        guard let snapshot = snapshots[provider] else { return nil }
        let age = now.timeIntervalSince(snapshot.observedAt)
        let degraded = (health[provider]?.state ?? .ok) != .ok
        guard degraded || age > 900 else { return nil }
        return freshnessText(for: snapshot.observedAt, now: now)
    }

    public func provenance(for provider: ProviderID) -> String {
        guard let snapshot = snapshots[provider] else { return "—" }
        switch snapshot.origin {
        case .network: return snapshot.source
        case .localLog: return "local Codex log"
        case .demo: return "demo data"
        }
    }

    // MARK: key management

    public func validateAndSaveGoKey(_ raw: String) async -> String? {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return "Enter a key first." }
        let state = await probes.fetchGo(key: key, source: "entered key")
        switch state {
        case .ready:
            guard saveKeychainKey(account: quotaBarGoAccount, value: key) else {
                return "Key is valid but Keychain save failed."
            }
            await refresh()
            return nil
        case .authFailed:
            return "That key was rejected (401). Check for typos or generate a fresh Personal API key."
        case .subscriptionUnavailable:
            return "Key accepted but no Go subscription for it (403). Use the console Personal API key for the right workspace."
        case .rateLimitedHTTP:
            return "Rate limited (429). Wait a minute and try again."
        case .providerDown:
            return "opencode.ai is having issues (5xx). Try again later."
        case .offline:
            return "No connection. Check network and retry."
        case let .unexpected(m):
            return "Unexpected response (\(m)). The API may have changed — try again later."
        case .noKey:
            return "Enter a key first."
        }
    }

    public func forgetGoKey() {
        deleteKeychainKey(account: quotaBarGoAccount)
        health[.go] = ProviderHealth(state: .noCredentials, message: "Saved key removed.", attemptedAt: Date())
        snapshots[.go] = nil
        Task { await refresh() }
    }

    public var goKeyKnown: Bool { !goKeyCandidates().isEmpty }

    public var goKeySourceText: String {
        if isDemo { return "demo data" }
        if let snapshot = snapshots[.go], snapshot.origin == .network { return snapshot.source }
        if loadKeychainKey(account: quotaBarGoAccount) != nil { return "Keychain (saved)" }
        if !goKeyCandidates().isEmpty { return "opencode auth.json" }
        return "none"
    }

    // MARK: demo

    /// Only the demo harness calls this (`--demo`), never the shipped flow.
    public func ingestDemo(_ snapshot: ProviderSnapshot) {
        guard isDemo else { return }
        snapshots[snapshot.provider] = snapshot
        health[snapshot.provider] = ProviderHealth(state: .ok, attemptedAt: Date())
        lastRefresh = Date()
        invalidateHistory()
    }
}
