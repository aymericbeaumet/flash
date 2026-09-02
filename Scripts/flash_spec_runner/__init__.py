"""Spec-driven protocol conformance runner for Flash plugins.

The declarative JSON scenarios in Plugins/_flash_plugin_specs/ are the shared
cross-stack test suite: the host and maintained Rust SDK must behave
identically under them, and every protocol bug gets a minimal repro spec
before its fix lands. This package is the engine: it spawns one fresh plugin
process per spec with a production-scrubbed
environment, plays the steps, emulates the host side (scripted replies for
plugin->host RPCs), and reports a machine-readable verdict.

Entry point: Scripts/plugin-protocol-spec.py (a thin shim over __main__).
Spec schema reference: Plugins/_flash_plugin_specs/schema.json and the
docstrings in schema.py.
"""
