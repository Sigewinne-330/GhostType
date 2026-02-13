import XCTest
@testable import GhostType

@MainActor
final class SettingsBindingTests: XCTestCase {
    func testEnginesPaneCanBeConstructedWithoutAppState() {
        let defaults = UserDefaults(suiteName: "tests.settings.engines")!
        defaults.removePersistentDomain(forName: "tests.settings.engines")
        let engine = EngineConfig(defaults: defaults)
        let prefs = UserPreferences(defaults: defaults)

        let pane = EnginesSettingsPane(engine: engine, prefs: prefs)
        _ = pane.body
    }

    func testGeneralPaneCanBeConstructedWithModuleDependencies() {
        let defaults = UserDefaults(suiteName: "tests.settings.general")!
        defaults.removePersistentDomain(forName: "tests.settings.general")
        let engine = EngineConfig(defaults: defaults)
        let prefs = UserPreferences(defaults: defaults)
        let runtime = RuntimeState()

        let pane = GeneralSettingsPane(engine: engine, prefs: prefs, runtime: runtime)
        _ = pane.body
    }
}
