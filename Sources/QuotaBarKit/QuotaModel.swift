import Foundation
import Combine

// MARK: - Backfill

/// Imports timestamped local Codex observations. Extracted so cancellation can
/// be proven deterministically instead of raced against a real importer.
public enum CodexBackfill {
    @discardableResult
    public static func importObservations(
        _ observations: [CodexLogObservation],
        into store: TelemetryStore,
        accountRef: String?,
        isCancelled: () -> Bool = { false }
    ) -> Int {
        var inserted = 0
        for observation in observations {
            if isCancelled() { break }
            inserted += store.insert(ProviderSnapshot(
                provider: .codex,
                windows: observation.windows,
                plan: observation.plan,
                accountRef: accountRef,
                origin: .localLog,
                source: "Codex local session log",
                observedAt: observation.observedAt
            ))
        }
        return inserted
    }
}

// MARK: - Presentation

public enum ProviderPresentation: Equatable, Sendable {
    case checking
    case unconfigured
    case available
    case degraded
    case needsAttention

    /// Pure state matrix: a probe failure never makes a provider disappear, and
    /// an unknown initial state is never presented as configured.
    public static func resolve(hasSnapshot: Bool, health: HealthState?) -> ProviderPresentation {
        if hasSnapshot {
            switch health {
            case .ok?: return .available
            default: return .degraded
            }
        }
        switch health {
        case nil: return .checking
        case .noCredentials?: return .unconfigured
        default: return .needsAttention
        }
    }
}

// MARK: - Model
//
// Keeps the last good snapshot per provider, writes observations to the local
// store, and serves history to the UI. A failed probe never erases what we
// already know: the snapshot stays and its age is shown instead.

@MainActor
public final class QuotaModel: ObservableObject {
    @Published public private(set) var snapshots: [ProviderID: ProviderSnapshot] = [:]
    /// Atomic current state per provider. Decisions read this, never the
    /// per-window history rows (which cannot prove the windows came from one
    /// probe, or one account).
    @Published public private(set) var providerStates: [ProviderID: ProviderState] = [:]
    /// True only after a complete refresh pass (Codex, Command Code **and** Go)
    /// has finished in this launch. The advice row waits for it, so persisted
    /// advice is never shown next to a card that is still checking.
    @Published public private(set) var hasFullRefresh = false
    @Published public private(set) var health: [ProviderID: ProviderHealth] = [:]
    @Published public private(set) var refreshing = false
    @Published public private(set) var lastRefresh: Date?
    @Published public private(set) var historyRevision = 0
    @Published public private(set) var storeIssue: String?
    @Published public private(set) var historyCount = 0

    public let isDemo: Bool
    public let store: TelemetryStore?
    /// Called for fresh, successful network snapshots only (never stale,
    /// backfilled or demo data). The app wires this to notifications.
    public var onNetworkSnapshot: ((ProviderSnapshot) -> Void)?

    private var probes: any ProbeProviding
    /// Builds the probe set for a newly selected source. Production always
    /// returns `QuotaProbes`; tests substitute a controllable fake.
    private let probeFactory: (CodexSource) -> any ProbeProviding
    private let defaults: UserDefaults
    private var timer: Timer?
    /// Bumped whenever the Codex source changes, so a result produced by the
    /// previous source cannot be applied after the user switched.
    private var sourceGeneration = 0
    private var pendingRefresh = false
    private var trendCache: [String: [SamplePoint]] = [:]
    private var lastPrune = Date.distantPast
    private var backfillTask: Task<Void, Never>?

    public init(
        probes: any ProbeProviding = QuotaProbes(),
        store: TelemetryStore? = nil,
        isDemo: Bool = false,
        defaults: UserDefaults = .standard,
        probeFactory: ((CodexSource) -> any ProbeProviding)? = nil
    ) {
        self.probes = probes
        self.store = store
        self.isDemo = isDemo
        self.defaults = defaults
        self.probeFactory = probeFactory ?? { QuotaProbes(codexSource: $0) }
    }

