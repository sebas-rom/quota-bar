import XCTest
@testable import QuotaBarKit

/// The Codex source is a user promise: strict `appServer` must never turn into
/// an HTTP request. That promise used to be lost on the store-failure branch of
/// `QuotaModel.live()`, which is exactly the branch a corrupted or unwritable
/// database takes.
@MainActor
final class CodexSourceWiringTests: XCTestCase {
    private let suiteName = "QuotaBarCodexSourceTests"

    private func defaults(_ value: String?) -> UserDefaults {
        let suite = UserDefaults(suiteName: suiteName) ?? .standard
        suite.removePersistentDomain(forName: suiteName)
        if let value { suite.set(value, forKey: "CodexSource") }
        return suite
    }

    func testStrictSourceSurvivesAStoreFailure() {
        let model = QuotaModel.live(defaults: defaults("appServer")) {
            throw StoreError.open("permission denied")
        }
        XCTAssertEqual(model.codexSource, .appServer)
        XCTAssertNil(model.store)
        XCTAssertNotNil(model.storeIssue)
    }

    func testStrictSourceIsUsedWhenTheStoreOpens() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let model = QuotaModel.live(defaults: defaults("appServer")) { store }
        XCTAssertEqual(model.codexSource, .appServer)
        XCTAssertNotNil(model.store)
    }

    func testMissingPreferenceFallsBackToHTTP() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let model = QuotaModel.live(defaults: defaults(nil)) { store }
        XCTAssertEqual(model.codexSource, .http)
    }

    func testUnknownPreferenceFallsBackToHTTP() throws {
        let store = try TelemetryStore.inMemory()
        defer { store.close() }
        let model = QuotaModel.live(defaults: defaults("not-a-source")) { store }
        XCTAssertEqual(model.codexSource, .http)
    }
}
