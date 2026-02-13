# Browser Context Native Messaging (MVP)

This project supports browser context ingestion through a shared inbox file:

`~/Library/Application Support/GhostType/browser-context-hint.json`

GhostType reads this file at dictation start / context snapshot time and uses it for domain-based routing.

## 1. Native Host Script

Host script path in this repo:

`scripts/chromium_native_host.py`

It implements Chromium Native Messaging protocol (`stdin/stdout`) and writes:

```json
{
  "bundleId": "com.google.Chrome",
  "activeDomain": "chat.openai.com",
  "source": "extension",
  "updatedAt": "2026-02-12T14:33:00Z"
}
```

The host intentionally stores only domain by default.

## 2. Install Manifest (Chrome / Edge / Arc)

Template:

`scripts/chromium_native_host_manifest.template.json`

1. Replace `__HOST_PATH__` with absolute script path.
2. Replace `__EXTENSION_ID__` with your extension id.
3. Save per browser:

- Chrome:
  `~/Library/Application Support/Google/Chrome/NativeMessagingHosts/com.codeandchill.ghosttype.context.json`
- Edge:
  `~/Library/Application Support/Microsoft Edge/NativeMessagingHosts/com.codeandchill.ghosttype.context.json`
- Arc (Chromium):
  `~/Library/Application Support/Arc/NativeMessagingHosts/com.codeandchill.ghosttype.context.json`

## 3. Extension Message Shape

Send one JSON message like:

```json
{
  "type": "active_tab",
  "browser": "chrome",
  "bundleId": "com.google.Chrome",
  "url": "https://chat.openai.com/c/xxx"
}
```

`url` can be replaced with `domain` / `active_domain`.

## 4. Safari App Extension Path

Safari can reuse the same inbox schema:

1. Get active tab URL inside extension.
2. Derive domain.
3. Write the same `browser-context-hint.json` payload (or send through app message bridge and let host app write it).

GhostType already supports fallback chain:

1. External channel hint (extension / native messaging inbox)
2. AppleScript URL read (MVP fallback)
3. Window title inference
4. App-only routing