    /// Production instance: opens the on-disk store, degrading to memory-less
    /// mode (quota still works) if the store cannot be opened.
    ///
    /// `defaults` and `makeStore` exist for tests: the store-failure branch used
    /// to drop the user's chosen Codex source, which would quietly turn a
    /// strict local-only setting back into an HTTP request.
    public static func live(
        defaults: UserDefaults = .standard,
        makeStore: () throws -> TelemetryStore = { try TelemetryStore(path: TelemetryStore.defaultPath()) }
    ) -> QuotaModel {
        let source = CodexSource(rawValue: defaults.string(forKey: "CodexSource") ?? "") ?? .http
        do {
            let store = try makeStore()
            let model = QuotaModel(probes: QuotaProbes(codexSource: source), store: store, defaults: defaults)
            model.historyCount = store.count()
            model.providerStates = store.providerStates()
            return model
        } catch {
            let model = QuotaModel(probes: QuotaProbes(codexSource: source), defaults: defaults)
            model.storeIssue = "History is off: \(error)."
            return model
        }
    }

    // MARK: codex source

    /// Which transport supplies Codex numbers. Persisted so the choice survives
    /// a relaunch, and applied immediately so the next refresh uses it.
    public var codexSource: CodexSource { probes.codexSource }

    public func setCodexSource(_ source: CodexSource) {
        defaults.set(source.rawValue, forKey: "CodexSource")
        guard probes.codexSource != source else { return }
        probes = probeFactory(source)
        sourceGeneration += 1
        Task { await refresh() }
    }

    // MARK: lifecycle

    public func start() {
        guard timer == nil else { return }
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
        guard !refreshing else {
            // A source switch (or a manual refresh) during a run must not be
            // dropped: run once more when the current pass finishes.
            pendingRefresh = true
            return
        }
        refreshing = true
        let generation = sourceGeneration
        defer {
            refreshing = false
            if pendingRefresh {
                pendingRefresh = false
                Task { await refresh() }
            }
        }

        let stamp = Date()
        async let goResult = probes.go(now: stamp)
        async let codexResult = probes.codex(now: stamp)
        async let commandCodeResult = probes.commandCode(now: stamp)

        // Apply the providers that cannot block on a system prompt first, so a
        // Keychain dialog can never hide fresh Codex/Command Code data.
        let codex = await codexResult
        if generation == sourceGeneration {
            apply(codex, provider: .codex)
        }
        apply(await commandCodeResult, provider: .commandCode)
        lastRefresh = Date()
        pruneIfNeeded()
        invalidateHistory()

        apply(await goResult, provider: .go)
        lastRefresh = Date()
        hasFullRefresh = true
        pruneIfNeeded()
        invalidateHistory()
    }

    private func apply(_ result: ProbeResult, provider: ProviderID) {
        let now = Date()
        switch result {
        case let .ok(snapshot):
            snapshots[provider] = snapshot
            health[provider] = ProviderHealth(state: .ok, attemptedAt: now)
            store?.insert(snapshot)
            if snapshot.origin == .network {
                onNetworkSnapshot?(snapshot)
            }
        case let .stale(snapshot, state, message):
            snapshots[provider] = snapshot
            health[provider] = ProviderHealth(state: state, message: message, attemptedAt: now)
            store?.insert(snapshot)
        case let .failed(state, message):
            // Keep the last good snapshot on purpose.
            health[provider] = ProviderHealth(state: state, message: message, attemptedAt: now)
        }
        recordState(provider: provider, result: result, now: now)
    }

    /// Persists the atomic current state. The transition rules live in
    /// `ProviderState.next` so they can be tested without a model.
    ///
    /// Publication follows the store, not the other way round: a write the store
    /// rejected because it predates Clear History must not reappear in memory
    /// either. A fresh failure with no retained evidence is allowed through
    /// (that is how "no credentials" reaches the advisor after a deletion).
    func recordState(provider: ProviderID, result: ProbeResult, now: Date) {
        let previous = providerStates[provider]
        let next = ProviderState.next(previous, result: result, provider: provider, now: now)
        guard let store else {
            providerStates[provider] = next
            return
        }
        switch store.saveProviderState(next) {
        case .saved:
            providerStates[provider] = next
        case .rejectedByCutoff:
            break
        case .failed:
            // Keep the in-memory view usable even when the disk write failed.
            providerStates[provider] = next
        }
    }

    private func pruneIfNeeded() {
        guard let store, Date().timeIntervalSince(lastPrune) > 86_400 else { return }
        lastPrune = Date()
        store.prune(olderThan: Date().addingTimeInterval(-90 * 86_400))
        historyCount = store.count()
    }

    /// Current advice from persisted atomic state. Read-only and side-effect
    /// free: the same function backs the popover row and `--advise-json`.
    public func advice(taskMinutes: Int? = nil, now: Date = Date()) -> Advice {
        Advisor.evaluate(states: providerStates, now: now, taskMinutes: taskMinutes)
    }

    // MARK: history

