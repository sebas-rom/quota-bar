import XCTest
@testable import QuotaBarKit

final class CodexUsageTests: XCTestCase {
    private func json(_ s: String) -> Data { s.data(using: .utf8)! }

    // Shape captured from GET /backend-api/wham/usage (values redacted/adjusted).
    private let liveFixture = """
    {
      "plan_type": "plus",
      "rate_limit": {
        "allowed": true,
        "limit_reached": false,
        "primary_window": { "used_percent": 14, "limit_window_seconds": 18000,
                            "reset_after_seconds": 16671, "reset_at": 1793071738 },
        "secondary_window": { "used_percent": 3, "limit_window_seconds": 604800,
                              "reset_after_seconds": 570806, "reset_at": 1793625873 }
      },
      "credits": { "has_credits": false, "unlimited": false, "balance": "0" },
      "rate_limit_reset_credits": { "available_count": 2 }
    }
    """

    func testDecodesBothWindowsResetCreditsAndPlan() throws {
        let now = Date(timeIntervalSince1970: 1_793_050_000)
        let report = try decodeCodexUsage(json(liveFixture), now: now)
        XCTAssertEqual(report.plan, "plus")
        XCTAssertEqual(report.windows.count, 2)
        XCTAssertEqual(report.windows[0].id, "codex.primary")
        XCTAssertEqual(report.windows[0].label, "5-hour")
        XCTAssertEqual(report.windows[0].percent, 14)
        XCTAssertEqual(report.windows[1].label, "Weekly")
        XCTAssertEqual(report.windows[1].percent, 3)
        XCTAssertEqual(report.windows[0].resetsAt, Date(timeIntervalSince1970: 1_793_071_738),
                       "absolute reset_at wins over reset_after_seconds")
        XCTAssertEqual(report.resetCreditsAvailable, 2)
        XCTAssertFalse(report.limitReached)
    }

    func testResetAfterSecondsIsUsedWhenAbsoluteIsMissing() throws {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let report = try decodeCodexUsage(json("""
        {"rate_limit":{"primary_window":{"used_percent":50,"limit_window_seconds":18000,"reset_after_seconds":600}}}
        """), now: now)
        XCTAssertEqual(report.windows.first?.resetsAt, now.addingTimeInterval(600))
    }

    func testAdditionalAndReviewRateLimitsBecomeExtraWindows() throws {
        let report = try decodeCodexUsage(json("""
        {"plan_type":"pro",
         "rate_limit":{"primary_window":{"used_percent":10,"limit_window_seconds":18000}},
         "code_review_rate_limit":{"primary_window":{"used_percent":40,"limit_window_seconds":18000}},
         "additional_rate_limits":[{"limit_id":"codex-pro","limit_name":"Pro",
                                    "primary_window":{"used_percent":70,"limit_window_seconds":604800}}]}
        """))
        let ids = report.windows.map(\.id)
        XCTAssertTrue(ids.contains("codex.primary"))
        XCTAssertTrue(ids.contains("codex.review.primary"))
        XCTAssertTrue(ids.contains("codex.extra.codex-pro.primary"))
        XCTAssertEqual(report.windows.first { $0.id == "codex.extra.codex-pro.primary" }?.percent, 70)
    }

    func testLimitReachedFlagsOnlyFullWindows() throws {
        let report = try decodeCodexUsage(json("""
        {"rate_limit":{"limit_reached":true,
          "primary_window":{"used_percent":100,"limit_window_seconds":18000},
          "secondary_window":{"used_percent":40,"limit_window_seconds":604800}}}
        """))
        XCTAssertTrue(report.limitReached)
        XCTAssertEqual(report.windows.first { $0.id == "codex.primary" }?.isLimited, true)
        XCTAssertEqual(report.windows.first { $0.id == "codex.secondary" }?.isLimited, false)
    }

    func testMalformedOrEmptyPayloadsThrow() {
        XCTAssertThrowsError(try decodeCodexUsage(json("{}")))
        XCTAssertThrowsError(try decodeCodexUsage(json("not json")))
        XCTAssertThrowsError(try decodeCodexUsage(json("{\"rate_limit\":{}}")))
    }

    func testStringNumbersAreTolerated() throws {
        let report = try decodeCodexUsage(json("""
        {"rate_limit":{"primary_window":{"used_percent":"12.5","limit_window_seconds":"18000"}}}
        """))
        XCTAssertEqual(report.windows.first?.percent, 12.5)
        XCTAssertEqual(report.windows.first?.label, "5-hour")
    }

    // MARK: local session log

