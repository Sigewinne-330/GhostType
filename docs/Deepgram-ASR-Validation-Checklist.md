# Deepgram ASR Validation Checklist

## Scope
This checklist verifies the Deepgram settings upgrade in GhostType against the acceptance criteria in the PRD.

## Environment
- macOS app built from current source.
- ASR engine set to `Cloud Deepgram API`.
- A valid Deepgram API key saved in Keychain.

## Acceptance Criteria Mapping

### 1) `zh-CN` auto-recommends `nova-2`
Steps:
1. Open `Settings -> Engines & Models`.
2. Select `ASR Engine = Cloud Deepgram API`.
3. Set `Language Strategy = Single Language: Chinese (Simplified)`.

Expected:
- Recommendation text says Chinese should use `nova-2`.
- Model picker defaults to `nova-2` (or warns if user forces incompatible model).

### 2) `en-US` auto-recommends `nova-3`
Steps:
1. In the same screen, set `Language Strategy = Single Language: English (US)`.

Expected:
- Recommendation text says English should use `nova-3`.
- Model picker defaults to `nova-3`.

### 3) Streaming mode preview uses `wss://.../v1/listen`
Steps:
1. Set `Transcription Mode = Streaming (WebSocket)`.
2. Observe `Endpoint Preview`.

Expected:
- URL starts with `wss://`.
- Path includes `/v1/listen`.

### 4) `smart_format=true` disables punctuation toggle semantics
Steps:
1. Enable `smart_format`.
2. Check `punctuate` control.

Expected:
- `punctuate` is disabled in UI.
- Helper text explains punctuation is already covered by `smart_format`.

### 5) `nova-2` shows and sends `keywords`
Steps:
1. Select model `nova-2`.
2. Enter sample terms in keywords field, e.g. `GhostType:2,MLX`.
3. Switch to `Batch` mode and inspect endpoint preview query.

Expected:
- UI shows `keywords` input (not `keyterm`).
- Preview query contains repeated `keywords=` entries.

### 6) `nova-3` shows and sends `keyterm`
Steps:
1. Select model `nova-3`.
2. Enter sample terms in keyterm field, e.g. `GhostType,Dictation`.
3. Inspect endpoint preview query.

Expected:
- UI shows `keyterm` input (not `keywords`).
- Preview query contains repeated `keyterm=` entries.

### 7) Test ASR Connection handles both Batch and Streaming
Steps:
1. Set mode to `Batch`, click `Test ASR Connection`.
2. Set mode to `Streaming`, click `Test ASR Connection`.

Expected:
- Batch test executes `/v1/listen` over HTTPS and reports success/failure details.
- Streaming test executes `/v1/listen` over WSS and reports handshake/message outcome.
- API key is never printed in logs.

### 8) Host-only Base URL is normalized to `/v1/listen`
Steps:
1. In `ASR Base URL`, enter `api.deepgram.com` (no scheme).
2. Observe endpoint preview.

Expected:
- Batch preview normalizes to `https://api.deepgram.com/v1/listen?...`.
- Streaming preview normalizes to `wss://api.deepgram.com/v1/listen?...`.

## Preset Regression

### Preset A: Chinese Dictation (Stable)
Steps:
1. Click `Preset: Chinese Dictation`.

Expected:
- model=`nova-2`
- language=`zh-CN`
- smart_format=`true`
- endpointing enabled with `500`
- interim_results enabled (effective when Streaming)

### Preset B: English Meeting (High Quality)
Steps:
1. Click `Preset: English Meeting`.

Expected:
- model=`nova-3`
- language=`en-US`
- smart_format=`true`
- endpointing enabled with `500`
- diarize=`true`

## Security Regression
- API key save/remove works through Keychain only.
- Connection testing and status text must not leak API keys.

## Known Local Limitation
- In this environment, `xcodebuild test` may fail at LaunchServices test-runner launch stage (`IDELaunchErrorDomain Code=20`) even when compile and test-build succeed. Use `xcodebuild build` and `xcodebuild build-for-testing` as compile gates if the test runner cannot launch.