    public func invalidateHistory() {
        trendCache.removeAll()
        historyCount = store?.count() ?? 0
        historyRevision &+= 1
    }

    public func trend(provider: ProviderID, windowID: String, hours: Int = 24) -> [SamplePoint] {
        // Live rows are account-scoped; device-level local-log rows (null
        // account) are included and labelled in the UI, never presented as
        // belonging to the signed-in account.
        let accountRef = historyScopeRef(for: provider)
        let key = "\(provider.rawValue)|\(windowID)|\(hours)|\(accountRef ?? "-")"
        if let cached = trendCache[key] { return cached }
        guard let store else { return [] }
        let since = Date().addingTimeInterval(-Double(hours) * 3_600)
        let points = downsample(
            store.series(provider: provider, windowID: windowID, since: since, accountRef: accountRef),
            max: 240
        )
        trendCache[key] = points
        return points
    }

    /// Forecast for a single window. Only 5-hour (rolling) windows are shown;
    /// everything else abstains.
    public func forecast(for provider: ProviderID, window: QuotaWindow, now: Date = Date()) -> ForecastState {
        guard WindowSemantics.isForecastable(window: window),
              let store else { return .unavailable("not a 5-hour window") }
        let samples = store.forecastSamples(
            provider: provider,
            windowID: window.id,
            since: now.addingTimeInterval(-ForecastEngine.lookback),
            accountRef: historyScopeRef(for: provider)
        )
        return ForecastEngine.forecast(
            samples: samples,
            now: now,
            currentPercent: window.percent,
            resetAt: window.resetsAt,
            windowMinutes: window.windowMinutes ?? 0
        )
    }

    /// Sliding windows report a reset that advances with time; a fixed cycle
    /// frame would fragment their samples. Go's rolling 5h and Codex's primary
    /// 5h window behave this way; Command Code's 5h window is fixed.
    public func isRollingWindow(_ provider: ProviderID, _ window: QuotaWindow) -> Bool {
        WindowSemantics.isRolling(provider: provider, window: window)
    }

    public func trailingSamples(
        for provider: ProviderID,
        window: QuotaWindow,
        hours: Double = 5,
        now: Date = Date()
    ) -> [SamplePoint] {
        guard let store else { return [] }
        let samples = store.forecastSamples(
            provider: provider,
            windowID: window.id,
            since: now.addingTimeInterval(-hours * 3_600),
            accountRef: historyScopeRef(for: provider)
        )
        return downsample(samples.map { SamplePoint(at: $0.at, percent: $0.percent) }, max: 400)
    }

    public func forecastProjection(
        for provider: ProviderID,
        window: QuotaWindow,
        now: Date = Date()
    ) -> ForecastProjection? {
        guard WindowSemantics.isForecastable(window: window),
              let store else { return nil }
        let samples = store.forecastSamples(
            provider: provider,
            windowID: window.id,
            since: now.addingTimeInterval(-ForecastEngine.lookback),
            accountRef: historyScopeRef(for: provider)
        )
        return ForecastEngine.projection(
            samples: samples,
            now: now,
            currentPercent: window.percent,
            resetAt: window.resetsAt,
            windowMinutes: window.windowMinutes ?? 0
        )
    }

    // MARK: cycles

    public func currentCycle(for provider: ProviderID, window: QuotaWindow, now: Date = Date()) -> QuotaCycle? {
        guard let end = window.resetsAt else { return nil }
        let minutes = window.windowMinutes ?? 0
        let start: Date?
        if let exact = window.cycleStart {
            start = exact
        } else if minutes > 0 {
            start = end.addingTimeInterval(-Double(minutes) * 60)
        } else {
            start = nil
        }
        guard let start, start < end else { return nil }
        let provenance: CycleProvenance = window.cycleStart != nil
            ? .exact
            : (window.kind == .monthly ? .estimated : .derived)
        return QuotaCycle(
            provider: provider, windowID: window.id,
            start: start, end: end, provenance: provenance, isCurrent: true
        )
    }

    public func cycles(for provider: ProviderID, window: QuotaWindow, now: Date = Date()) -> [QuotaCycle] {
        var out: [QuotaCycle] = []
        let current = currentCycle(for: provider, window: window, now: now)
        if let current { out.append(current) }

        guard let store else { return out }
        let minutes = window.windowMinutes ?? 0
        guard minutes > 0 else { return out }
        let stored = store.storedCycles(
            provider: provider,
            windowID: window.id,
            accountRef: historyScopeRef(for: provider)
        )
        for cycle in stored {
            if let current, abs(cycle.resetAt.timeIntervalSince(current.end)) < 180 { continue }
            let start = cycle.resetAt.addingTimeInterval(-Double(minutes) * 60)
            guard start < cycle.resetAt else { continue }
            let provenance: CycleProvenance = window.kind == .monthly ? .estimated : .derived
            out.append(QuotaCycle(
                provider: provider, windowID: window.id,
                start: start, end: cycle.resetAt,
                provenance: provenance, isCurrent: false
            ))
        }
        return out
    }

