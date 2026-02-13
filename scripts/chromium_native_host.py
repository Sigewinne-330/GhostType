#!/usr/bin/env python3
"""Chromium Native Messaging host for GhostType context routing.

Reads active-tab context from browser extensions and writes a small
JSON hint into GhostType's app-support inbox file:
~/Library/Application Support/GhostType/browser-context-hint.json
"""

from __future__ import annotations

import datetime as _dt
import json
import os
import pathlib
import struct
import sys
import urllib.parse
from typing import Any


HOST_NAME = "com.codeandchill.ghosttype.context"
APP_SUPPORT_DIR = pathlib.Path.home() / "Library" / "Application Support" / "GhostType"
INBOX_FILE = APP_SUPPORT_DIR / "browser-context-hint.json"

DEFAULT_BUNDLE_BY_BROWSER = {
    "chrome": "com.google.Chrome",
    "edge": "com.microsoft.edgemac",
    "arc": "company.thebrowser.Browser",
    "safari": "com.apple.Safari",
}


def _read_message() -> dict[str, Any] | None:
    raw_length = sys.stdin.buffer.read(4)
    if not raw_length:
        return None
    if len(raw_length) != 4:
        return None
    msg_length = struct.unpack("<I", raw_length)[0]
    raw_payload = sys.stdin.buffer.read(msg_length)
    if len(raw_payload) != msg_length:
        return None
    try:
        payload = json.loads(raw_payload.decode("utf-8"))
    except Exception:
        return None
    if not isinstance(payload, dict):
        return None
    return payload


def _send_message(message: dict[str, Any]) -> None:
    data = json.dumps(message, ensure_ascii=False).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(data)))
    sys.stdout.buffer.write(data)
    sys.stdout.buffer.flush()


def _extract_domain(value: str) -> str | None:
    candidate = value.strip()
    if not candidate:
        return None
    parsed = urllib.parse.urlparse(candidate)
    host = (parsed.hostname or "").strip().lower()
    if host:
        return host
    if "://" not in candidate:
        parsed = urllib.parse.urlparse(f"https://{candidate}")
        host = (parsed.hostname or "").strip().lower()
        if host:
            return host
    return None


def _normalize_payload(message: dict[str, Any]) -> tuple[str, str] | tuple[None, None]:
    domain = None
    if isinstance(message.get("domain"), str):
        domain = _extract_domain(message["domain"])
    if domain is None and isinstance(message.get("active_domain"), str):
        domain = _extract_domain(message["active_domain"])
    if domain is None and isinstance(message.get("url"), str):
        domain = _extract_domain(message["url"])
    if domain is None and isinstance(message.get("active_url"), str):
        domain = _extract_domain(message["active_url"])
    if domain is None:
        return None, None

    bundle_id = ""
    for key in ("bundleId", "bundle_id"):
        value = message.get(key)
        if isinstance(value, str) and value.strip():
            bundle_id = value.strip()
            break

    if not bundle_id:
        browser = message.get("browser")
        if isinstance(browser, str):
            bundle_id = DEFAULT_BUNDLE_BY_BROWSER.get(browser.strip().lower(), "")

    if not bundle_id:
        bundle_id = DEFAULT_BUNDLE_BY_BROWSER["chrome"]

    return bundle_id, domain


def _write_inbox(bundle_id: str, domain: str) -> None:
    APP_SUPPORT_DIR.mkdir(parents=True, exist_ok=True)
    payload = {
        "bundleId": bundle_id,
        "activeDomain": domain,
        "source": "extension",
        "updatedAt": _dt.datetime.now(tz=_dt.timezone.utc).isoformat(),
    }
    temp_file = INBOX_FILE.with_suffix(".tmp")
    temp_file.write_text(json.dumps(payload, ensure_ascii=False), encoding="utf-8")
    os.replace(temp_file, INBOX_FILE)


def main() -> int:
    while True:
        message = _read_message()
        if message is None:
            return 0

        bundle_id, domain = _normalize_payload(message)
        if not bundle_id or not domain:
            _send_message({"ok": False, "error": "Missing usable domain in message."})
            continue

        try:
            _write_inbox(bundle_id=bundle_id, domain=domain)
        except Exception as exc:  # pragma: no cover - host resilience path
            _send_message({"ok": False, "error": str(exc)})
            continue

        _send_message(
            {
                "ok": True,
                "host": HOST_NAME,
                "bundleId": bundle_id,
                "activeDomain": domain,
            }
        )


if __name__ == "__main__":
    raise SystemExit(main())