    private func makeSession(lines: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-sessions-\(UUID().uuidString)", isDirectory: true)
        let day = root.appendingPathComponent("2026/10/26", isDirectory: true)
        try FileManager.default.createDirectory(at: day, withIntermediateDirectories: true)
        let file = day.appendingPathComponent("rollout-test.jsonl")
        try lines.joined(separator: "\n").write(to: file, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func tokenCountLine(at timestamp: String, primary: Double, secondary: Double) -> String {
        """
        {"timestamp":"\(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{},"rate_limits":{"limit_id":"codex","primary":{"used_percent":\(primary),"window_minutes":300,"resets_at":1793071738},"secondary":{"used_percent":\(secondary),"window_minutes":10080,"resets_at":1793625873},"plan_type":"plus"}}}
        """
    }

    func testLocalLogLatestParsesRateLimits() throws {
        let root = try makeSession(lines: [
            #"{"timestamp":"2026-10-26T10:00:00.000Z","type":"session_meta","payload":{"cwd":"/tmp"}}"#,
            tokenCountLine(at: "2026-10-26T10:05:00.000Z", primary: 14, secondary: 3),
        ])
        let observation = try XCTUnwrap(CodexLocalLog.latest(root: root))
        XCTAssertEqual(observation.plan, "plus")
        XCTAssertEqual(observation.windows.count, 2)
        XCTAssertEqual(observation.windows[0].percent, 14)
        XCTAssertEqual(observation.windows[0].label, "5-hour")
        XCTAssertEqual(observation.windows[1].percent, 3)
        XCTAssertEqual(observation.observedAt, ISO8601DateFormatter().date(from: "2026-10-26T10:05:00Z"))
    }

    func testLocalLogIgnoresUnrelatedLinesAndDeduplicates() throws {
        let root = try makeSession(lines: [
            #"{"timestamp":"2026-10-26T10:00:00.000Z","type":"event_msg","payload":{"type":"task_started"}}"#,
            tokenCountLine(at: "2026-10-26T10:05:00.000Z", primary: 14, secondary: 3),
            tokenCountLine(at: "2026-10-26T10:05:00.000Z", primary: 14, secondary: 3),
        ])
        let observations = CodexLocalLog.observations(since: .distantPast, root: root)
        XCTAssertEqual(observations.count, 1, "identical snapshots are deduplicated")
    }

    func testLocalLogRejectsInvalidTimestamps() throws {
        let root = try makeSession(lines: [
            #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9,"window_minutes":300}}}}"#,
            #"{"timestamp":"not-a-date","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":9,"window_minutes":300}}}}"#,
        ])
        XCTAssertNil(CodexLocalLog.latest(root: root))
        XCTAssertTrue(CodexLocalLog.observations(since: .distantPast, root: root).isEmpty)
    }

    func testLocalLogFiltersByRecordTimestampNotFileAge() throws {
        let root = try makeSession(lines: [
            tokenCountLine(at: "2026-10-26T10:05:00.000Z", primary: 14, secondary: 3),
        ])
        // File mtime is "now" and passes the prefilter, but the record is old.
        let cutoff = ISO8601DateFormatter().date(from: "2026-10-26T12:00:00Z")!
        XCTAssertTrue(CodexLocalLog.observations(since: cutoff, root: root).isEmpty)
    }

    func testLocalLogSinceFiltersOldFiles() throws {
        let root = try makeSession(lines: [
            tokenCountLine(at: "2026-10-26T10:05:00.000Z", primary: 14, secondary: 3),
        ])
        let future = Date().addingTimeInterval(86_400)
        XCTAssertTrue(CodexLocalLog.observations(since: future, root: root).isEmpty)
        XCTAssertEqual(CodexLocalLog.observations(since: .distantPast, root: root).count, 1)
    }
}

// MARK: - Outgoing request construction

final class ProbeRequestTests: XCTestCase {
    func testGoRequestUsesBearerAuthorizationHeader() {
        let request = QuotaProbes.goRequest(key: "test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer test-key")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/json")
        XCTAssertNil(request.value(forHTTPHeaderField: "Bearer test-key"),
                     "the credential must never be used as a header name")
    }

    func testCodexRequestUsesBearerAndAccountHeaders() {
        let request = QuotaProbes.codexRequest(token: "tok-123", accountId: "acct-1")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-123")
        XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-1")
        XCTAssertNil(request.value(forHTTPHeaderField: "Bearer tok-123"))
    }

    func testCodexRequestOmitsEmptyAccountHeader() {
        let request = QuotaProbes.codexRequest(token: "tok", accountId: "")
        XCTAssertNil(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"))
    }

    func testCodexProbeSendsHeadersToTheWire() async throws {
        MockURLProtocol.handler = { request in
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer tok-wire")
            XCTAssertEqual(request.value(forHTTPHeaderField: "ChatGPT-Account-Id"), "acct-wire")
            return (HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!,
                    Data("""
                    {"plan_type":"plus","rate_limit":{"primary_window":{"used_percent":11,"limit_window_seconds":18000},
                     "secondary_window":{"used_percent":2,"limit_window_seconds":604800}}}
                    """.utf8))
        }
        defer { MockURLProtocol.handler = nil }

        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let probes = QuotaProbes(session: URLSession(configuration: config))
        let result = await probes.codex(credentials: CodexCreds(token: "tok-wire", accountId: "acct-wire"))

        guard case let .ok(snapshot) = result else {
            return XCTFail("expected ok, got \(result)")
        }
        XCTAssertEqual(snapshot.provider, .codex)
        XCTAssertEqual(snapshot.plan, "plus")
        XCTAssertEqual(snapshot.windows.first?.percent, 11)
        XCTAssertEqual(snapshot.accountRef, accountRef("acct-wire"))
    }
}

final class MockURLProtocol: URLProtocol {
    static var handler: ((URLRequest) -> (HTTPURLResponse, Data))?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let handler = Self.handler else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
            return
        }
        let (response, data) = handler(request)
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
