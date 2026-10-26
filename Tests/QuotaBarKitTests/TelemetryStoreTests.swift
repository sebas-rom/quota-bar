import XCTest
@testable import QuotaBarKit

final class TelemetryStoreTests: XCTestCase {
    private var store: TelemetryStore!

    override func setUpWithError() throws {
        store = try TelemetryStore.inMemory()
    }

    override func tearDown() {
        store.close()
        store = nil
    }

    private func snapshot(
        _ provider: ProviderID,
        windows: [(String, Double, Date?)],
        at date: Date = Date(),
        origin: SnapshotOrigin = .network
    ) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: windows.map {
                QuotaWindow(id: $0.0, kind: .primary, label: $0.0, percent: $0.1,
                            resetsAt: $0.2, windowMinutes: 300, isLimited: false)
            },
            origin: origin,
            source: "test",
            observedAt: date
        )
    }

    func testInsertIsIdempotentPerObservation() {
        let date = Date()
        let snap = snapshot(.go, windows: [("go.rolling", 42, nil), ("go.weekly", 10, nil)], at: date)
        XCTAssertEqual(store.insert(snap), 2)
        XCTAssertEqual(store.insert(snap), 0, "re-importing the same observation must not duplicate rows")
        XCTAssertEqual(store.count(), 2)
    }

    func testSeriesIsWindowScopedAndTimeOrdered() {
        let now = Date()
        for offset in [0.0, -600.0, -300.0] {
            _ = store.insert(snapshot(.go, windows: [("go.rolling", 40 + offset / 60, nil)],
                                      at: now.addingTimeInterval(offset)))
        }
        _ = store.insert(snapshot(.go, windows: [("go.weekly", 99, nil)], at: now))

        let points = store.series(provider: .go, windowID: "go.rolling", since: now.addingTimeInterval(-3_600))
        XCTAssertEqual(points.count, 3)
        XCTAssertEqual(points.map(\.at), points.map(\.at).sorted())
        XCTAssertEqual(points.last?.percent, 40)
    }

    func testSeriesRespectsSinceCutoff() {
        let now = Date()
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 10, nil)], at: now.addingTimeInterval(-7_200)))
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 20, nil)], at: now))

        let recent = store.series(provider: .go, windowID: "go.rolling", since: now.addingTimeInterval(-3_600))
        XCTAssertEqual(recent.count, 1)
        XCTAssertEqual(recent.first?.percent, 20)
    }

    func testPruneDropsOldSamplesOnly() {
        let now = Date()
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 50, nil)], at: now.addingTimeInterval(-20 * 86_400)))
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 60, nil)], at: now))

        store.prune(olderThan: now.addingTimeInterval(-90 * 86_400))
        XCTAssertEqual(store.count(), 2, "nothing is older than retention yet")

        store.prune(olderThan: now.addingTimeInterval(-1 * 86_400))
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(store.lastObserved(provider: .go)?.timeIntervalSince1970 ?? 0,
                       now.timeIntervalSince1970, accuracy: 0.001)
    }

    func testResetClearsSamplesAndMeta() {
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 50, nil)]))
        store.setMeta("codex_backfill_v1", "12")
        XCTAssertEqual(store.meta("codex_backfill_v1"), "12")

        store.reset()
        XCTAssertEqual(store.count(), 0)
        XCTAssertNil(store.meta("codex_backfill_v1"))
    }

    func testObservedWindowIDsDeduplicates() {
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 10, nil), ("go.weekly", 20, nil)]))
        _ = store.insert(snapshot(.go, windows: [("go.rolling", 30, nil)]))
        XCTAssertEqual(Set(store.observedWindowIDs(provider: .go)), ["go.rolling", "go.weekly"])
        XCTAssertTrue(store.observedWindowIDs(provider: .codex).isEmpty)
    }

    func testPlanAndAccountRefPersist() {
        let snap = ProviderSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour",
                                  percent: 12, resetsAt: nil, windowMinutes: 300, isLimited: false)],
            plan: "plus",
            accountRef: "abc123",
            origin: .localLog,
            source: "Codex local session log",
            observedAt: Date()
        )
        _ = store.insert(snap)
        XCTAssertEqual(store.series(provider: .codex, windowID: "codex.primary", since: .distantPast).count, 1)
        XCTAssertEqual(store.count(), 1)
        XCTAssertEqual(store.lastObserved(provider: .codex)?.timeIntervalSince1970 ?? 0,
                       snap.observedAt.timeIntervalSince1970, accuracy: 0.001)
    }

    func testSeriesCanBeScopedToAccount() {
        let now = Date()
        for (offset, ref) in [(0.0, "acctA"), (-300.0, "acctB")] {
            _ = store.insert(ProviderSnapshot(
                provider: .codex,
                windows: [QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour",
                                      percent: 10 + offset / -30, resetsAt: nil,
                                      windowMinutes: 300, isLimited: false)],
                accountRef: ref,
                origin: .network, source: "test",
                observedAt: now.addingTimeInterval(offset)
            ))
        }
        let scoped = store.series(provider: .codex, windowID: "codex.primary",
                                  since: now.addingTimeInterval(-3_600), accountRef: "acctA")
        XCTAssertEqual(scoped.count, 1)
        let unscoped = store.series(provider: .codex, windowID: "codex.primary",
                                    since: now.addingTimeInterval(-3_600))
        XCTAssertEqual(unscoped.count, 2)
    }

    func testStoreSurvivesReopen() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-store-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }

        do {
            let first = try TelemetryStore(path: url)
            _ = first.insert(snapshot(.codex, windows: [("codex.primary", 33, nil)]))
            first.close()
        }
        let second = try TelemetryStore(path: url)
        XCTAssertEqual(second.count(), 1)
        second.close()
    }
}

@MainActor
final class QuotaModelHistoryTests: XCTestCase {
    func testClearHistoryEmptiesStoreAndStopsBackfillFromReturning() async throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let model = QuotaModel(store: store)
        let now = Date()
        _ = store.insert(ProviderSnapshot(
            provider: .codex,
            windows: [QuotaWindow(id: "codex.primary", kind: .primary, label: "5-hour",
                                  percent: 12, resetsAt: nil, windowMinutes: 300, isLimited: false)],
            origin: .localLog, source: "test", observedAt: now
        ))
        XCTAssertEqual(store.count(), 1)

        await model.clearHistory()

        XCTAssertEqual(store.count(), 0)
        XCTAssertEqual(model.historyCount, 0)
        XCTAssertEqual(store.meta("codex_backfill_v1"), "cleared",
                       "cleared history must not be re-imported by the one-time backfill")
    }
}