    public func rawCycleSamples(for cycle: QuotaCycle, provider: ProviderID, window: QuotaWindow) -> [ForecastSample] {
        guard let store else { return [] }
        return store.cycleSamples(
            provider: provider,
            windowID: window.id,
            accountRef: historyScopeRef(for: provider),
            start: cycle.start,
            end: cycle.end,
            resetAt: cycle.end
        )
    }

    public func cycleSamples(for cycle: QuotaCycle, provider: ProviderID, window: QuotaWindow) -> [SamplePoint] {
        downsample(
            rawCycleSamples(for: cycle, provider: provider, window: window)
                .map { SamplePoint(at: $0.at, percent: $0.percent) },
            max: 400
        )
    }

    public func cycleForecast(
        for cycle: QuotaCycle,
        provider: ProviderID,
        window: QuotaWindow,
        now: Date = Date()
    ) -> ForecastState {
        guard cycle.isCurrent else { return .unavailable("historical cycle") }
        return ForecastEngine.forecast(
            samples: rawCycleSamples(for: cycle, provider: provider, window: window),
            now: now,
            currentPercent: window.percent,
            resetAt: cycle.end,
            windowMinutes: window.windowMinutes ?? 0
        )
    }

    public func cycleProjection(
        for cycle: QuotaCycle,
        provider: ProviderID,
        window: QuotaWindow,
        now: Date = Date()
    ) -> ForecastProjection? {
        guard cycle.isCurrent else { return nil }
        return ForecastEngine.projection(
            samples: rawCycleSamples(for: cycle, provider: provider, window: window),
            now: now,
            currentPercent: window.percent,
            resetAt: cycle.end,
            windowMinutes: window.windowMinutes ?? 0
        )
    }

    /// Sparkline data for a card: the current cycle of the given window.
    public func cycleTrend(for provider: ProviderID, window: QuotaWindow) -> (points: [SamplePoint], cycle: QuotaCycle)? {
        guard let cycle = currentCycle(for: provider, window: window) else { return nil }
        let points = cycleSamples(for: cycle, provider: provider, window: window)
        guard points.count >= 2 else { return nil }
        return (points, cycle)
    }

    public func historyWindowIDs(provider: ProviderID) -> [String] {
        store?.observedWindowIDs(provider: provider) ?? []
    }

    /// Cancels any in-flight import before deleting, so nothing can reappear
    /// after the user confirms. Async because it waits for that cancellation.
    public func clearHistory() async {
        let inFlight = backfillTask
        inFlight?.cancel()
        backfillTask = nil
        _ = await inFlight?.value
        // Deletion + cutoff in one transaction; anything observed before the
        // cutoff can never be persisted again.
        let cleared = store?.clearAll() ?? false
        if cleared {
            store?.setMeta("codex_backfill_v1", "cleared")
            providerStates = [:]
            storeIssue = nil
        } else {
            storeIssue = "History could not be cleared. Try again."
        }
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
            // Device-level: local logs carry no trustworthy account identity.
            accountRef: nil,
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
        guard let store, backfillTask == nil else { return }
        let marker = store.meta("codex_backfill_v1")
        guard marker == nil || marker == "running" else { return }
        store.setMeta("codex_backfill_v1", "running")
        backfillTask = Task.detached(priority: .utility) { [weak self] in
            let since = Date().addingTimeInterval(-14 * 86_400)
            let observations = CodexLocalLog.observations(since: since)
            let inserted = CodexBackfill.importObservations(observations, into: store, accountRef: nil) {
                Task.isCancelled
            }
            if Task.isCancelled { return }
            store.setMeta("codex_backfill_v1", "\(inserted)")
            await MainActor.run { [weak self] in
                self?.backfillTask = nil
                self?.invalidateHistory()
            }
        }
    }

    /// Scope for history queries: the account the Codex CLI is currently signed
    /// in as. Used to select account-scoped live rows; local-log rows stay
    /// unattributed and are shown as device-level.
    private func localAccountRef() -> String? {
        accountRef(readCodexCreds()?.accountId)
    }

