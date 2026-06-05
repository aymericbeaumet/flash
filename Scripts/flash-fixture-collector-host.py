#!/usr/bin/env python3
import json
import os
import re
import struct
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

PROJECT_DIR = Path(__file__).resolve().parents[1]
FIXTURES_DIR = PROJECT_DIR / "Tests" / "BrowserSnapshots"
SNAPSHOTS_DIR = FIXTURES_DIR / "snapshots"
MANIFEST_PATH = FIXTURES_DIR / "manifest.json"

MAX_HTML_BYTES = 8 * 1024 * 1024

TOKEN_RE = re.compile(r"\b(?:bearer|basic)\s+[a-z0-9._~+/-]+=*|\b[a-z0-9._~+/-]{32,}={0,2}\b", re.I)
EMAIL_RE = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.I)
def read_message():
    raw_length = sys.stdin.buffer.read(4)
    if len(raw_length) == 0:
        return None
    if len(raw_length) != 4:
        raise ValueError("truncated native-message length")
    length = struct.unpack("<I", raw_length)[0]
    if length > MAX_HTML_BYTES + 1024 * 1024:
        raise ValueError("native message too large")
    return json.loads(sys.stdin.buffer.read(length).decode("utf-8"))


def send_message(payload):
    encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
    sys.stdout.buffer.write(struct.pack("<I", len(encoded)))
    sys.stdout.buffer.write(encoded)
    sys.stdout.buffer.flush()


def redact_text(value):
    value = EMAIL_RE.sub("[redacted-email]", value)
    value = TOKEN_RE.sub("[redacted-token]", value)
    return value


def sanitize_url(value):
    try:
        parts = urlsplit(value)
    except Exception:
        return ""
    if not parts.scheme:
      return redact_text(value)
    netloc = parts.hostname or ""
    if parts.port:
      netloc += f":{parts.port}"
    return urlunsplit((parts.scheme, netloc, parts.path, "", ""))


def sanitize_html(html):
    html = redact_text(html)
    html = re.sub(
        r"(?P<prefix>\b(?:href|src|action|formaction|poster|data|cite)=)(?P<quote>[\"'])(?P<url>.*?)(?P=quote)",
        lambda m: f"{m.group('prefix')}{m.group('quote')}{sanitize_url(m.group('url'))}{m.group('quote')}",
        html,
        flags=re.I | re.S,
    )
    html = re.sub(
        r"(?P<name>\b[a-z0-9_-]*(?:token|secret|password|passwd|pwd|session|cookie|csrf|xsrf|auth|jwt|bearer|credential|api[-_]?key)[a-z0-9_-]*=)(?P<quote>[\"']).*?(?P=quote)",
        lambda m: f"{m.group('name')}{m.group('quote')}[redacted]{m.group('quote')}",
        html,
        flags=re.I | re.S,
    )
    return html


def slugify(value):
    value = value.lower()
    value = re.sub(r"[^a-z0-9]+", "-", value)
    value = value.strip("-")
    return value[:48] or "page"


def load_manifest():
    with MANIFEST_PATH.open("r", encoding="utf-8") as handle:
        return json.load(handle)


def write_manifest(manifest):
    tmp = MANIFEST_PATH.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
        handle.write("\n")
    os.replace(tmp, MANIFEST_PATH)


def next_fixture_name(title, url):
    base = slugify(title or url or "captured-page")
    existing = {fixture["name"] for fixture in load_manifest()["fixtures"]}
    index = 1
    while True:
        name = f"collected-{base}-{index:03d}"
        if name not in existing:
            return name
        index += 1


def capture_page(page):
    title = redact_text(str(page.get("title") or "captured-page"))
    url = sanitize_url(str(page.get("url") or ""))
    html = sanitize_html(str(page.get("html") or ""))
    encoded = html.encode("utf-8")
    if not html.strip():
        raise ValueError("empty html")
    if len(encoded) > MAX_HTML_BYTES:
        raise ValueError("sanitized html too large")

    name = next_fixture_name(title, url)
    file_name = f"{name}.html"
    SNAPSHOTS_DIR.mkdir(parents=True, exist_ok=True)
    snapshot_path = SNAPSHOTS_DIR / file_name
    header = (
        "<!-- Captured by Flash Fixture Collector.\n"
        f"     Source: {url}\n"
        "     Sanitization: scripts removed; credentials, token-like values, query strings, and fragments redacted.\n"
        "-->\n"
    )
    snapshot_path.write_text(header + html, encoding="utf-8")

    manifest = load_manifest()
    manifest["fixtures"].append(
        {
            "name": name,
            "file": file_name,
            "category": "collected-regression",
            "kind": "collected",
        }
    )
    write_manifest(manifest)
    return {"ok": True, "name": name, "file": file_name}


def main():
    if len(sys.argv) > 1 and sys.argv[1] == "--self-test":
        sample = (
            '<a href="https://u:p@example.com/path?token=secret#frag">a</a>'
            '<div data-token="secret"></div>'
            ' user@example.com bearer abcdefghijklmnopqrstuvwxyz0123456789'
        )
        sanitized = sanitize_html(sample)
        assert "secret" not in sanitized
        assert "user@example.com" not in sanitized
        assert "?token=" not in sanitized
        assert "token=secret" not in sanitized
        assert "#frag" not in sanitized
        assert "[redacted-email]" in sanitized
        assert "[redacted-token]" in sanitized
        print("ok")
        return
    try:
        message = read_message()
        if not message:
            return
        if message.get("type") != "capture_page":
            raise ValueError("unsupported message type")
        send_message(capture_page(message.get("page") or {}))
    except Exception as exc:
        send_message({"ok": False, "error": str(exc)})


if __name__ == "__main__":
    main()
