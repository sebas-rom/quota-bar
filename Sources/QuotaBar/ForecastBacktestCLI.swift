import Foundation
import Darwin
import QuotaBarKit

// `qbar --forecast-backtest` — read-only replay report. Never writes, probes,
// or reads credentials. `insufficient_data` is the expected initial result.

enum ForecastBacktestCLI {
    // Rolling windows (Go 5h, Codex primary) advance their reset with time and
    // have no fixed cycle to score; only fixed-cycle windows are replayed.
    private static let windows: [(ProviderID, String, Int)] = [
        (.go, "go.weekly", 10_080),
        (.go, "go.monthly", 43_200),
        (.codex, "codex.secondary", 10_080),
        (.commandCode, "commandcode.5h", 300),
        (.commandCode, "commandcode.weekly", 10_080),
        (.commandCode, "commandcode.monthly", 43_200),
    ]

    static func run() -> Never {
        let url = TelemetryStore.defaultPath()
        guard FileManager.default.fileExists(atPath: url.path) else {
            emitError("no local history store; launch QuotaBar once")
        }
        guard let store = try? TelemetryStore(path: url, createDirectory: false, readOnly: true) else {
            emitError("cannot open the local history store")
        }
        let now = Date()
        let since = now.addingTimeInterval(-90 * 86_400)
        let groups = windows.compactMap { provider, windowID, minutes -> BacktestGroup? in
            let samples = store.networkSamples(provider: provider, windowID: windowID, since: since)
            guard !samples.isEmpty else { return nil }
            return ForecastBacktest.evaluate(
                provider: provider,
                windowID: windowID,
                windowMinutes: minutes,
                samples: samples,
                now: now
            )
        }
        let report = ForecastBacktest.report(groups: groups, now: now)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(report), let json = String(data: data, encoding: .utf8) else {
            emitError("failed to encode report")
        }
        print(json)
        exit(0)
    }

    private static func emitError(_ message: String) -> Never {
        let payload: [String: Any] = ["schema_version": 1, "error": message]
        if let data = try? JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted, .sortedKeys]),
           let json = String(data: data, encoding: .utf8) {
            print(json)
        }
        exit(2)
    }
}
