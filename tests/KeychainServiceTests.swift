import XCTest
@testable import GhostType

final class KeychainServiceTests: XCTestCase {
    override func setUp() {
        super.setUp()
        AppKeychain.replace(with: .dryRun)
        APISecretKey.allCases.forEach { AppKeychain.shared.clearPresenceHint(for: $0) }
    }

    override func tearDown() {
        APISecretKey.allCases.forEach { AppKeychain.shared.clearPresenceHint(for: $0) }
        AppKeychain.replace(with: .dryRun)
        super.tearDown()
    }

    func testSetGetDeleteRoundTrip() throws {
        let key: APISecretKey = .llmOpenAI
        try AppKeychain.shared.setSecret("demo-secret", for: key)

        let value = try AppKeychain.shared.getSecret(for: key, policy: .noUserInteraction)
        XCTAssertEqual(value, "demo-secret")

        try AppKeychain.shared.deleteSecret(for: key)
        let deleted = try AppKeychain.shared.getSecret(for: key, policy: .noUserInteraction)
        XCTAssertNil(deleted)
    }

    func testPresenceHintsFollowOperations() throws {
        let key: APISecretKey = .asrOpenAI
        XCTAssertEqual(AppKeychain.shared.presenceHint(for: key), .unknown)

        try AppKeychain.shared.setSecret("k-123", for: key)
        XCTAssertEqual(AppKeychain.shared.presenceHint(for: key), .present)

        try AppKeychain.shared.deleteSecret(for: key)
        XCTAssertEqual(AppKeychain.shared.presenceHint(for: key), .missing)
    }

    func testDryRunSelfCheckDoesNotNeedSystemKeychain() {
        let report = AppKeychain.shared.runSelfCheck()
        XCTAssertFalse(report.guidance.isEmpty)
        XCTAssertFalse(report.requiresAttention)
    }
}
