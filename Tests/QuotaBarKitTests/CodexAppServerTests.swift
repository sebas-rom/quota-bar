import XCTest
@testable import QuotaBarKit

/// The Codex app-server reply is a protocol surface, not a URL we can inspect
/// by hand. These tests pin the mapping from the real `account/rateLimits/read`
/// payload (captured from codex-cli 0.159.2) so a protocol change fails here
/// instead of silently blanking the Codex card.
final class CodexAppServerTests: XCTestCase {
    private func payload(
        primaryPercent: Double = 12,
        secondaryPercent: Double = 40,
        reached: String? = nil,
        extraBuckets: Bool = false
    ) -> [String: Any] {
        var limits: [String: Any] = [
            "limitId": "codex",
            "primary": [
                "usedPercent": primaryPercent,
                "windowDurationMins": 300,
                "resetsAt": 1_793_211_010,
            ],
            "secondary": [
                "usedPercent": secondaryPercent,
                "windowDurationMins": 10_080,
                "resetsAt": 1_793_797_810,
            ],
            "credits": ["hasCredits": false, "unlimited": false, "balance": "0"],
            "planType": "plus",
        ]
        if let reached { limits["rateLimitReachedType"] = reached }
        var root: [String: Any] = [
            "ordinaryUsageAllowed": true,
            "rateLimits": limits,
            "rateLimitResetCredits": ["availableCount": 2],
        ]
        if extraBuckets {
            root["rateLimitsByLimitId"] = [
                "codex": ["planType": "plus"],
                "codex-other": [
                    "primary": ["usedPercent": 5, "windowDurationMins": 60],
                ],
            ]
        }
        return root
    }

    func testDecodesTheRealShape() throws {
        let usage = try CodexAppServer.decodeRateLimits(payload())
        XCTAssertEqual(usage.plan, "plus")
        XCTAssertEqual(usage.windows.map(\.id), ["codex.primary", "codex.secondary"])
        XCTAssertEqual(usage.windows.first?.kind, .primary)
        XCTAssertEqual(usage.windows.first?.percent, 12)
        XCTAssertEqual(usage.windows.first?.windowMinutes, 300)
        XCTAssertEqual(usage.windows.first?.label, "5-hour")
        XCTAssertEqual(usage.windows.last?.kind, .secondary)
        XCTAssertEqual(usage.windows.last?.label, "Weekly")
        XCTAssertEqual(usage.resetCreditsAvailable, 2)
        XCTAssertEqual(usage.hasCredits, false)
        XCTAssertEqual(usage.creditBalance, "0")
        XCTAssertEqual(usage.limitReached, false)
        XCTAssertEqual(usage.ordinaryUsageAllowed, true)
        XCTAssertFalse(usage.windows.contains { $0.isLimited })
    }

    func testResetTimestampIsDecoded() throws {
        let usage = try CodexAppServer.decodeRateLimits(payload())
        let reset = try XCTUnwrap(usage.windows.first?.resetsAt)
        XCTAssertEqual(reset.timeIntervalSince1970, 1_793_211_010, accuracy: 0.5)
    }

    func testReachedLimitMarksFullWindowsAsLimited() throws {
        let usage = try CodexAppServer.decodeRateLimits(
            payload(primaryPercent: 100, reached: "primary")
        )
        XCTAssertEqual(usage.limitReached, true)
        XCTAssertEqual(usage.windows.first?.isLimited, true)
    }

    func testReachedLimitDoesNotMislabelAFreshWindow() throws {
        let usage = try CodexAppServer.decodeRateLimits(
            payload(primaryPercent: 20, secondaryPercent: 100, reached: "secondary")
        )
        XCTAssertEqual(usage.windows.first?.isLimited, false, "only the exhausted bucket is limited")
        XCTAssertEqual(usage.windows.last?.isLimited, true)
    }

    func testReachedLimitNamesOnlyItsOwnBucket() throws {
        let usage = try CodexAppServer.decodeRateLimits(
            payload(primaryPercent: 99, secondaryPercent: 100, reached: "secondary")
        )
        XCTAssertEqual(usage.windows.first?.isLimited, false, "primary never reported reached")
        XCTAssertEqual(usage.windows.last?.isLimited, true)
    }

    func testUnknownReachedValueDoesNotFlagEveryBucket() throws {
        let usage = try CodexAppServer.decodeRateLimits(
            payload(primaryPercent: 100, secondaryPercent: 100, reached: "something_new")
        )
        XCTAssertFalse(usage.windows.contains { $0.isLimited })
        XCTAssertTrue(usage.limitReached)
    }

    func testAdditionalBucketsGetTheirOwnIDs() throws {
        let usage = try CodexAppServer.decodeRateLimits(payload(extraBuckets: true))
        XCTAssertEqual(
            usage.windows.map(\.id),
            ["codex.primary", "codex.secondary", "codex.extra.codex-other.primary"]
        )
        XCTAssertEqual(usage.windows.last?.kind, .additional)
        XCTAssertEqual(usage.windows.last?.label, "1-hour")
    }

