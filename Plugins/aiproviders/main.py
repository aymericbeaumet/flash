#!/usr/bin/env python3
"""AI provider bangs, in Python (one of the six deliberately non-Rust
official plugins exercising the language-agnostic wire protocol; see
docs/plugin-protocol.md and AGENTS.md — Rust stays the default).

Opens AI chat providers from the flashlight: `!chatgpt <query>` etc. The
optional query is pre-filled via the provider's `q` URL parameter, and a
Return keystroke is synthesized after a load delay so the prompt actually
sends. Best-effort — if focus lands elsewhere the keystroke goes there,
the same tradeoff the Rust implementation made.
"""
import subprocess
import sys
import time
import urllib.parse

sys.dont_write_bytecode = True  # never litter the (signed) bundle with .pyc
from flashplugin import Plugin  # resolved via host-injected PYTHONPATH

# (base_url, prefill_query_param) keyed by bang token.
PROVIDERS = {
    "chatgpt": ("https://chatgpt.com/", "q"),
    "claude": ("https://claude.ai/new", "q"),
    "copilot": ("https://copilot.microsoft.com/", "q"),
    "gemini": ("https://gemini.google.com/app", "q"),
    "grok": ("https://grok.com/", "q"),
    "perplexity": ("https://www.perplexity.ai/search", "q"),
}

AUTOSEND_DELAY_SECONDS = 2.5


plugin = Plugin()


def on_command(params):
    bang = params.get("subcommand", "").lower()
    provider = PROVIDERS.get(bang)
    if provider is None:
        return {"ok": False, "error": f"unknown ai provider: !{bang}"}
    base, query_param = provider
    query = " ".join(params.get("args", [])).strip()
    url = f"{base}?{query_param}={urllib.parse.quote(query)}" if query else base
    # Fork-free: the host opens the URL (`host.open`).
    opened = plugin.call_host("host.open", {"url": url})
    if not opened.get("ok"):
        return {"ok": False, "error": opened.get("error") or "host.open failed"}
    if query:
        # Wait for the page's composer to take focus, then synthesize Return.
        time.sleep(AUTOSEND_DELAY_SECONDS)
        subprocess.run(
            [
                "/usr/bin/osascript",
                "-e",
                'tell application "System Events" to key code 36',
            ],
            capture_output=True,
            timeout=10,
        )
    return {"ok": True}


if __name__ == "__main__":
    plugin.serve(on_command)
