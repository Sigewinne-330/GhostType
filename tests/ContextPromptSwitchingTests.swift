import XCTest
@testable import GhostType

final class ContextPromptSwitchingTests: XCTestCase {
    func testRouterPrefersDomainExactOverAppBundleRule() {
        let snapshot = makeSnapshot(
            bundleID: "com.tencent.xinWeChat",
            domain: "chat.openai.com",
            title: "ChatGPT"
        )
        let rules = [
            RoutingRule(
                id: "bundle-rule",
                priority: 1,
                matchType: .appBundleId,
                matchValue: "com.tencent.xinWeChat",
                targetPresetId: "wechat"
            ),
            RoutingRule(
                id: "domain-rule",
                priority: 100,
                matchType: .domainExact,
                matchValue: "chat.openai.com",
                targetPresetId: "chatgpt"
            ),
        ]

        let decision = ContextPromptRouter.decide(snapshot: snapshot, rules: rules, defaultPresetId: "default")
        XCTAssertEqual(decision.presetId, "chatgpt")
        XCTAssertEqual(decision.matchedRule?.id, "domain-rule")
    }

    func testRouterSupportsDomainSuffix() {
        let snapshot = makeSnapshot(
            bundleID: "com.apple.Safari",
            domain: "workspace.chat.openai.com",
            title: "ChatGPT - Safari"
        )
        let rules = [
            RoutingRule(
                id: "suffix-rule",
                priority: 5,
                matchType: .domainSuffix,
                matchValue: "openai.com",
                targetPresetId: "chatgpt"
            ),
        ]

        let decision = ContextPromptRouter.decide(snapshot: snapshot, rules: rules, defaultPresetId: "default")
        XCTAssertEqual(decision.presetId, "chatgpt")
    }

    func testResolverSkipsAutoSwitchForAskMode() {
        let snapshot = makeSnapshot(bundleID: "com.apple.Safari", domain: "chat.openai.com", title: "ChatGPT")
        let rules = [
            RoutingRule(
                id: "domain-rule",
                priority: 10,
                matchType: .domainExact,
                matchValue: "chat.openai.com",
                targetPresetId: "chatgpt"
            ),
        ]

        let resolution = ContextPresetResolver.resolve(
            mode: .ask,
            autoSwitchEnabled: true,
            lockCurrentPreset: false,
            currentPresetId: "current",
            defaultPresetId: "default",
            rules: rules,
            snapshot: snapshot
        )

        XCTAssertEqual(resolution.presetId, "current")
        XCTAssertFalse(resolution.didAutoSwitch)
        XCTAssertNil(resolution.matchedRule)
    }

    func testResolverHonorsLockCurrentPreset() {
        let snapshot = makeSnapshot(bundleID: "notion.id", domain: nil, title: "Notion")
        let rules = [
            RoutingRule(
                id: "notion-rule",
                priority: 1,
                matchType: .appBundleId,
                matchValue: "notion.id",
                targetPresetId: "notion"
            ),
        ]

        let resolution = ContextPresetResolver.resolve(
            mode: .dictate,
            autoSwitchEnabled: true,
            lockCurrentPreset: true,
            currentPresetId: "manual",
            defaultPresetId: "default",
            rules: rules,
            snapshot: snapshot
        )

        XCTAssertEqual(resolution.presetId, "manual")
        XCTAssertFalse(resolution.didAutoSwitch)
        XCTAssertNil(resolution.matchedRule)
    }

    private func makeSnapshot(bundleID: String, domain: String?, title: String?) -> ContextSnapshot {
        ContextSnapshot(
            timestamp: Date(),
            frontmostAppBundleId: bundleID,
            frontmostAppName: "App",
            browserType: nil,
            activeDomain: domain,
            activeUrl: domain.map { "https://\($0)" },
            windowTitle: title,
            confidence: .medium,
            source: .windowTitle
        )
    }
}
