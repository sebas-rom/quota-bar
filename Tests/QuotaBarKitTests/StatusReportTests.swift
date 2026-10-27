import XCTest
@testable import QuotaBarKit

final class StatusReportTests: XCTestCase {
    private func snapshot(_ provider: ProviderID, _ windowID: String, percent: Double,
                          at date: Date, reset: Date? = nil, origin: SnapshotOrigin = .network,
                          plan: String? = nil) -> ProviderSnapshot {
        ProviderSnapshot(
            provider: provider,
            windows: [QuotaWindow(id: windowID, kind: .rolling, label: windowID,
                                  percent: percent, resetsAt: reset, windowMinutes: 300, isLimited: false)],
            plan: plan, origin: origin, source: "test", observedAt: date
        )
    }

    func testLatestObservationPerWindowAndReportShape() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let now = Date()

        _ = store.insert(snapshot(.codex, "codex.primary", percent: 20, at: now.addingTimeInterval(-1_200), plan: "plus"))
        _ = store.insert(snapshot(.codex, "codex.primary", percent: 30, at: now.addingTimeInterval(-60), plan: "plus"))
        _ = store.insert(snapshot(.go, "go.rolling", percent: 74, at: now.addingTimeInterval(-30)))
        _ = store.insert(snapshot(.codex, "codex.secondary", percent: 39, at: now.addingTimeInterval(-900), origin: .localLog))

        let latest = store.latestObservations()
        XCTAssertEqual(latest.count, 3)
        XCTAssertEqual(latest.first { $0.windowID == "codex.primary" }?.percent, 30)

        let report = StatusReport.build(from: latest, now: now)
        XCTAssertEqual(report.schemaVersion, 1)
        XCTAssertEqual(report.providers.map(\.id), ["opencode-go", "codex"])
        let codex = try XCTUnwrap(report.providers.first { $0.id == "codex" })
        XCTAssertEqual(codex.plan, "plus")
        XCTAssertEqual(codex.windows.count, 2)
        let primary = try XCTUnwrap(codex.windows.first { $0.id == "codex.primary" })
        XCTAssertEqual(primary.percentUsed, 30)
        XCTAssertFalse(primary.stale)
        XCTAssertEqual(primary.ageSeconds, 60)
        let secondary = try XCTUnwrap(codex.windows.first { $0.id == "codex.secondary" })
        XCTAssertTrue(secondary.stale, "older than 15 minutes")
        XCTAssertEqual(secondary.origin, "localLog")
        XCTAssertTrue(report.fresh)
    }

    func testReadOnlyStoreCanReadWithoutMigrating() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-status-\(UUID().uuidString).sqlite")
        defer { try? FileManager.default.removeItem(at: url) }
        do {
            let writer = try TelemetryStore(path: url)
            _ = writer.insert(snapshot(.commandCode, "commandcode.5h", percent: 12, at: Date()))
            writer.close()
        }
        let reader = try TelemetryStore(path: url, createDirectory: false, readOnly: true)
        XCTAssertEqual(reader.latestObservations().count, 1)
        XCTAssertEqual(reader.latestObservations().first?.percent, 12)
        reader.close()
    }
}
