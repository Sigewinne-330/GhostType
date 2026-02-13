# Keychain Startup Audit (GhostType)

## Scope
- Goal: ensure app startup path performs zero Keychain access.
- Covered startup stages:
  - `AppDelegate.applicationDidFinishLaunching`
  - initial settings/detail view load (`onAppear`)
  - provider/bootstrap initialization

## Previous Trigger Points (Before)

1. Startup self-check in AppDelegate:
- Path: `applicationDidFinishLaunching` -> `runKeychainSelfCheck()` -> `KeychainManager.runSelfCheck()` -> `SecItemCopyMatching(...)`
- File: `macos/AppDelegate.swift`

2. Settings view eager reads:
- Path: `EnginesSettingsPane.onAppear` -> `reloadSecretsFromKeychain()` -> `KeychainManager.read(...)`
- Path: `EnginesSettingsPane.onAppear` -> `refreshKeychainHealthReport()` -> `KeychainManager.runSelfCheck()`
- File: `macos/SettingsView.swift`

## Updated Behavior (After)

1. Startup path:
- No Keychain API calls from `applicationDidFinishLaunching`.
- App initialization only configures runtime services and permissions flow.

2. Settings load path:
- `onAppear` no longer reads Keychain or runs self-check.
- Credential fields are reset locally and show guidance text.

3. Keychain access is user-action only:
- `Check Keychain Status` button
- `Run Keychain Repair` button
- `Migrate Legacy Credentials` button
- `Reset All Credentials` button
- cloud inference execution after in-app explanation dialog
- explicit `Test ASR/LLM Connection` actions

## Notes
- Legacy migration is no longer automatic at startup.
- For cloud runs, app shows a local explanation dialog before any credential access.
- If credential presence hint is known missing, app routes user to settings first without Keychain read.