    private func historyScopeRef(for provider: ProviderID) -> String? {
        guard provider == .codex else { return nil }
        return localAccountRef() ?? snapshots[provider]?.accountRef
    }

    public func hasDeviceLevelHistory(provider: ProviderID, windowID: String, hours: Int) -> Bool {
        store?.hasUnattributedHistory(
            provider: provider,
            windowID: windowID,
            since: Date().addingTimeInterval(-Double(hours) * 3_600)
        ) ?? false
    }

    // MARK: presentation

    public struct HeadsUp: Equatable, Sendable {
        public let provider: ProviderID
        public let window: QuotaWindow
        public let text: String
        public let isLimit: Bool
    }

    /// The single worst window worth surfacing above the cards.
    public var headsUp: HeadsUp? {
        headsUp(now: Date())
    }

    public func headsUp(now: Date) -> HeadsUp? {
        var best: (ProviderID, QuotaWindow)?
        for provider in ProviderID.allCases {
            guard let snapshot = snapshots[provider] else { continue }
            for window in snapshot.windows where window.percent.isFinite {
                guard let current = best else {
                    best = (provider, window)
                    continue
                }
                if (window.isLimited && !current.1.isLimited) || window.percent > current.1.percent {
                    best = (provider, window)
                }
            }
        }
        guard let (provider, window) = best else { return nil }
        guard window.isLimited || window.percent >= AlertRules.warningThreshold else { return nil }
        let kind: AlertKind = window.isLimited ? .limit : .warning
        var text = AlertRules.message(provider: provider, window: window, kind: kind, now: now)
        if staleness(for: provider, now: now) != nil {
            text += " Last reading is not current."
        }
        return HeadsUp(
            provider: provider,
            window: window,
            text: text,
            isLimit: window.isLimited
        )
    }

    public func presentation(for provider: ProviderID) -> ProviderPresentation {
        ProviderPresentation.resolve(
            hasSnapshot: snapshots[provider] != nil,
            health: health[provider]?.state
        )
    }

    public var hasConfiguredProvider: Bool {
        ProviderID.allCases.contains {
            switch presentation(for: $0) {
            case .available, .degraded, .needsAttention: return true
            case .checking, .unconfigured: return false
            }
        }
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
            let savedFile = saveGoKeyFile(key)
            let savedKeychain = saveKeychainKey(account: quotaBarGoAccount, value: key)
            guard savedFile || savedKeychain else {
                return "Key is valid but could not be saved."
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
        deleteGoKeyFile()
        health[.go] = ProviderHealth(state: .noCredentials, message: "Saved key removed.", attemptedAt: Date())
        snapshots[.go] = nil
        Task { await refresh() }
    }

    public var goKeyKnown: Bool { !goKeyCandidates().isEmpty }

    public var goKeySourceText: String {
        if isDemo { return "demo data" }
        if let snapshot = snapshots[.go], snapshot.origin == .network { return snapshot.source }
        if FileManager.default.fileExists(atPath: goKeyConfigURL().path) { return "cached key file" }
        if !goKeyCandidates().isEmpty { return "opencode auth.json" }
        return "none"
    }

    /// Non-prompting check for the UI. The cached file is authoritative once it
    /// exists; only fall back to the candidate chain (which may read Keychain
    /// once to migrate) when there is no file.
    public var hasSavedGoKey: Bool {
        if FileManager.default.fileExists(atPath: goKeyConfigURL().path) { return true }
        return !goKeyCandidates().isEmpty
    }

    // MARK: demo

    /// Only the demo harness calls this (`--demo`), never the shipped flow.
    /// Demo-only: mark providers as missing credentials so the setup card can be
    /// rendered in evidence without touching real keychains.
    public func markDemoUnconfigured(_ providers: [ProviderID]) {
        guard isDemo else { return }
        for provider in providers {
            health[provider] = ProviderHealth(state: .noCredentials, attemptedAt: Date())
        }
    }

    public func ingestDemo(_ snapshot: ProviderSnapshot) {
        guard isDemo else { return }
        snapshots[snapshot.provider] = snapshot
        health[snapshot.provider] = ProviderHealth(state: .ok, attemptedAt: Date())
        lastRefresh = Date()
        invalidateHistory()
        // Demo mode must exercise the same current-state contract as a probe,
        // otherwise the advisor would be blank in every preview and screenshot.
        let now = Date()
        if let store {
            recordState(provider: snapshot.provider, result: .ok(snapshot), now: now)
        }
        hasFullRefresh = true
    }
}
