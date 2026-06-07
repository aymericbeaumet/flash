#!/usr/bin/env python3
"""Tmux plugin — ports the former Swift TmuxProvider.

Subscribes to focus.changed to refresh the candidate snapshot (tmux
window finder). On each activation Flash calls discoverTargets with
the focused app's pid + window frame; the plugin returns pane-chip
and link-chip targets in screen coordinates.

Geometry mirrors the Swift implementation:
  - cell size = window / cells (fallback) OR alacritty-style font
    metrics when alacritty.toml exposes the font and PyObjC is
    available to read NSFont ascender/descender/advance.
  - pane chips: 1-cell rect at pane centre.
  - link chips: per-regex match in `capture-pane -p` output.
"""

import os
import re
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "_lib"))

# install.sh provisions PyObjC into $FLASH_PLUGIN_DATA_DIR/lib. Adding
# it to sys.path before the geometry helpers run lets `_cell_metrics_appkit`
# resolve NSFont metrics for Alacritty's hint geometry. Without this,
# the plugin falls back to `window / cells` and pane/link chips end
# up off-grid.
_data_dir = os.environ.get("FLASH_PLUGIN_DATA_DIR")
if _data_dir:
    _vendor_lib = os.path.join(_data_dir, "lib")
    if os.path.isdir(_vendor_lib) and _vendor_lib not in sys.path:
        sys.path.insert(0, _vendor_lib)

from flash_plugin import FlashPlugin  # noqa: E402

PLUGIN_ID = "tmux"
# Matches PluginFlashSource.identifier on the Swift side so candidate
# resolution can route back to the tmux plugin via SourceRegistry.
SOURCE_ID = f"plugin.{PLUGIN_ID}"

# Read-only locations probed for a pre-existing tmux binary. The plugin
# itself never installs tmux — users install it through their package
# manager — so these paths are inspected with os.path.isfile + os.access
# and never written to.
_TMUX_PREFIXES = ("/opt/homebrew", "/usr/local", "/opt/local", "/usr")
TMUX_CANDIDATES = tuple(prefix + "/bin/tmux" for prefix in _TMUX_PREFIXES)

# Match the entity classes the user asked for: URLs, absolute paths,
# home paths, relative paths, and bare filenames with an extension. The
# old port hand-rolled overlapping alternatives that exploded on dense
# pane contents (every dotted token became a hint).
#
# Token is bounded by whitespace, brackets, parentheses, quotes, and
# commas. Optional trailing `:LINE` / `:LINE:COL` survives the boundary
# so editor jump-to-line forms are kept intact.
_PATH_TAIL = r"(?::\d+(?::\d+)?)?"
_BOUNDARY = r"[^\s\"'`,\[\]\(\)<>]+"
LINK_PATTERN = re.compile(
    r"https?://" + _BOUNDARY + r"[A-Za-z0-9/_-]"  # http(s)://...
    + r"|~/" + _BOUNDARY + _PATH_TAIL  # ~/path/...
    + r"|/[A-Za-z0-9._-][^\s\"'`,\[\]\(\)<>]*" + _PATH_TAIL  # /abs/path
    + r"|\.{1,2}/" + _BOUNDARY + _PATH_TAIL  # ./rel or ../rel
    + r"|[\w.-]+\.[A-Za-z][\w-]*" + _PATH_TAIL  # file.ext / file.ext:LN
)
# Per-pane hint cap. A `man` page or scrollback can produce hundreds of
# matches; only the first N are surfaced so the overlay stays readable.
LINKS_PER_PANE_LIMIT = 40

ALACRITTY_BUNDLES = {"org.alacritty", "io.alacritty"}


def find_tmux():
    for path in TMUX_CANDIDATES:
        if os.path.isfile(path) and os.access(path, os.X_OK):
            return path
    return shutil.which("tmux")


