import Foundation
import Darwin
import QuotaBarKit

// `QuotaBar --status-json` — read-only, no GUI, no secrets.
// Exits 0 with a status document; exits 2 with an error document.
//
// Success and error documents share one key (`schemaVersion`). The error
// document used to emit `schema_version`, which forced machine clients to
// special-case failures; docs/STATUS.md records the correction.

enum StatusCLI {
    /// Error payload for a failed status read. Same envelope key as the
    /// success document, so one decoder handles both.
    struct ErrorDocument: Encodable {
        let schemaVersion: Int
        let error: String
    }

    static func run() -> Never {
        let url = TelemetryStore.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            emitError("no local history store; launch QuotaBar once")
        }
        guard let store = try? TelemetryStore(path: url, createDirectory: false, readOnly: true) else {
            emitError("cannot open the local history store")
        }
        let report = StatusReport.build(from: store.latestObservations())
        guard let json = encode(report) else {
            emitError("failed to encode status")
        }
        print(json)
        exit(0)
    }

    static func encode<T: Encodable>(_ document: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func emitError(_ message: String) -> Never {
        if let json = encode(ErrorDocument(schemaVersion: 1, error: message)) {
            print(json)
        }
        exit(2)
    }
}
