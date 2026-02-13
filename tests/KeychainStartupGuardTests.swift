import AppKit
import XCTest
@testable import GhostType

@MainActor
final class KeychainStartupGuardTests: XCTestCase {
    private final class KeychainReadSpyStore: KeychainStoring {
        private let lock = NSLock()
        private(set) var readCount = 0

        private func recordRead() {
            lock.lock()
            readCount += 1
            lock.unlock()
        }

        func getSecret(forRef keyRef: String, policy: KeychainReadPolicy) throws -> String? {
            recordRead()
            return nil
        }

        func setSecret(_ value: String, forRef keyRef: String) throws {}

        func deleteSecret(forRef keyRef: String) throws {}

        func getSecret(for key: APISecretKey, policy: KeychainReadPolicy) throws -> String? {
            recordRead()
            return nil
        }

        func setSecret(_ value: String, for key: APISecretKey) throws {}

        func deleteSecret(for key: APISecretKey) throws {}

        func deleteAllSecrets() -> KeychainRepairReport { makeReport() }

        func runSelfCheck() -> KeychainRepairReport { makeReport() }

        func runInteractiveRepair() -> KeychainRepairReport { makeReport() }

        func savedSecretCount() -> Int { 0 }

        private func makeReport() -> KeychainRepairReport {
            KeychainRepairReport(
                checkedAt: Date(),
                runtimeIdentity: KeychainRuntimeIdentity(
                    bundleIdentifier: "tests.bundle",
                    executablePath: "tests.executable",
                    signingIdentifier: nil,
                    teamIdentifier: nil,
                    cdhash: nil,
                    sandboxEnabled: false,
                    keychainAccessGroups: []
                )
            )
        }
    }

    private var originalService: KeychainService!

    override func setUp() {
        super.setUp()
        originalService = AppKeychain.shared
    }

    override func tearDown() {
        AppKeychain.replace(with: originalService)
        super.tearDown()
    }

    func testAppLaunchAndSettingsInitializationDoNotReadCredentials() {
        let spyStore = KeychainReadSpyStore()
        AppKeychain.replace(with: KeychainService(store: spyStore))

        let appDelegate = AppDelegate()
        appDelegate.applicationDidFinishLaunching(
            Notification(name: NSApplication.didFinishLaunchingNotification)
        )

        let defaults = UserDefaults(suiteName: "tests.keychain.startup.guard")!
        defaults.removePersistentDomain(forName: "tests.keychain.startup.guard")
        let engine = EngineConfig(defaults: defaults)
        let prefs = UserPreferences(defaults: defaults)
        let pane = EnginesSettingsPane(engine: engine, prefs: prefs)
        _ = pane.body

        XCTAssertEqual(
            spyStore.readCount,
            0,
            "Startup path and settings construction should not read credentials."
        )
    }
}