def run_tmux(tmux_path, args, timeout=2.0):
    if not tmux_path:
        return None
    try:
        proc = subprocess.run(
            [tmux_path, *args],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout


def trimmed(value):
    if not value:
        return None
    stripped = value.strip()
    return stripped or None


def parent_pid_map():
    """One-shot snapshot of pid → ppid for the whole process table."""
    try:
        proc = subprocess.run(
            ["ps", "-axo", "pid=,ppid="],
            capture_output=True,
            text=True,
            timeout=1.5,
        )
    except (FileNotFoundError, subprocess.TimeoutExpired):
        return {}
    if proc.returncode != 0:
        return {}
    m = {}
    for line in proc.stdout.splitlines():
        parts = line.split()
        if len(parts) < 2:
            continue
        try:
            m[int(parts[0])] = int(parts[1])
        except ValueError:
            continue
    return m


def find_top_level_ancestor(pid, parent_map, max_hops=64):
    """Walk up from `pid` until the next parent is `launchd` (pid 1).
    Returns the highest-level pid before launchd — typically the
    terminal app hosting the tmux client. Returns nil when the chain
    is broken or exceeds the hop cap."""
    cur = pid
    for _ in range(max_hops):
        if cur <= 1:
            return None
        nxt = parent_map.get(cur)
        if nxt is None or nxt == cur:
            return None
        if nxt <= 1:
            return cur
        cur = nxt
    return None


def is_ancestor(ancestor_pid, descendant_pid, parent_map, max_hops=64):
    cur = descendant_pid
    for _ in range(max_hops):
        if cur <= 1:
            return False
        if cur == ancestor_pid:
            return True
        nxt = parent_map.get(cur)
        if nxt is None or nxt == cur:
            return False
        cur = nxt
    return False


def list_clients(tmux_path):
    raw = run_tmux(
        tmux_path,
        ["list-clients", "-F", "#{client_tty}\t#{session_name}\t#{client_pid}"],
    )
    if raw is None:
        return []
    out = []
    for line in raw.splitlines():
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        try:
            client_pid = int(parts[2])
        except ValueError:
            continue
        out.append({"tty": parts[0], "session": parts[1], "client_pid": client_pid})
    return out


def client_hosted_by(tmux_path, focused_pid):
    if focused_pid is None:
        return None
    clients = list_clients(tmux_path)
    if not clients:
        return None
    pmap = parent_pid_map()
    for client in clients:
        if is_ancestor(focused_pid, client["client_pid"], pmap):
            return client
    return None


def parse_two_ints(line):
    parts = line.strip().split()
    if len(parts) < 2:
        return None
    try:
        return int(parts[0]), int(parts[1])
    except ValueError:
        return None


def parse_status_info(line):
    parts = line.strip().split()
    if not parts:
        return 0, False, 0
    raw = parts[0]
    try:
        lines = int(raw)
    except ValueError:
        lines = 1 if raw == "on" else 0
    at_top = len(parts) >= 2 and parts[1] == "top"
    return lines, at_top, (lines if at_top else 0)


# ---- Alacritty font + cell geometry -----------------------------------------


def _read_toml_raw(text, section, key):
    in_section = False
    for raw_line in text.split("\n"):
        line = raw_line.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            inner = line[1:-1].strip()
            in_section = inner == section
            continue
        if not in_section:
            continue
        if "=" not in line:
            continue
        k, _, v = line.partition("=")
        if k.strip() == key:
            return v.strip()
    return None


def read_toml_string(text, section, key):
    raw = _read_toml_raw(text, section, key)
    if raw is None:
        return None
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = raw[1:-1]
    return raw or None


def read_toml_number(text, section, key):
    raw = _read_toml_raw(text, section, key)
    if raw is None:
        return None
    try:
        return float(raw)
    except ValueError:
        return None


def alacritty_font():
    for path in (
        os.path.expanduser("~/.config/alacritty/alacritty.toml"),
        os.path.expanduser("~/.alacritty.toml"),
    ):
        try:
            with open(path, "r", encoding="utf-8") as fh:
                text = fh.read()
        except OSError:
            continue
        size = read_toml_number(text, "font", "size") or 11.0
        family = read_toml_string(text, "font.normal", "family") or "Menlo"
        return family, size
    return None


def _cell_metrics_appkit(family, size):
    try:
        from AppKit import NSFont  # type: ignore
    except Exception:
        return None
    font = NSFont.fontWithName_size_(family, size) or NSFont.fontWithName_size_("Menlo", size)
    if font is None:
        try:
            font = NSFont.monospacedSystemFontOfSize_weight_(size, 0.0)
        except Exception:
            return None
    line_height = float(font.ascender()) - float(font.descender())
    try:
        advance = float(font.maximumAdvancement().width)
    except Exception:
        return None
    if advance <= 0 or line_height <= 0:
        return None
    return advance, line_height


def resolve_geometry(bundle_id, frame, cols, rows):
    win_w = frame["width"]
    win_h = frame["height"]
    if bundle_id in ALACRITTY_BUNDLES:
        font = alacritty_font()
        if font is not None:
            metrics = _cell_metrics_appkit(*font)
            if metrics is not None:
                cell_w, cell_h = metrics
                content_w = cols * cell_w
                content_h = rows * cell_h
                pad_x = max(0.0, (win_w - content_w) / 2)
                pad_y = max(0.0, (win_h - content_h) / 2)
                return cell_w, cell_h, pad_x, pad_y
    return win_w / cols, win_h / rows, 0.0, 0.0


# ---- Link extraction --------------------------------------------------------


def extract_links(line, max_cols):
    for match in LINK_PATTERN.finditer(line):
        col = match.start()
        if col >= max_cols:
            continue
        end_col = min(match.end(), max_cols)
        if end_col <= col:
            continue
        text = line[col:end_col]
        # Trim trailing punctuation that the regex tolerates inside a
        # match but isn't actually part of the link (`see foo.txt.`).
        text = text.rstrip(".,;:)]}>")
        if not text:
            continue
        yield col, text


# ---- Snapshots --------------------------------------------------------------


def build_target(target_id, x, y, width, height, role, label, pid):
    return {
        "id": target_id,
        "frame": {"x": x, "y": y, "width": width, "height": height},
        "role": role,
        "label": label,
        "accepts_text_input": True,
        "pid": int(pid),
        "source_id": SOURCE_ID,
    }


def discover_targets_for_context(tmux_path, params):
    if not tmux_path:
        return {"targets": []}
    pid = params.get("pid")
    bundle_id = params.get("bundle_id") or ""
    frame = params.get("front_window_frame") or {}
    if pid is None or frame.get("width", 0) <= 0 or frame.get("height", 0) <= 0:
        return {"targets": [], "context_pid": pid}
    client = client_hosted_by(tmux_path, pid)
    if client is None:
        return {"targets": [], "context_pid": pid}

    combined = run_tmux(
        tmux_path,
        [
            "display-message", "-c", client["tty"], "-p",
            "#{client_width} #{client_height}\n#{status} #{status-position}",
        ],
    )
    if combined is None:
        return {"targets": [], "context_pid": pid}
    combined_lines = combined.split("\n")
    if len(combined_lines) < 2:
        return {"targets": [], "context_pid": pid}
    parsed_dims = parse_two_ints(combined_lines[0])
    if parsed_dims is None:
        return {"targets": [], "context_pid": pid}
    client_cols, client_rows = parsed_dims
    if client_cols <= 0 or client_rows <= 0:
        return {"targets": [], "context_pid": pid}

    cell_w, cell_h, pad_x, pad_y = resolve_geometry(bundle_id, frame, client_cols, client_rows)

    pane_list = run_tmux(
        tmux_path,
        [
            "list-panes", "-t", client["tty"], "-F",
            "#{pane_id} #{pane_left} #{pane_top} #{pane_width} #{pane_height}",
        ],
    )
    if pane_list is None:
        return {"targets": [], "context_pid": pid}

    panes = []
    for line in pane_list.split("\n"):
        parts = line.split()
        if len(parts) != 5:
            continue
        try:
            panes.append({
                "id": parts[0],
                "left": int(parts[1]),
                "top": int(parts[2]),
                "cols": int(parts[3]),
                "rows": int(parts[4]),
            })
        except ValueError:
            continue
    if not panes:
        return {"targets": [], "context_pid": pid}

    _, _, top_offset = parse_status_info(combined_lines[1])
    min_x = frame["x"]
    min_y = frame["y"]
    win_h = frame["height"]

    # Pane chip is 3-cells wide so the hint label is readable. Anchored
    # at pane center, chip extends 1 cell left and right.
    pane_chip_cells = 3
    pane_targets = []
    raw_links = []
    for i, pane in enumerate(panes):
        center_col = pane["left"] + pane["cols"] // 2
        center_row = top_offset + pane["top"] + pane["rows"] // 2
        chip_x = min_x + pad_x + (center_col - pane_chip_cells // 2) * cell_w
        chip_y = min_y + win_h - pad_y - (center_row + 1) * cell_h
        pane_targets.append(build_target(
            f"tmux-{pid}-p{i}", chip_x, chip_y,
            pane_chip_cells * cell_w, cell_h,
            role="tmux-pane", label=pane["id"], pid=pid))

        raw = run_tmux(tmux_path, ["capture-pane", "-t", pane["id"], "-p"])
        if raw is None:
            continue
        lines = raw.split("\n")
        pane_links_seen = 0
        for row_idx, content in enumerate(lines):
            if row_idx >= pane["rows"]:
                break
            if pane_links_seen >= LINKS_PER_PANE_LIMIT:
                break
            for col, text in extract_links(content, pane["cols"]):
                if pane_links_seen >= LINKS_PER_PANE_LIMIT:
                    break
                screen_col = pane["left"] + col
                screen_row = top_offset + pane["top"] + row_idx
                raw_links.append({
                    "screen_row": screen_row,
                    "screen_col": screen_col,
                    "text": text,
                    "pane_index": i,
                })
                pane_links_seen += 1

    # Pane chips emit first so HintAssigner allocates the shortest
    # labels to them — that's the "best" hint per the user's spec.
    # Link chips then sort across all panes by screen position
    # (top-to-bottom, left-to-right) so the labelling reads as the
    # natural eye-scan order.
    raw_links.sort(key=lambda link: (link["screen_row"], link["screen_col"]))
    targets = list(pane_targets)
    for idx, link in enumerate(raw_links):
        x = min_x + pad_x + link["screen_col"] * cell_w
        y = min_y + win_h - pad_y - (link["screen_row"] + 1) * cell_h
        targets.append(build_target(
            f"tmux-{pid}-l{idx}",
            x, y, len(link["text"]) * cell_w, cell_h,
            role="tmux-link", label=link["text"], pid=pid))

    return {"targets": targets, "context_pid": int(pid)}


# ---- Candidate (tmux window finder) -----------------------------------------


def build_candidates(tmux_path):
    if not tmux_path:
        return []
    clients = list_clients(tmux_path)
    client_by_session = {}
    for client in clients:
        client_by_session.setdefault(client["session"], client)
    # Resolve each client's hosting terminal app pid by walking the
    # parent chain up to launchd. Cached for the snapshot so we walk
    # once per refresh, not once per window.
    pmap = parent_pid_map() if clients else {}
    terminal_pid_by_session = {}
    for session, client in client_by_session.items():
        if client and client.get("client_pid"):
            terminal_pid_by_session[session] = find_top_level_ancestor(
                client["client_pid"], pmap)

    raw = run_tmux(
        tmux_path,
        [
            "list-windows", "-a", "-F",
            "#{session_name}\t#{window_index}\t#{window_name}",
        ],
    )
    if raw is None:
        return []
    out = []
    for line in raw.split("\n"):
        if not line:
            continue
        parts = line.split("\t", 2)
        if len(parts) != 3:
            continue
        session, index, name = parts
        name = name.strip()
        client = client_by_session.get(session) or (clients[0] if clients else None)
        terminal_pid = terminal_pid_by_session.get(session)
        title = f"{session}:{index} {name}" if name else f"{session}:{index}"
        subtitle = f"tmux {session} {name}" if name else f"tmux {session}"
        target = f"{session}:{index}"
        candidate = {
            "kind": "tmux_window",
            "source_id": SOURCE_ID,
            "source": PLUGIN_ID,
            "name": title,
            "subtitle": subtitle,
            "payload": {
                "tmux_target": target,
                "tmux_client_tty": client["tty"] if client else "",
                "client_pid": client["client_pid"] if client else None,
                "terminal_pid": terminal_pid,
            },
        }
        if terminal_pid is not None:
            candidate["pid"] = int(terminal_pid)
        out.append(candidate)
    return out


# ---- Tab actions ------------------------------------------------------------


def tmux_window_indices(raw):
    return [line.strip() for line in raw.split("\n") if line.strip()]


def target_for_ordinal(ordinal, session, indices):
    if ordinal <= 0 or ordinal > len(indices):
        return None
    return f"{session}:{indices[ordinal - 1]}"


def target_for_adjacent(direction, session, current_index, indices):
    if not indices or current_index not in indices:
        return None
    offset = indices.index(current_index)
    if direction == "next":
        offset = (offset + 1) % len(indices)
    else:
        offset = (offset - 1 + len(indices)) % len(indices)
    return f"{session}:{indices[offset]}"


def switch_client(tmux_path, tty, target):
    return run_tmux(tmux_path, ["switch-client", "-c", tty, "-t", target]) is not None


def tab_select(tmux_path, client, args):
    idx = args.get("index")
    if not isinstance(idx, int) or idx <= 0:
        return False
    raw = run_tmux(
        tmux_path,
        ["list-windows", "-t", client["session"], "-F", "#{window_index}"],
    )
    if raw is None:
        return False
    target = target_for_ordinal(idx, client["session"], tmux_window_indices(raw))
    if target is None:
        return False
    return switch_client(tmux_path, client["tty"], target)


def tab_adjacent(tmux_path, client, direction):
    current = trimmed(run_tmux(
        tmux_path,
        ["display-message", "-c", client["tty"], "-p", "#{window_index}"],
    ))
    raw = run_tmux(
        tmux_path,
        ["list-windows", "-t", client["session"], "-F", "#{window_index}"],
    )
    if current is None or raw is None:
        return False
    target = target_for_adjacent(direction, client["session"], current, tmux_window_indices(raw))
    if target is None:
        return False
    return switch_client(tmux_path, client["tty"], target)


def tab_new(tmux_path, client):
    current_path = trimmed(run_tmux(
        tmux_path,
        ["display-message", "-c", client["tty"], "-p", "#{pane_current_path}"],
    ))
    args = ["new-window", "-P", "-F", "#{window_index}", "-t", client["session"]]
    if current_path:
        args.extend(["-c", current_path])
    created = trimmed(run_tmux(tmux_path, args))
    if not created:
        return False
    return switch_client(tmux_path, client["tty"], f"{client['session']}:{created}")


def tab_close(tmux_path, client):
    current = trimmed(run_tmux(
        tmux_path,
        ["display-message", "-c", client["tty"], "-p", "#{window_index}"],
    ))
    if not current:
        return False
    return run_tmux(
        tmux_path,
        ["kill-window", "-t", f"{client['session']}:{current}"],
    ) is not None


def perform_source_action(tmux_path, name, params):
    context = params.get("context") or {}
    pid = context.get("pid")
    if pid is None:
        return {"did_perform": False}
    client = client_hosted_by(tmux_path, int(pid))
    if client is None:
        return {"did_perform": False}
    if name == "tab_select":
        ok = tab_select(tmux_path, client, params)
    elif name == "tab_next":
        ok = tab_adjacent(tmux_path, client, "next")
    elif name == "tab_prev":
        ok = tab_adjacent(tmux_path, client, "previous")
    elif name == "tab_new":
        ok = tab_new(tmux_path, client)
    elif name == "tab_close":
        ok = tab_close(tmux_path, client)
    else:
        return {"did_perform": False}
    return {"did_perform": bool(ok), "target_pid": int(pid)}


def resolve_candidate(tmux_path, candidate):
    raw_payload = candidate.get("payload")
    payload = {}
    if isinstance(raw_payload, str):
        try:
            import json
            payload = json.loads(raw_payload)
        except Exception:
            payload = {}
    elif isinstance(raw_payload, dict):
        payload = raw_payload
    target = payload.get("tmux_target")
    tty = payload.get("tmux_client_tty") or ""
    if not target:
        return {"did_resolve": False}
    args = ["switch-client"]
    if tty:
        args.extend(["-c", tty])
    args.extend(["-t", target])
    ok = run_tmux(tmux_path, args) is not None
    return {"did_resolve": bool(ok)}


# ---- Plugin glue ------------------------------------------------------------


def refresh_candidate_snapshot(plugin, tmux_path):
    candidates = build_candidates(tmux_path)
    plugin.emit_snapshot(candidates=candidates, source_id=SOURCE_ID)


def main():
    tmux_path = find_tmux()
    plugin = FlashPlugin(PLUGIN_ID)
    if not tmux_path:
        plugin.log("warn", "[tmux] tmux binary not found")

    def on_event(_plugin, name, _payload):
        if name in ("focus.changed", "flash.started", "apps.terminated"):
            refresh_candidate_snapshot(plugin, tmux_path)

    def on_discover(_plugin, params):
        return discover_targets_for_context(tmux_path, params)

    def on_source_action(_plugin, name, params):
        return perform_source_action(tmux_path, name, params)

    def on_resolve(_plugin, candidate):
        return resolve_candidate(tmux_path, candidate)

    plugin.on_event = on_event
    plugin.on_discover_targets = on_discover
    plugin.on_source_action = on_source_action
    plugin.on_resolve_candidate = on_resolve
    refresh_candidate_snapshot(plugin, tmux_path)
    plugin.serve()


if __name__ == "__main__":
    main()
