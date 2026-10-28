import Foundation
import SQLite3

// MARK: - Local observation store
//
// A tiny, versioned SQLite database that remembers quota observations so the
// app can answer "how did we get here?" and survive a provider outage with the
// last known values. Read-only with respect to provider data: nothing here is
// uploaded, and no tokens, prompts or message bodies are stored.

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Result of writing one provider's current state. The cutoff case is
/// distinct from a storage failure: the record is valid, it is simply evidence
/// the user deleted.
public enum ProviderStateSave: Equatable {
    case saved
    case rejectedByCutoff
    case failed
}

public enum StoreError: Error, Equatable {
    case open(String)
    case prepare(String)
    case step(String)
}

public final class TelemetryStore: @unchecked Sendable {
    /// Version 2 adds `provider_state`: one atomic current-state record per
    /// provider. The `sample` history table is unchanged, so charts, replay and
    /// `--status-json` keep their v1 meaning.
    public static let schemaVersion: Int32 = 2

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String
    /// Observations written before this instant are never persisted again.
    /// Set by "Clear History"; protects against re-import from local logs.
    private var clearedAt: Date?

    public static func defaultPath() -> URL {
        homeDir()
            .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
            .appendingPathComponent("telemetry.sqlite")
    }

    /// In-memory store, useful for tests and the demo harness.
    public static func inMemory() throws -> TelemetryStore {
        try TelemetryStore(path: URL(fileURLWithPath: "memory"), createDirectory: false, memory: true)
    }

