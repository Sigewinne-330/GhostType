import CryptoKit
import XCTest
@testable import GhostType

final class LocalFileSecretStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!
    private var store: LocalFileSecretStore!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("LocalFileSecretStoreTests-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appendingPathComponent("test-secrets.enc")
        let key = SymmetricKey(size: .bits256)
        store = LocalFileSecretStore(fileURL: fileURL, symmetricKey: key)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Round Trip

    func testSetAndGetSecret() throws {
        try store.setSecret("sk-test-12345", for: .llmOpenAI)

        let retrieved = try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction)
        XCTAssertEqual(retrieved, "sk-test-12345")
    }

    func testGetSecretReturnsNilWhenMissing() throws {
        let retrieved = try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction)
        XCTAssertNil(retrieved)
    }

    func testDeleteSecret() throws {
        try store.setSecret("sk-test-12345", for: .llmOpenAI)
        try store.deleteSecret(for: .llmOpenAI)

        let retrieved = try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction)
        XCTAssertNil(retrieved)
    }

    func testDeleteSecretDoesNotAffectOtherKeys() throws {
        try store.setSecret("key-a", for: .llmOpenAI)
        try store.setSecret("key-b", for: .asrOpenAI)

        try store.deleteSecret(for: .llmOpenAI)

        let remaining = try store.getSecret(for: .asrOpenAI, policy: .noUserInteraction)
        XCTAssertEqual(remaining, "key-b")
    }

    // MARK: - Overwrite

    func testOverwriteSecret() throws {
        try store.setSecret("old-value", for: .llmOpenAI)
        try store.setSecret("new-value", for: .llmOpenAI)

        let retrieved = try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction)
        XCTAssertEqual(retrieved, "new-value")
    }

    // MARK: - Multiple Keys

    func testMultipleKeys() throws {
        try store.setSecret("openai-key", for: .llmOpenAI)
        try store.setSecret("anthropic-key", for: .llmAnthropic)
        try store.setSecret("deepgram-key", for: .asrDeepgram)

        XCTAssertEqual(try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction), "openai-key")
        XCTAssertEqual(try store.getSecret(for: .llmAnthropic, policy: .noUserInteraction), "anthropic-key")
        XCTAssertEqual(try store.getSecret(for: .asrDeepgram, policy: .noUserInteraction), "deepgram-key")
    }

    // MARK: - Delete All

    func testDeleteAllSecrets() throws {
        try store.setSecret("key-a", for: .llmOpenAI)
        try store.setSecret("key-b", for: .asrOpenAI)

        let report = store.deleteAllSecrets()
        XCTAssertFalse(report.requiresAttention)

        XCTAssertNil(try store.getSecret(for: .llmOpenAI, policy: .noUserInteraction))
        XCTAssertNil(try store.getSecret(for: .asrOpenAI, policy: .noUserInteraction))
    }

    // MARK: - Saved Count

    func testSavedSecretCount() throws {
        XCTAssertEqual(store.savedSecretCount(), 0)

        try store.setSecret("key-a", for: .llmOpenAI)
        XCTAssertEqual(store.savedSecretCount(), 1)

        try store.setSecret("key-b", for: .asrOpenAI)
        XCTAssertEqual(store.savedSecretCount(), 2)

        try store.deleteSecret(for: .llmOpenAI)
        XCTAssertEqual(store.savedSecretCount(), 1)
    }

    // MARK: - Self Check

    func testRunSelfCheckWithNoFile() {
        let report = store.runSelfCheck()
        XCTAssertFalse(report.requiresAttention)
        XCTAssertTrue(report.guidance.contains { $0.contains("No credentials file") })
    }

    func testRunSelfCheckWithCredentials() throws {
        try store.setSecret("key-a", for: .llmOpenAI)

        let report = store.runSelfCheck()
        XCTAssertFalse(report.requiresAttention)
        XCTAssertEqual(report.foundCurrentItems, 1)
    }

    // MARK: - Encryption Verification

    func testFileIsNotPlaintext() throws {
        let secretValue = "super-secret-api-key-that-should-not-appear-in-plaintext"
        try store.setSecret(secretValue, for: .llmOpenAI)

        let rawData = try Data(contentsOf: fileURL)
        let rawString = String(data: rawData, encoding: .utf8) ?? ""
        XCTAssertFalse(rawString.contains(secretValue), "Secret appears in plaintext in the encrypted file!")
        XCTAssertFalse(rawString.contains("llmOpenAI"), "Key name appears in plaintext in the encrypted file!")
    }

    // MARK: - Wrong Key Cannot Decrypt

    func testWrongKeyCannotDecrypt() throws {
        try store.setSecret("my-secret", for: .llmOpenAI)

        let wrongKey = SymmetricKey(size: .bits256)
        let wrongStore = LocalFileSecretStore(fileURL: fileURL, symmetricKey: wrongKey)

        XCTAssertThrowsError(try wrongStore.getSecret(for: .llmOpenAI, policy: .noUserInteraction))
    }
}
