import Foundation
import Darwin
import QuotaBarKit

// `QuotaBar --advise-json [--task-minutes N]`
//
// Read-only sibling of `--status-json`: it reads the persisted *current state*
// (one atomic record per provider), evaluates it with the same pure function the
// popover uses, and prints a versioned document. No GUI, no network, no
// credentials, no history rows.
//
// The two surfaces are deliberately separate:
//   --status-json  observation contract, schema v1, frozen
//   --advise-json  decision contract, its own schema v1, may return `unknown`

enum AdviseCLI {
    struct ErrorDocument: Encodable {
        let schemaVersion: Int
        let error: String
    }

    static func run(arguments: [String]) -> Never {
        let url = TelemetryStore.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            emitError("no local history store; launch QuotaBar once")
        }
        guard let store = try? TelemetryStore(path: url, createDirectory: false, readOnly: true) else {
            emitError("cannot open the local history store")
        }
        let advice = Advisor.evaluate(
            states: store.providerStates(),
            taskMinutes: taskMinutes(from: arguments)
        )
        guard let json = encode(advice) else { emitError("failed to encode advice") }
        print(json)
        exit(0)
    }

    /// `--task-minutes 60` is optional context for humans and agents; the
    /// provider-scope decision does not depend on it.
    static func taskMinutes(from arguments: [String]) -> Int? {
        guard let index = arguments.firstIndex(of: "--task-minutes"),
              index + 1 < arguments.count,
              let value = Int(arguments[index + 1]),
              value > 0, value <= 24 * 60 else { return nil }
        return value
    }

    private static func encode<T: Encodable>(_ document: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(document) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func emitError(_ message: String) -> Never {
        if let json = encode(ErrorDocument(schemaVersion: 1, error: message)) {
            print(json)
        }
        exit(2)
    }
}
