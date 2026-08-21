#!/usr/bin/env python3
"""Spec-driven protocol conformance runner for Flash plugins, any language.

Thin shim over the Scripts/flash_spec_runner package (kept at this path — the
docs, CI, and muscle memory all call it). See the package docstrings and
Plugins/_flash_plugin_specs/schema.json for the spec schema; quick usage:

    # legacy per-plugin loop, from the plugin's directory:
    python3 Scripts/plugin-protocol-spec.py [--skip GLOB]... [--only GLOB]... -- <argv...>
    # full conformance matrix, from anywhere in the repo:
    python3 Scripts/plugin-protocol-spec.py --all [--jobs 8] [--report out.json]
    python3 Scripts/plugin-protocol-spec.py --probes
    python3 Scripts/plugin-protocol-spec.py --sandbox --flash-bin .build/debug/flash
"""
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))

from flash_spec_runner.__main__ import main  # noqa: E402

if __name__ == "__main__":
    main()
