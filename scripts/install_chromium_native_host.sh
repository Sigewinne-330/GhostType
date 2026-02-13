#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'USAGE'
Install GhostType Chromium native messaging host manifest.

Usage:
  bash scripts/install_chromium_native_host.sh --browser <chrome|edge|arc> [--extension-id <id>] [--host-path <path>]
                                           [--extension-manifest <path>]

Examples:
  bash scripts/install_chromium_native_host.sh --browser chrome
  bash scripts/install_chromium_native_host.sh --browser edge --extension-id abcdefghijklmnopabcdefghijklmnop
USAGE
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

BROWSER=""
EXTENSION_ID=""
HOST_PATH="${ROOT_DIR}/scripts/chromium_native_host.py"
TEMPLATE_PATH="${ROOT_DIR}/scripts/chromium_native_host_manifest.template.json"
EXTENSION_MANIFEST_PATH="${ROOT_DIR}/browser/chromium_context_bridge/manifest.json"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --browser)
      BROWSER="${2:-}"
      shift 2
      ;;
    --extension-id)
      EXTENSION_ID="${2:-}"
      shift 2
      ;;
    --host-path)
      HOST_PATH="${2:-}"
      shift 2
      ;;
    --extension-manifest)
      EXTENSION_MANIFEST_PATH="${2:-}"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

if [[ -z "${BROWSER}" ]]; then
  echo "Missing required arguments." >&2
  usage
  exit 1
fi

if [[ -z "${EXTENSION_ID}" ]]; then
  if [[ ! -f "${EXTENSION_MANIFEST_PATH}" ]]; then
    echo "Extension manifest not found and --extension-id not provided: ${EXTENSION_MANIFEST_PATH}" >&2
    exit 1
  fi

  EXTENSION_ID="$(python3 - "${EXTENSION_MANIFEST_PATH}" <<'PY'
import base64
import hashlib
import json
import pathlib
import sys

manifest_path = pathlib.Path(sys.argv[1]).expanduser()
manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
key_b64 = (manifest.get("key") or "").strip()
if not key_b64:
    raise SystemExit("")
raw = base64.b64decode(key_b64)
digest = hashlib.sha256(raw).hexdigest()[:32]
alphabet = "abcdefghijklmnop"
extension_id = "".join(alphabet[int(ch, 16)] for ch in digest)
print(extension_id)
PY
)"

  if [[ -z "${EXTENSION_ID}" ]]; then
    echo "Unable to derive extension id from manifest key. Provide --extension-id explicitly." >&2
    exit 1
  fi
fi

case "${BROWSER}" in
  chrome)
    MANIFEST_DIR="${HOME}/Library/Application Support/Google/Chrome/NativeMessagingHosts"
    ;;
  edge)
    MANIFEST_DIR="${HOME}/Library/Application Support/Microsoft Edge/NativeMessagingHosts"
    ;;
  arc)
    MANIFEST_DIR="${HOME}/Library/Application Support/Arc/NativeMessagingHosts"
    ;;
  *)
    echo "Unsupported browser: ${BROWSER}" >&2
    usage
    exit 1
    ;;
esac

if [[ ! -f "${HOST_PATH}" ]]; then
  echo "Host script not found: ${HOST_PATH}" >&2
  exit 1
fi

if [[ ! -f "${TEMPLATE_PATH}" ]]; then
  echo "Template not found: ${TEMPLATE_PATH}" >&2
  exit 1
fi

mkdir -p "${MANIFEST_DIR}"
MANIFEST_PATH="${MANIFEST_DIR}/com.codeandchill.ghosttype.context.json"

python3 - "${TEMPLATE_PATH}" "${MANIFEST_PATH}" "${HOST_PATH}" "${EXTENSION_ID}" <<'PY'
import json
import pathlib
import sys

template_path = pathlib.Path(sys.argv[1])
output_path = pathlib.Path(sys.argv[2])
host_path = pathlib.Path(sys.argv[3]).expanduser().resolve()
extension_id = sys.argv[4].strip()

template = json.loads(template_path.read_text(encoding="utf-8"))
template["path"] = str(host_path)
template["allowed_origins"] = [f"chrome-extension://{extension_id}/"]
output_path.write_text(json.dumps(template, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY

chmod +x "${HOST_PATH}"

echo "Installed native host manifest: ${MANIFEST_PATH}"
echo "Host script: ${HOST_PATH}"
echo "Browser: ${BROWSER}"
echo "Extension ID: ${EXTENSION_ID}"
echo "Done. Restart ${BROWSER} and verify by changing tabs, then check:"
echo "  ~/Library/Application Support/GhostType/browser-context-hint.json"
