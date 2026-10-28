import XCTest
@testable import QuotaBarKit

/// Model-level state contracts: what the popover sees must be exactly what the
/// store kept, and the advice row must wait for a complete refresh pass.
@MainActor
final class QuotaModelStateTests: XCTestCase {
    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    private func snapshot(_ provider: ProviderID, percent: Double, at date: Date) -> ProviderSnapshot {
        let ids: [(String, WindowKind, Int)] = switch provider {
        case .go: [("go.rolling", .rolling, 300), ("go.weekly", .weekly, 10_080), ("go.monthly", .monthly, 43_200)]
        case .codex: [("codex.primary", .primary, 300), ("codex.secondary", .secondary, 10_080)]
        case .commandCode: [("commandcode.5h", .primary, 300), ("commandcode.weekly", .weekly, 10_080)]
        }
        return ProviderSnapshot(
            provider: provider,
            windows: ids.map {
                QuotaWindow(id: $0.0, kind: $0.1, label: $0.0, percent: percent,
                            resetsAt: nil, windowMinutes: $0.2, isLimited: false)
            },
            origin: .network,
            source: "test",
            observedAt: date
        )
    }

    private func state(_ provider: ProviderID, observedAt: Date, percent: Double) -> ProviderState {
        ProviderState(
            provider: provider, generation: 1, observedAt: observedAt, origin: .network,
            source: "test", plan: nil, accountRef: nil, completeness: .complete,
            probeState: .ok, probeMessage: nil, probeAt: observedAt,
            windows: snapshot(provider, percent: percent, at: observedAt).windows, facts: []
        )
    }

    func testStateRejectedByCutoffIsNotPublishedInMemory() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        XCTAssertEqual(store.saveProviderState(state(.codex, observedAt: base, percent: 30)), .saved)
        XCTAssertTrue(store.clearAll(now: base.addingTimeInterval(600)))

        let model = QuotaModel(store: store)
        model.recordState(
            provider: .codex,
            result: .ok(snapshot(.codex, percent: 30, at: base)),
            now: base.addingTimeInterval(700)
        )
        XCTAssertNil(model.providerStates[.codex], "erased evidence must not reappear in the popover")
        XCTAssertTrue(store.providerStates().isEmpty)
        XCTAssertEqual(model.advice(now: base.addingTimeInterval(700)).recommendation.status, .unknown)
    }

    func testFreshNoCredentialsAfterClearIsPublishedAndPersisted() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let cutoff = base.addingTimeInterval(600)
        XCTAssertTrue(store.clearAll(now: cutoff))

        let now = cutoff.addingTimeInterval(30)
        let model = QuotaModel(store: store)
        model.recordState(
            provider: .commandCode,
            result: .failed(.noCredentials, "No key"),
            now: now
        )
        let published = try XCTUnwrap(model.providerStates[.commandCode])
        XCTAssertFalse(published.isConfigured)
        XCTAssertNil(published.observedAt)
        XCTAssertEqual(store.providerState(.commandCode)?.generation, published.generation)

        // The popover and the CLI must reach the same decision from the same
        // evidence: the model's advice and a fresh evaluation of the persisted
        // rows are identical.
        XCTAssertEqual(model.advice(now: now), Advisor.evaluate(states: store.providerStates(), now: now))
    }

    func testAdviceRowWaitsForTheWholeRefreshPass() async throws {
        let fake = FakeProbes(source: .http)
        fake.goDelay = 0.3
        let model = QuotaModel(probes: fake)
        XCTAssertFalse(model.hasFullRefresh)

        let task = Task { await model.refresh() }
        try await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertFalse(model.hasFullRefresh, "Go is still in flight, so the row must stay hidden")
        await task.value
        XCTAssertTrue(model.hasFullRefresh)
    }

    func testSourceSwitchMidRefreshDiscardsTheOldResult() async throws {
        let suiteName = "QuotaModelStateTests"
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)

        let slow = FakeProbes(source: .http)
        slow.codexDelay = 0.4
        slow.codexPercent = 11
        let fast = FakeProbes(source: .appServer)
        fast.codexPercent = 55

        let model = QuotaModel(probes: slow, defaults: suite, probeFactory: { _ in fast })
        let task = Task { await model.refresh() }
        try await Task.sleep(nanoseconds: 120_000_000)
        model.setCodexSource(.appServer)
        await task.value

        var waited: TimeInterval = 0
        while model.snapshots[.codex]?.windows.first?.percent != 55, waited < 3 {
            try await Task.sleep(nanoseconds: 50_000_000)
            waited += 0.05
        }
        XCTAssertEqual(model.snapshots[.codex]?.windows.first?.percent, 55,
                       "the HTTP result must not land after the source changed")
        XCTAssertEqual(model.codexSource, .appServer)
        XCTAssertEqual(suite.string(forKey: "CodexSource"), "appServer")
        suite.removePersistentDomain(forName: suiteName)
    }
}

/// Controllable probe set: no network, adjustable latency, per-provider values.
final class FakeProbes: ProbeProviding, @unchecked Sendable {
    let codexSource: CodexSource
    var goDelay: TimeInterval = 0
    var codexDelay: TimeInterval = 0
    var codexPercent: Double = 20
    var goPercent: Double = 20

    init(source: CodexSource) {
        codexSource = source
    }

    private func snapshot(_ provider: ProviderID, percent: Double, now: Date) -> ProviderSnapshot {
        let ids: [(String, WindowKind, Int)] = switch provider {
        case .go: [("go.rolling", .rolling, 300), ("go.weekly", .weekly, 10_080), ("go.monthly", .monthly, 43_200)]
        case .codex: [("codex.primary", .primary, 300), ("codex.secondary", .secondary, 10_080)]
        case .commandCode: [("commandcode.5h", .primary, 300), ("commandcode.weekly", .weekly, 10_080)]
        }
        return ProviderSnapshot(
            provider: provider,
            windows: ids.map {
                QuotaWindow(id: $0.0, kind: $0.1, label: $0.0, percent: percent,
                            resetsAt: nil, windowMinutes: $0.2, isLimited: false)
            },
            origin: .network,
            source: "fake",
            observedAt: now
        )
    }

    func go(now: Date) async -> ProbeResult {
        if goDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(goDelay * 1_000_000_000)) }
        return .ok(snapshot(.go, percent: goPercent, now: now))
    }

    func codex(now: Date) async -> ProbeResult {
        if codexDelay > 0 { try? await Task.sleep(nanoseconds: UInt64(codexDelay * 1_000_000_000)) }
        return .ok(snapshot(.codex, percent: codexPercent, now: now))
    }

    func commandCode(now: Date) async -> ProbeResult {
        .ok(snapshot(.commandCode, percent: 10, now: now))
    }

    func fetchGo(key: String, source: String) async -> GoFetchState {
        .unexpected("fake probes")
    }
}