    public init(path: URL, createDirectory: Bool = true, memory: Bool = false, readOnly: Bool = false) throws {
        self.path = memory ? ":memory:" : path.path
        if createDirectory, !memory, !readOnly {
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags: Int32 = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(memory ? ":memory:" : path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed (\(rc))"
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(message)
        }
        db = handle
        if readOnly {
            try exec("PRAGMA busy_timeout=2000")
        } else {
            try exec("PRAGMA journal_mode=WAL")
            try exec("PRAGMA synchronous=NORMAL")
            try exec("PRAGMA busy_timeout=2000")
            try migrate()
            if let cutoff = meta("history_cleared_at").flatMap(Double.init) {
                clearedAt = Date(timeIntervalSince1970: cutoff)
            }
        }
    }

    deinit { close() }

    public func close() {
        lock.lock(); defer { lock.unlock() }
        if let db { sqlite3_close(db) }
        db = nil
    }

    // MARK: writes

    /// Idempotent: the primary key makes a re-import of the same observation a no-op.
    @discardableResult
    public func insert(_ snapshot: ProviderSnapshot) -> Int {
        withLock { db in
            // Nothing observed before the deletion cutoff may be stored again,
            // whatever its origin: a slow in-flight probe must not resurrect
            // data the user just deleted. Genuinely fresh observations are
            // timestamped after the cutoff and pass.
            if let cutoff = clearedAt, snapshot.observedAt <= cutoff {
                return 0
            }
            let sql = """
            INSERT OR IGNORE INTO sample
                (provider, window_id, window_label, percent, resets_at, observed_at, origin, plan, account_ref)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return 0 }
            defer { sqlite3_finalize(stmt) }
            var inserted = 0
            for w in snapshot.windows {
                sqlite3_reset(stmt)
                sqlite3_clear_bindings(stmt)
                bind(stmt, 1, snapshot.provider.rawValue)
                bind(stmt, 2, w.id)
                bind(stmt, 3, w.label)
                sqlite3_bind_double(stmt, 4, w.percent)
                if let r = w.resetsAt { sqlite3_bind_double(stmt, 5, r.timeIntervalSince1970) }
                else { sqlite3_bind_null(stmt, 5) }
                sqlite3_bind_double(stmt, 6, snapshot.observedAt.timeIntervalSince1970)
                bind(stmt, 7, snapshot.origin.rawValue)
                if let p = snapshot.plan { bind(stmt, 8, p) } else { sqlite3_bind_null(stmt, 8) }
                if let a = snapshot.accountRef { bind(stmt, 9, a) } else { sqlite3_bind_null(stmt, 9) }
                if sqlite3_step(stmt) == SQLITE_DONE { inserted += Int(sqlite3_changes(db)) }
            }
            return inserted
        } ?? 0
    }

    public func prune(olderThan date: Date) {
        _ = try? run("DELETE FROM sample WHERE observed_at < ?", [date.timeIntervalSince1970])
    }

    /// Wipes everything without recording a deletion cutoff. Test helper and
    /// the explicit "start over" path; the user-facing Clear History goes
    /// through `clearAll(now:)`, which is transactional and timestamped.
    ///
    /// Deletions run in one transaction so an interrupted call cannot leave
    /// half a store behind.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        let sampleDeleted = sqlite3_exec(db, "DELETE FROM sample", nil, nil, nil) == SQLITE_OK
        let stateDeleted = sqlite3_exec(db, "DELETE FROM provider_state", nil, nil, nil) == SQLITE_OK
        let metaDeleted = sqlite3_exec(db, "DELETE FROM meta", nil, nil, nil) == SQLITE_OK
        if sampleDeleted, stateDeleted, metaDeleted,
           sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK {
            clearedAt = nil
        } else {
            _ = sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
        }
    }

    /// Deletes every observation and records the deletion cutoff in the same
    /// transaction, so a crash can never leave the store empty without the
    /// cutoff (or vice versa). Returns false if the transaction did not commit.
    @discardableResult
    public func clearAll(now: Date = Date()) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return false }
        guard sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return false }
        let delete = sqlite3_exec(db, "DELETE FROM sample", nil, nil, nil) == SQLITE_OK
        // Current state is advisory input: deleting history must not leave a
        // recommendation standing on evidence the user just erased.
        let deleteState = sqlite3_exec(db, "DELETE FROM provider_state", nil, nil, nil) == SQLITE_OK
        var stmt: OpaquePointer?
        var cutoffWritten = false
        if sqlite3_prepare_v2(db, "INSERT OR REPLACE INTO meta(key, value) VALUES ('history_cleared_at', ?)", -1, &stmt, nil) == SQLITE_OK {
            sqlite3_bind_double(stmt, 1, now.timeIntervalSince1970)
            cutoffWritten = sqlite3_step(stmt) == SQLITE_DONE
        }
        sqlite3_finalize(stmt)
        guard delete, deleteState, cutoffWritten else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        guard sqlite3_exec(db, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(db, "ROLLBACK", nil, nil, nil)
            return false
        }
        clearedAt = now
        return true
    }

    // MARK: reads

    /// `accountRef == nil` means "any account" (Go has no account identity);
    /// a value scopes the history so switching accounts never blends charts.
    public func series(provider: ProviderID, windowID: String, since: Date,
                       accountRef: String? = nil) -> [SamplePoint] {
        withLock { db in
            let sql = """
            SELECT observed_at, percent FROM sample
            WHERE provider = ? AND window_id = ? AND observed_at >= ?
              AND (? IS NULL OR account_ref = ? OR account_ref IS NULL)
            ORDER BY observed_at ASC LIMIT 5000
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)
            if let accountRef { bind(stmt, 4, accountRef); bind(stmt, 5, accountRef) }
            else { sqlite3_bind_null(stmt, 4); sqlite3_bind_null(stmt, 5) }
            var out: [SamplePoint] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(SamplePoint(
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    percent: sqlite3_column_double(stmt, 1)
                ))
            }
            return out
        } ?? []
    }

    /// True when the range contains device-level (local-log) rows that carry no
    /// account identity. The UI surfaces this instead of implying ownership.
    public func hasUnattributedHistory(provider: ProviderID, windowID: String, since: Date) -> Bool {
        withLock { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            let sql = """
            SELECT 1 FROM sample
            WHERE provider = ? AND window_id = ? AND observed_at >= ?
              AND origin = 'localLog' AND account_ref IS NULL
            LIMIT 1
            """
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)
            return sqlite3_step(stmt) == SQLITE_ROW
        } ?? false
    }

    public struct StoredCycle: Equatable, Sendable {
        public let resetAt: Date
        public let first: Date
        public let last: Date
        public let count: Int
    }

    /// Distinct reset boundaries observed for a window, newest first.
    public func storedCycles(
        provider: ProviderID,
        windowID: String,
        accountRef: String? = nil,
        limit: Int = 20
    ) -> [StoredCycle] {
        withLock { db in
            let sql = """
            SELECT MAX(resets_at), MIN(observed_at), MAX(observed_at), COUNT(*)
            FROM sample
            WHERE provider = ? AND window_id = ? AND resets_at IS NOT NULL AND origin = 'network'
              AND (? IS NULL OR account_ref = ? OR account_ref IS NULL)
            GROUP BY CAST(resets_at / 120 AS INTEGER)
            ORDER BY MAX(resets_at) DESC
            LIMIT ?
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            if let accountRef { bind(stmt, 3, accountRef); bind(stmt, 4, accountRef) }
            else { sqlite3_bind_null(stmt, 3); sqlite3_bind_null(stmt, 4) }
            sqlite3_bind_int(stmt, 5, Int32(limit))
            var out: [StoredCycle] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                out.append(StoredCycle(
                    resetAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    first: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 1)),
                    last: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2)),
                    count: Int(sqlite3_column_int64(stmt, 3))
                ))
            }
            return out
        } ?? []
    }

    /// Observations that belong to exactly one reset boundary. Never mixes
    /// cycles, never bridges a reset.
    public func cycleSamples(
        provider: ProviderID,
        windowID: String,
        accountRef: String? = nil,
        start: Date,
        end: Date,
        resetAt: Date,
        tolerance: TimeInterval = 120
    ) -> [ForecastSample] {
        withLock { db in
            let sql = """
            SELECT observed_at, percent, resets_at, origin FROM sample
            WHERE provider = ? AND window_id = ?
              AND observed_at >= ? AND observed_at < ?
              AND resets_at IS NOT NULL AND resets_at BETWEEN ? AND ?
              AND origin = 'network'
              AND (? IS NULL OR account_ref = ? OR account_ref IS NULL)
            ORDER BY observed_at ASC LIMIT 5000
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            sqlite3_bind_double(stmt, 3, start.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 4, end.timeIntervalSince1970)
            sqlite3_bind_double(stmt, 5, resetAt.timeIntervalSince1970 - tolerance)
            sqlite3_bind_double(stmt, 6, resetAt.timeIntervalSince1970 + tolerance)
            if let accountRef { bind(stmt, 7, accountRef); bind(stmt, 8, accountRef) }
            else { sqlite3_bind_null(stmt, 7); sqlite3_bind_null(stmt, 8) }

            var out: [ForecastSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let reset: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let origin = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "network"
                out.append(ForecastSample(
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    percent: sqlite3_column_double(stmt, 1),
                    resetsAt: reset,
                    origin: SnapshotOrigin(rawValue: origin) ?? .network
                ))
            }
            return out
        } ?? []
    }

    public struct LatestObservation: Equatable, Sendable {
        public let provider: String
        public let windowID: String
        public let label: String
        public let percent: Double
        public let resetsAt: Date?
        public let observedAt: Date
        public let origin: String
        public let plan: String?
    }

    /// Newest persisted observation per provider/window. Read-only friendly;
    /// used by `--status-json`. Never includes credentials.
    public func latestObservations() -> [LatestObservation] {
        withLock { db in
            let sql = """
            SELECT provider, window_id, window_label, percent, resets_at, observed_at, origin, plan
            FROM (
                SELECT *, ROW_NUMBER() OVER (
                    PARTITION BY provider, window_id ORDER BY observed_at DESC
                ) AS rn
                FROM sample
            ) WHERE rn = 1
            ORDER BY provider ASC, window_id ASC
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            var out: [LatestObservation] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                func text(_ index: Int32) -> String? {
                    sqlite3_column_text(stmt, index).map { String(cString: $0) }
                }
                out.append(LatestObservation(
                    provider: text(0) ?? "",
                    windowID: text(1) ?? "",
                    label: text(2) ?? text(1) ?? "",
                    percent: sqlite3_column_double(stmt, 3),
                    resetsAt: sqlite3_column_type(stmt, 4) == SQLITE_NULL
                        ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 4)),
                    observedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 5)),
                    origin: text(6) ?? "network",
                    plan: text(7)
                ))
            }
            return out
        } ?? []
    }

    /// Every network observation for a window, oldest first. Used by the
    /// read-only replay; no account filter (replay is a local diagnostic).
    public func networkSamples(provider: ProviderID, windowID: String, since: Date) -> [ForecastSample] {
        withLock { db in
            let sql = """
            SELECT observed_at, percent, resets_at, origin FROM sample
            WHERE provider = ? AND window_id = ? AND observed_at >= ? AND origin = 'network'
            ORDER BY observed_at DESC LIMIT 20000
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)
            var out: [ForecastSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let reset: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                out.append(ForecastSample(
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    percent: sqlite3_column_double(stmt, 1),
                    resetsAt: reset,
                    origin: .network
                ))
            }
            // Selected newest-first so the cap drops the oldest rows, then
            // restored to chronological order for the replay.
            return out.reversed()
        } ?? []
    }

    /// Raw network observations for forecasting. Never mixes origins, and
    /// honours the account scope used by the charts.
    public func forecastSamples(
        provider: ProviderID,
        windowID: String,
        since: Date,
        accountRef: String? = nil
    ) -> [ForecastSample] {
        withLock { db in
            let sql = """
            SELECT observed_at, percent, resets_at, origin FROM sample
            WHERE provider = ? AND window_id = ? AND observed_at >= ?
              AND origin = 'network'
              AND (? IS NULL OR account_ref = ? OR account_ref IS NULL)
            ORDER BY observed_at ASC LIMIT 2000
            """
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, provider.rawValue)
            bind(stmt, 2, windowID)
            sqlite3_bind_double(stmt, 3, since.timeIntervalSince1970)
            if let accountRef { bind(stmt, 4, accountRef); bind(stmt, 5, accountRef) }
            else { sqlite3_bind_null(stmt, 4); sqlite3_bind_null(stmt, 5) }

            var out: [ForecastSample] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                let reset: Date? = sqlite3_column_type(stmt, 2) == SQLITE_NULL
                    ? nil
                    : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 2))
                let origin = sqlite3_column_text(stmt, 3).map { String(cString: $0) } ?? "network"
                out.append(ForecastSample(
                    at: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0)),
                    percent: sqlite3_column_double(stmt, 1),
                    resetsAt: reset,
                    origin: SnapshotOrigin(rawValue: origin) ?? .network
                ))
            }
            return out
        } ?? []
    }

    public func observedWindowIDs(provider: ProviderID) -> [String] {
        withLock { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT DISTINCT window_id FROM sample WHERE provider = ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
            bind(stmt, 1, provider.rawValue)
            var out: [String] = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let c = sqlite3_column_text(stmt, 0) { out.append(String(cString: c)) }
            }
            return out
        } ?? []
    }

    public func count() -> Int {
        withLock { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM sample", -1, &stmt, nil) == SQLITE_OK,
                  sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(stmt, 0))
        } ?? 0
    }

    public func lastObserved(provider: ProviderID) -> Date? {
        withLock { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT MAX(observed_at) FROM sample WHERE provider = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            bind(stmt, 1, provider.rawValue)
            guard sqlite3_step(stmt) == SQLITE_ROW, sqlite3_column_type(stmt, 0) != SQLITE_NULL else { return nil }
            return Date(timeIntervalSince1970: sqlite3_column_double(stmt, 0))
        } ?? nil
    }

    public func sizeBytes() -> Int64 {
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    // MARK: current provider state

    private static let stateEncoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let stateDecoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    /// Writes one provider's current state as a single row. A record is never
    /// partially applied: either the whole payload lands or nothing changes.
    @discardableResult
    public func saveProviderState(_ state: ProviderState) -> ProviderStateSave {
        guard let payload = try? Self.stateEncoder.encode(state),
              let json = String(data: payload, encoding: .utf8) else { return .failed }
        let sql = """
        INSERT OR REPLACE INTO provider_state
            (provider, generation, observed_at, completeness, payload)
        VALUES (?, ?, ?, ?, ?)
        """
        return withLock { db -> ProviderStateSave in
            // The same cutoff that protects history must protect current state,
            // or a probe that started before Clear History could restore advice
            // the user just deleted. Two shapes are still legitimate after the
            // cutoff: a genuinely fresh observation, and a fresh failure that
            // retains no pre-clear evidence (that is how "no credentials"
            // reaches the advisor after a deletion).
            if let cutoff = clearedAt {
                let hasFreshObservation = state.observedAt.map { $0 > cutoff } ?? false
                let isFreshFailure = state.observedAt == nil
                    && state.windows.isEmpty
                    && (state.probeAt.map { $0 > cutoff } ?? false)
                guard hasFreshObservation || isFreshFailure else { return .rejectedByCutoff }
            }
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return .failed }
            defer { sqlite3_finalize(stmt) }
            bind(stmt, 1, state.provider.rawValue)
            sqlite3_bind_int64(stmt, 2, Int64(state.generation))
            if let observedAt = state.observedAt {
                sqlite3_bind_double(stmt, 3, observedAt.timeIntervalSince1970)
            } else {
                sqlite3_bind_null(stmt, 3)
            }
            bind(stmt, 4, state.completeness.rawValue)
            bind(stmt, 5, json)
            return sqlite3_step(stmt) == SQLITE_DONE ? .saved : .failed
        } ?? .failed
    }

    public func providerState(_ provider: ProviderID) -> ProviderState? {
        providerStates()[provider]
    }

    /// Every persisted current state, keyed by provider. An empty table means
    /// "no decision input yet" — callers must treat that as unknown, not as
    /// zero usage.
    public func providerStates() -> [ProviderID: ProviderState] {
        withLock { db -> [ProviderID: ProviderState] in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT payload FROM provider_state", -1, &stmt, nil) == SQLITE_OK else {
                return [:]
            }
            var out: [ProviderID: ProviderState] = [:]
            while sqlite3_step(stmt) == SQLITE_ROW {
                guard let c = sqlite3_column_text(stmt, 0),
                      let data = String(cString: c).data(using: .utf8),
                      let state = try? Self.stateDecoder.decode(ProviderState.self, from: data) else { continue }
                out[state.provider] = state
            }
            return out
        } ?? [:]
    }

    // MARK: meta

    public func meta(_ key: String) -> String? {
        withLock { db in
            var stmt: OpaquePointer?
            defer { sqlite3_finalize(stmt) }
            guard sqlite3_prepare_v2(db, "SELECT value FROM meta WHERE key = ?", -1, &stmt, nil) == SQLITE_OK else { return nil }
            bind(stmt, 1, key)
            guard sqlite3_step(stmt) == SQLITE_ROW, let c = sqlite3_column_text(stmt, 0) else { return nil }
            return String(cString: c)
        } ?? nil
    }

    public func setMeta(_ key: String, _ value: String) {
        _ = try? run("INSERT OR REPLACE INTO meta(key, value) VALUES (?, ?)", [key, value])
    }

    // MARK: schema

    private func migrate() throws {
        let version = try userVersion()
        if version < 1 {
            try exec("""
            CREATE TABLE IF NOT EXISTS sample (
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
            )
            """)
            try exec("CREATE INDEX IF NOT EXISTS sample_series ON sample(provider, window_id, observed_at)")
            try exec("CREATE INDEX IF NOT EXISTS sample_time ON sample(observed_at)")
            try exec("CREATE TABLE IF NOT EXISTS meta (key TEXT PRIMARY KEY, value TEXT NOT NULL)")
            try exec("PRAGMA user_version = 1")
        }
        if version < 2 {
            // Additive only: history rows and their meaning are untouched.
            try exec("""
            CREATE TABLE IF NOT EXISTS provider_state (
                provider TEXT PRIMARY KEY,
                generation INTEGER NOT NULL,
                observed_at REAL,
                completeness TEXT NOT NULL,
                payload TEXT NOT NULL
            )
            """)
            try exec("PRAGMA user_version = 2")
        }
    }

    private func userVersion() throws -> Int32 {
        guard let db else { throw StoreError.open("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "PRAGMA user_version", -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return 0 }
        return sqlite3_column_int(stmt, 0)
    }

    // MARK: plumbing

    private func withLock<T>(_ body: (OpaquePointer) -> T) -> T? {
        lock.lock(); defer { lock.unlock() }
        guard let db else { return nil }
        return body(db)
    }

    private func bind(_ stmt: OpaquePointer?, _ index: Int32, _ value: String) {
        sqlite3_bind_text(stmt, index, value, -1, sqliteTransient)
    }

    private func run(_ sql: String, _ args: [Any]) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw StoreError.open("closed") }
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.prepare(String(cString: sqlite3_errmsg(db)))
        }
        defer { sqlite3_finalize(stmt) }
        for (i, arg) in args.enumerated() {
            let idx = Int32(i + 1)
            switch arg {
            case let s as String: bind(stmt, idx, s)
            case let d as Double: sqlite3_bind_double(stmt, idx, d)
            case let i as Int: sqlite3_bind_int64(stmt, idx, Int64(i))
            default: sqlite3_bind_null(stmt, idx)
            }
        }
        let rc = sqlite3_step(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            throw StoreError.step(String(cString: sqlite3_errmsg(db)))
        }
    }

    private func exec(_ sql: String) throws {
        lock.lock(); defer { lock.unlock() }
        guard let db else { throw StoreError.open("closed") }
        var err: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK else {
            let message = err.map { String(cString: $0) } ?? "exec failed"
            sqlite3_free(err)
            throw StoreError.step(message)
        }
    }
}
