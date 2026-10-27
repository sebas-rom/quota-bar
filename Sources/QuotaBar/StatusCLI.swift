import Foundation
import Darwin
import QuotaBarKit

// `QuotaBar --status-json` — read-only, no GUI, no secrets.
// Exits 0 with a status document; exits 2 with an error document.

enum StatusCLI {
    static func run() -> Never {
        let url = TelemetryStore.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            emitError("no local history store; launch QuotaBar once")
        }
        guard let store = try? TelemetryStore(path: url, createDirectory: false, readOnly: true) else {
            emitError("cannot open the local history store")
        }
        let report = StatusReport.build(from: store.latestObservations())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            emitError("failed to encode status")
        }
        print(json)
        exit(0)
    }

    private static func emitError(_ message: String) -> Never {
        let payload: [String: Any] = [
            "schema_version": 1,
            "error": message,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(2)
    }
}
