#!/usr/bin/env python3
"""Python port of the bundled aiproviders plugin (Plugins/aiproviders).

Opens AI chat providers from the flashlight: `!chatgpt <query>` etc. The
optional query is pre-filled into the new chat via the provider's `q` URL
parameter, and a Return keystroke is synthesized after a load delay so the
prompt actually sends — behavior identical to the Rust original.
"""
import subprocess
import time
import urllib.parse

from flashplugin import Plugin

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


def on_command(params):
    # Manifest tokens are py-prefixed (!pyclaude) so this example can
    # coexist with the bundled Rust plugin's bangs.
    bang = params.get("subcommand", "").lower().removeprefix("py")
    provider = PROVIDERS.get(bang)
    if provider is None:
        return {"ok": False, "error": f"unknown ai provider: !{bang}"}
    base, query_param = provider
    query = " ".join(params.get("args", [])).strip()
    url = (
        f"{base}?{query_param}={urllib.parse.quote(query)}"
        if query
        else base
    )
    opened = subprocess.run(
        ["/usr/bin/open", url], capture_output=True, timeout=10
    )
    if opened.returncode != 0:
        return {
            "ok": False,
            "error": opened.stderr.decode("utf-8", "replace").strip() or "open failed",
        }
    if query:
        # Best-effort auto-send: wait for the page's composer to take focus,
        # then synthesize Return. Same tradeoff as the Rust original.
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
    Plugin().serve(on_command)
