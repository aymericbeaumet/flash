"""Spec and plugin enumeration + requires-gating + overrides.

Everything is discovered by glob — a new plugin or spec file is covered by
construction, never by editing a hand list. The single escape hatch is
Plugins/_flash_plugin_specs/overrides.json:

  {
    "reminders": {"skip": ["sources/*"], "reason": "needs a TCC grant CI lacks"},
    "probe:ruby": {"xfail": ["probe/queries/*"], "reason": "parity pending (#N)"}
  }

skip = not run (counted, annotated). xfail = run, failure expected and green;
an xfail that PASSES fails the run so stale entries must be deleted.
"""
import fnmatch
import json
import pathlib

from .schema import SpecError, validate

SCRIPTS_DIR = pathlib.Path(__file__).resolve().parent.parent
PROJECT_DIR = SCRIPTS_DIR.parent
PLUGINS_DIR = PROJECT_DIR / "Plugins"
SPECS_DIR = PLUGINS_DIR / "_flash_plugin_specs"

RESERVED_FILES = {"schema.json", "overrides.json"}


def load_spec(path, specs_root):
    try:
        spec = json.loads(path.read_text())
    except (OSError, ValueError) as error:
        raise SpecError(f"{path}: unreadable spec: {error}")
    rel = path.relative_to(specs_root).with_suffix("")
    spec.setdefault("name", str(rel))
    validate(spec, spec["name"])
    return spec


def shared_specs():
    """All shared scenario files, sorted; (spec, is_probe_only) pairs."""
    out = []
    for path in sorted(SPECS_DIR.rglob("*.json")):
        rel = path.relative_to(SPECS_DIR)
        if rel.name in RESERVED_FILES or rel.parts[0] == "probes":
            continue
        probe_only = rel.parts[0] == "probe"
        out.append((load_spec(path, SPECS_DIR), probe_only))
    return out


def plugin_specs(plugin_dir):
    """Per-plugin local specs at Plugins/<id>/specs/*.json."""
    local = plugin_dir / "specs"
    if not local.is_dir():
        return []
    return [load_spec(path, local.parent) for path in sorted(local.glob("*.json"))]


def plugin_dirs():
    return sorted(
        path.parent
        for path in PLUGINS_DIR.glob("*/manifest.json")
        if not path.parent.name.startswith("_")
    )


def probe_dirs():
    probes = SPECS_DIR / "probes"
    if not probes.is_dir():
        return []
    return sorted(path.parent for path in probes.glob("*/manifest.json"))


def manifest_features(manifest):
    features = {"always"}
    if manifest.get("exec"):
        features.add("exec")
    sources = manifest.get("sources") or []
    if sources:
        features.add("sources")
        live = [s for s in sources if isinstance(s, dict) and s.get("mode") == "live"]
        features.add("sources_live" if live else "sources_warm")
    if "queries" in manifest:
        features.add("queries")
    if manifest.get("commands") or manifest.get("shebangs"):
        features.add("commands")
    if "hints" in manifest:
        features.add("hints")
    if manifest.get("source_actions"):
        features.add("source_actions")
    if manifest.get("navigation"):
        features.add("navigation")
    if manifest.get("status"):
        features.add("status")
    if manifest.get("listen"):
        features.add("listen")
    for capability in manifest.get("capabilities") or []:
        features.add(f"capability:{capability}")
    return features


def applicable(spec, features):
    return all(predicate in features for predicate in spec.get("requires", []))


class Overrides:
    def __init__(self, path=None):
        path = path or SPECS_DIR / "overrides.json"
        self.table = {}
        if path.exists():
            self.table = json.loads(path.read_text())

    def _entry(self, plugin_key):
        return self.table.get(plugin_key, {})

    def disposition(self, plugin_key, spec_name):
        """Returns (mode, reason): mode in {run, skip, xfail}."""
        entry = self._entry(plugin_key)
        for mode in ("skip", "xfail"):
            for pattern in entry.get(mode, []):
                if fnmatch.fnmatch(spec_name, pattern):
                    return mode, entry.get("reason", "")
        return "run", ""
