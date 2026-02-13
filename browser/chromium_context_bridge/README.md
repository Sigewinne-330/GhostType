# GhostType Chromium Context Bridge (PoC)

This extension pushes the active tab domain to GhostType through Chromium Native Messaging.
It auto-detects Chrome / Edge / Arc and sends the matching macOS bundle id.

## What It Does
- Watches active tab changes.
- Extracts `domain` from tab URL.
- Sends payload to native host `com.codeandchill.ghosttype.context`.
- GhostType reads the inbox file and uses it for context routing.

Payload example:

```json
{
  "type": "active_tab",
  "browser": "chrome",
  "bundleId": "com.google.Chrome",
  "url": "https://chat.openai.com/c/abc",
  "domain": "chat.openai.com"
}
```

## Install Steps (Chrome)
1. Open `chrome://extensions`.
2. Enable `Developer mode`.
3. Click `Load unpacked` and select this folder (`browser/chromium_context_bridge`).
4. Install native host manifest (extension ID auto-derived from `manifest.json` key):

```bash
bash scripts/install_chromium_native_host.sh --browser chrome
```

6. Restart Chrome.
7. Click the extension icon once (or switch tabs) and start a Dictation in GhostType.

## Edge / Arc
Use the same extension package and install manifest with browser flag:

```bash
bash scripts/install_chromium_native_host.sh --browser edge
bash scripts/install_chromium_native_host.sh --browser arc
```

If you use a different unpacked package without the bundled `key`, pass extension id manually:

```bash
bash scripts/install_chromium_native_host.sh --browser chrome --extension-id <YOUR_EXTENSION_ID>
```

## Verification
Check inbox updates:

```bash
cat ~/Library/Application\ Support/GhostType/browser-context-hint.json
```

Expected fields:
- `bundleId`
- `activeDomain`
- `source = "extension"`
