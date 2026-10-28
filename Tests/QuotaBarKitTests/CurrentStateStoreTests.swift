import XCTest
@testable import QuotaBarKit

/// Schema v2 adds `provider_state` next to the untouched `sample` history. These
/// tests pin both halves of that promise: current state round-trips atomically,
/// and an existing v1 store keeps every history row when it is opened.
final class CurrentStateStoreTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-store-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func state(
        _ provider: ProviderID = .codex,
        generation: Int = 1,
        percent: Double = 25,
        completeness: ObservationCompleteness = .complete
    ) -> ProviderState {
        ProviderState(
            provider: provider,
            generation: generation,
            observedAt: Date(timeIntervalSince1970: 1_800_000_000),
            origin: .network,
            source: "test",
            plan: "plus",
            accountRef: "acct",
            completeness: completeness,
            probeState: .ok,
            probeMessage: nil,
            probeAt: Date(timeIntervalSince1970: 1_800_000_000),
            windows: [QuotaWindow(id: "\(provider.rawValue).primary", kind: .primary,
                                  label: "5-hour", percent: percent, resetsAt: nil,
                                  windowMinutes: 300, isLimited: false)],
            facts: ["2 reset credits"]
        )
    }

    func testCurrentStateRoundTrips() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        XCTAssertEqual(store.saveProviderState(state()), .saved)
        let loaded = try XCTUnwrap(store.providerState(.codex))
        XCTAssertEqual(loaded, state())
    }

    func testEmptyStoreMeansUnknownNotZero() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        XCTAssertTrue(store.providerStates().isEmpty)
        XCTAssertNil(store.providerState(.go))
    }

    func testSavingReplacesTheWholeRecord() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        store.saveProviderState(state(generation: 1, percent: 25))
        store.saveProviderState(state(generation: 2, percent: 60))
        let loaded = try XCTUnwrap(store.providerState(.codex))
        XCTAssertEqual(loaded.generation, 2)
        XCTAssertEqual(loaded.windows.first?.percent, 60)
    }

    func testStatesAreIndependentPerProvider() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        store.saveProviderState(state(.codex, percent: 10))
        store.saveProviderState(state(.go, percent: 90))
        let all = store.providerStates()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all[.codex]?.windows.first?.percent, 10)
        XCTAssertEqual(all[.go]?.windows.first?.percent, 90)
    }

    func testClearAllAlsoDeletesCurrentState() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        store.saveProviderState(state())
        XCTAssertTrue(store.clearAll())
        XCTAssertTrue(store.providerStates().isEmpty, "advice must not survive a history deletion")
    }

    func testResetAlsoDeletesCurrentState() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        store.saveProviderState(state())
        store.reset()
        XCTAssertTrue(store.providerStates().isEmpty)
    }

    func testSchemaVersionIsTwo() {
        XCTAssertEqual(TelemetryStore.schemaVersion, 2)
    }

    /// Creates a version-1 file on disk, then opens it with the real store. The
    /// history row must survive and the new table must appear.
    func testVersionOneStoreMigratesInPlace() throws {
        let sqlite = URL(fileURLWithPath: "/usr/bin/sqlite3")
        guard FileManager.default.isExecutableFile(atPath: sqlite.path) else {
            throw XCTSkip("sqlite3 CLI not available")
        }
        let path = dir.appendingPathComponent("legacy.sqlite")
        let script = """
        PRAGMA journal_mode=DELETE;
        CREATE TABLE sample (
            provider TEXT NOT NULL,
            window_id TEXT NOT NULL,
            window_label TEXT NOT NULL,
            percent REAL NOT NULL,
            resets_at REAL,
            observed_at REAL NOT NULL,
            origin TEXT NOT NULL,
            plan TEXT,
            account_ref TEXT,
            PRIMARY KEY (provider, window_id, observed_at, origin)
        );
        CREATE TABLE meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
        INSERT INTO sample (provider, window_id, window_label, percent, observed_at, origin)
            VALUES ('codex', 'codex.primary', '5-hour', 42, 1700000000, 'network');
        PRAGMA user_version = 1;
        """
        let process = Process()
        process.executableURL = sqlite
        process.arguments = [path.path, script]
        try process.run()
        process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0)

        let store = try TelemetryStore(path: path, createDirectory: false)
        defer { store.close() }
        XCTAssertEqual(store.count(), 1, "history must be untouched by the migration")
        XCTAssertTrue(store.providerStates().isEmpty)
        XCTAssertEqual(store.saveProviderState(state()), .saved, "the new table must exist after migration")
        let series = store.series(provider: .codex, windowID: "codex.primary",
                                  since: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(series.map(\.percent), [42])
    }

    /// A probe that started before Clear History can finish afterwards. Its
    /// history rows are rejected by the deletion cutoff; current state must obey
    /// the same rule or the advice would stand on erased evidence.
    func testPreClearStateCannotBeRestoredAfterClearAll() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let old = Date(timeIntervalSince1970: 1_800_000_000)
        let signal = state(percent: 25)
        XCTAssertEqual(store.saveProviderState(signal), .saved)

        let clearedAt = Date(timeIntervalSince1970: 1_800_000_600)
        XCTAssertTrue(store.clearAll(now: clearedAt))
        XCTAssertTrue(store.providerStates().isEmpty)

        let resurrected = ProviderState(
            provider: .codex, generation: 2, observedAt: old, origin: .network,
            source: "test", plan: "plus", accountRef: "acct", completeness: .complete,
            probeState: .ok, probeMessage: nil, probeAt: clearedAt,
            windows: signal.windows, facts: []
        )
        XCTAssertEqual(store.saveProviderState(resurrected), .rejectedByCutoff)
        XCTAssertTrue(store.providerStates().isEmpty, "cleared advice must not come back")

        let fresh = ProviderState(
            provider: .codex, generation: 3, observedAt: clearedAt.addingTimeInterval(60),
            origin: .network, source: "test", plan: "plus", accountRef: "acct",
            completeness: .complete, probeState: .ok, probeMessage: nil,
            probeAt: clearedAt.addingTimeInterval(60), windows: signal.windows, facts: []
        )
        XCTAssertEqual(store.saveProviderState(fresh), .saved)
        XCTAssertEqual(store.providerState(.codex)?.generation, 3)
    }

    /// A failure with no retained windows carries no erased quota, so the fresh
    /// probe outcome after Clear History is still worth storing: it is how the
    /// advisor learns a provider is explicitly unconfigured.
    func testFreshFailureWithoutRetainedEvidenceSurvivesTheCutoff() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let cutoff = Date(timeIntervalSince1970: 1_800_000_600)
        XCTAssertTrue(store.clearAll(now: cutoff))

        let unconfigured = ProviderState(
            provider: .commandCode, generation: 1, observedAt: nil, origin: nil,
            source: nil, plan: nil, accountRef: nil, completeness: .failed,
            probeState: .noCredentials, probeMessage: "No key",
            probeAt: cutoff.addingTimeInterval(30), windows: [], facts: []
        )
        XCTAssertEqual(store.saveProviderState(unconfigured), .saved)
        XCTAssertEqual(store.providerState(.commandCode)?.isConfigured, false)
    }

    /// The same failure path that retains pre-clear numbers must stay rejected:
    /// those windows are exactly the evidence the user deleted.
    func testFailureRetainingPreClearWindowsIsRejected() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let observed = Date(timeIntervalSince1970: 1_800_000_000)
        let signal = state(percent: 40)
        XCTAssertEqual(store.saveProviderState(signal), .saved)

        let cutoff = observed.addingTimeInterval(600)
        XCTAssertTrue(store.clearAll(now: cutoff))

        let retained = ProviderState.next(
            signal,
            result: .failed(.offline, "offline"),
            provider: .codex,
            now: cutoff.addingTimeInterval(30)
        )
        XCTAssertEqual(retained.observedAt, observed)
        XCTAssertEqual(store.saveProviderState(retained), .rejectedByCutoff)
    }

    func testCurrentStateSurvivesReopen() throws {
        let path = dir.appendingPathComponent("state.sqlite")
        do {
            let store = try TelemetryStore(path: path, createDirectory: false)
            store.saveProviderState(state(percent: 37))
            store.close()
        }
        let reopened = try TelemetryStore(path: path, createDirectory: false)
        defer { reopened.close() }
        XCTAssertEqual(reopened.providerState(.codex)?.windows.first?.percent, 37)
    }
}
