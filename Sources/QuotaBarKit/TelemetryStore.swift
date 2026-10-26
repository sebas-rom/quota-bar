import Foundation
import SQLite3

// MARK: - Local observation store
//
// A tiny, versioned SQLite database that remembers quota observations so the
// app can answer "how did we get here?" and survive a provider outage with the
// last known values. Read-only with respect to provider data: nothing here is
// uploaded, and no tokens, prompts or message bodies are stored.

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum StoreError: Error, Equatable {
    case open(String)
    case prepare(String)
    case step(String)
}

public final class TelemetryStore: @unchecked Sendable {
    public static let schemaVersion: Int32 = 1

    private var db: OpaquePointer?
    private let lock = NSLock()
    public let path: String

    public static func defaultPath() -> URL {
        homeDir()
            .appendingPathComponent("Library/Application Support/QuotaBar", isDirectory: true)
            .appendingPathComponent("telemetry.sqlite")
    }

    /// In-memory store, useful for tests and the demo harness.
    public static func inMemory() throws -> TelemetryStore {
        try TelemetryStore(path: URL(fileURLWithPath: "memory"), createDirectory: false, memory: true)
    }

    public init(path: URL, createDirectory: Bool = true, memory: Bool = false) throws {
        self.path = memory ? ":memory:" : path.path
        if createDirectory, !memory {
            try? FileManager.default.createDirectory(
                at: path.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
        }
        var handle: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        let rc = sqlite3_open_v2(memory ? ":memory:" : path.path, &handle, flags, nil)
        guard rc == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite open failed (\(rc))"
            if let handle { sqlite3_close(handle) }
            throw StoreError.open(message)
        }
        db = handle
        try exec("PRAGMA journal_mode=WAL")
        try exec("PRAGMA synchronous=NORMAL")
        try exec("PRAGMA busy_timeout=2000")
        try migrate()
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

    public func reset() {
        _ = try? exec("DELETE FROM sample")
        _ = try? exec("DELETE FROM meta")
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
              AND (? IS NULL OR account_ref = ?)
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