    func testAccountIdIsCarriedForHashing() throws {
        var root = payload()
        root["accountId"] = "acct-123"
        let usage = try CodexAppServer.decodeRateLimits(root)
        XCTAssertEqual(usage.accountId, "acct-123")
    }

    func testMissingWindowsFailInsteadOfReturningEmpty() {
        XCTAssertThrowsError(try CodexAppServer.decodeRateLimits([:])) { error in
            XCTAssertEqual(error as? CodexAppServerError, .protocolError)
        }
    }

    func testNonObjectResultIsRejected() {
        XCTAssertThrowsError(try CodexAppServer.decodeRateLimits([1, 2, 3]))
    }

    func testWindowWithoutPercentIsSkipped() throws {
        let root: [String: Any] = [
            "rateLimits": [
                "primary": ["windowDurationMins": 300],
                "secondary": ["usedPercent": 30, "windowDurationMins": 10_080],
            ],
        ]
        let usage = try CodexAppServer.decodeRateLimits(root)
        XCTAssertEqual(usage.windows.map(\.id), ["codex.secondary"])
    }

    func testBinaryDiscoveryPrefersExplicitPaths() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-codex-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\nexit 0\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let found = CodexAppServer.locateBinary(environment: [:], extraPaths: [fake.path])
        XCTAssertEqual(found?.path, fake.path)
    }

    func testErrorMappingMatchesTheCardVocabulary() {
        XCTAssertEqual(CodexAppServerError.notSignedIn.healthState, .noCredentials)
        XCTAssertEqual(CodexAppServerError.protocolError.healthState, .badResponse)
        XCTAssertEqual(CodexAppServerError.binaryNotFound.healthState, .providerDown)
        XCTAssertEqual(CodexAppServerError.timeout.healthState, .providerDown)
        XCTAssertTrue(CodexAppServerError.binaryNotFound.message.contains("codex CLI"))
        XCTAssertFalse(CodexAppServerError.launch.message.lowercased().contains("token"))
    }

    /// The child's stderr is untrusted: it can contain a token, an account id or
    /// a private path. Only a fixed category may ever leave this layer.
    func testChildStderrNeverReachesTheErrorMessage() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-secret-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'ACCT-SECRET-SENTINEL-1234567890 /var/tmp/fake-auth.json' >&2\nexit 1\n"
            .write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        XCTAssertThrowsError(try CodexAppServer.fetchUsage(timeout: 5, binary: fake)) { error in
            let described = String(describing: error)
            XCTAssertFalse(described.contains("SENTINEL"), "raw stderr must never be propagated")
            XCTAssertFalse(described.contains("fake-auth.json"))
            XCTAssertEqual(error as? CodexAppServerError, .protocolError)
            let message = (error as? CodexAppServerError)?.message ?? described
            XCTAssertFalse(message.contains("SENTINEL"))
        }
    }

    /// Regression: `FileHandle.read(upToCount:)` on a Process pipe can block
    /// forever, which silently defeated the hard timeout. The child here never
    /// answers, so the probe must fail fast instead of hanging the caller.
    func testUnresponsiveChildTimesOutInsteadOfHanging() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-hang-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let started = Date()
        XCTAssertThrowsError(try CodexAppServer.fetchUsage(timeout: 0.5, binary: fake)) { error in
            XCTAssertEqual(error as? CodexAppServerError, .timeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the deadline must be enforced")
    }

    func testChildThatExitsImmediatelyFailsFast() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-eof-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\necho 'not signed in' >&2\nexit 1\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let started = Date()
        XCTAssertThrowsError(try CodexAppServer.fetchUsage(timeout: 5, binary: fake)) { error in
            // The stderr tail mentions a login, which must map to notSignedIn
            // rather than a generic crash.
            XCTAssertEqual(error as? CodexAppServerError, .notSignedIn)
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
    }

    /// Every path must reap the child, not just kill it. A repeated timeout is
    /// the case that used to leave a zombie per refresh.
    func testRepeatedTimeoutsStayBounded() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-repeat-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let fake = dir.appendingPathComponent("codex")
        try "#!/bin/sh\nexec sleep 30\n".write(to: fake, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fake.path)

        let started = Date()
        for _ in 0..<3 {
            XCTAssertThrowsError(try CodexAppServer.fetchUsage(timeout: 0.3, binary: fake)) { error in
                XCTAssertEqual(error as? CodexAppServerError, .timeout)
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(started), 6)
    }

    func testMissingBinaryFailsInsteadOfHanging() {
        let missing = URL(fileURLWithPath: "/nonexistent/quotabar/codex")
        XCTAssertThrowsError(try CodexAppServer.fetchUsage(timeout: 0.5, binary: missing))
    }

    func testDefaultBinaryPathsCoverAHostileLaunchdPath() {
        let paths = CodexAppServer.defaultBinaryPaths(environment: ["PATH": "/usr/bin:/bin"])
        XCTAssertTrue(paths.contains("/opt/homebrew/bin/codex"))
        XCTAssertTrue(paths.contains("/usr/local/bin/codex"))
        XCTAssertTrue(paths.contains("/usr/bin/codex"), "PATH entries are searched too")
    }
}
