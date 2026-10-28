import XCTest
@testable import QuotaBarKit

/// Command Code credential discovery. The product exposes the key in three
/// places (two environment variables, the CLI's auth file, and the OpenCode
/// provider config), so the order and the rejection rules are part of the
/// contract: a wrong guess means a "no credentials" card for a user who is
/// signed in.
final class CredentialDiscoveryTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("quotabar-cred-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: dir)
    }

    private func write(_ name: String, _ body: String) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try body.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: auth file parsing

    func testTopLevelKeyIsAccepted() {
        let data = Data(#"{"apiKey":"cc_live_1234567890"}"#.utf8)
        XCTAssertEqual(CommandCode.keyFromAuthFile(data), "cc_live_1234567890")
    }

    func testNestedTokenIsAccepted() {
        let data = Data(#"{"auth":{"access_token":"  cc_live_abcdefgh  "}}"#.utf8)
        XCTAssertEqual(CommandCode.keyFromAuthFile(data), "cc_live_abcdefgh")
    }

    func testOAuthStyleTopLevelTokenBeatsNested() {
        let data = Data(#"{"accessToken":"cc_live_top123456","auth":{"apiKey":"cc_live_nested1234"}}"#.utf8)
        XCTAssertEqual(CommandCode.keyFromAuthFile(data), "cc_live_top123456")
    }

    func testEnvironmentPlaceholderIsRejected() {
        let data = Data(#"{"apiKey":"{env:COMMANDCODE_API_KEY}"}"#.utf8)
        XCTAssertNil(CommandCode.keyFromAuthFile(data), "a placeholder is not a key")
    }

    func testShortValueIsRejected() {
        let data = Data(#"{"apiKey":"abc"}"#.utf8)
        XCTAssertNil(CommandCode.keyFromAuthFile(data), "tiny strings are more likely a boolean/status field")
    }

    func testNonStringAndUnknownShapesAreRejected() {
        XCTAssertNil(CommandCode.keyFromAuthFile(Data(#"{"apiKey":12345678}"#.utf8)))
        XCTAssertNil(CommandCode.keyFromAuthFile(Data(#"{"user":{"apiKey":"cc_live_1234567890"}}"#.utf8)))
        XCTAssertNil(CommandCode.keyFromAuthFile(Data("not json".utf8)))
        XCTAssertNil(CommandCode.keyFromAuthFile(Data("[]".utf8)))
    }

    // MARK: precedence

    func testEnvironmentBeatsAuthFileAndConfig() throws {
        let auth = try write("auth.json", #"{"apiKey":"cc_live_fromauth1"}"#)
        let config = try write("opencode.json", #"{"providers":{"commandcode":{"settings":{"apiKey":"cc_live_fromconfig"}}}}"#)
        let key = CommandCode.discoverKey(
            environment: ["COMMANDCODE_API_KEY": "  cc_live_fromenv  "],
            configURLs: [config],
            authURLs: [auth]
        )
        XCTAssertEqual(key, "cc_live_fromenv")
    }

    func testOfficialCLIVariableIsRead() {
        let key = CommandCode.discoverKey(
            environment: ["COMMAND_CODE_API_KEY": "cc_live_official"],
            configURLs: [],
            authURLs: []
        )
        XCTAssertEqual(key, "cc_live_official")
    }

    func testAuthFileBeatsConfigFile() throws {
        let auth = try write("auth.json", #"{"apiKey":"cc_live_fromauth1"}"#)
        let config = try write("opencode.json", #"{"providers":{"commandcode":{"settings":{"apiKey":"cc_live_fromconfig"}}}}"#)
        let key = CommandCode.discoverKey(environment: [:], configURLs: [config], authURLs: [auth])
        XCTAssertEqual(key, "cc_live_fromauth1")
    }

    func testConfigFileIsTheLastResort() throws {
        let missingAuth = dir.appendingPathComponent("nope.json")
        let config = try write("opencode.json", #"{"provider":{"commandcode":{"settings":{"apiKey":"cc_live_fromconfig"}}}}"#)
        let key = CommandCode.discoverKey(environment: [:], configURLs: [config], authURLs: [missingAuth])
        XCTAssertEqual(key, "cc_live_fromconfig")
    }

    func testConfigPlaceholderIsNotReturned() throws {
        let config = try write("opencode.json", #"{"providers":{"commandcode":{"settings":{"apiKey":"{env:HOME}"}}}}"#)
        XCTAssertNil(CommandCode.discoverKey(environment: [:], configURLs: [config], authURLs: []))
    }

    func testNothingFoundReturnsNil() {
        XCTAssertNil(CommandCode.discoverKey(environment: [:], configURLs: [], authURLs: []))
    }

    func testDefaultAuthURLsCoverTheCLILocation() {
        let paths = CommandCode.defaultAuthURLs().map(\.path)
        XCTAssertTrue(paths.contains { $0.hasSuffix("/.commandcode/auth.json") })
    }
}
