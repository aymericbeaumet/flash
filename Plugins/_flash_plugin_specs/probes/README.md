# Rust conformance probe

`rust/` is a deliberately generic plugin used to exercise every branch of
the language-neutral protocol suite. It has no Flash business concepts. The
manifest opts into sources, query, hints, commands, actions, navigation,
status, and events so the runner can test the complete SDK surface against
`../protocol.json` and the scenarios under `../`.

Build it with:

```bash
./Scripts/build-probes.sh
```

Run it with:

```bash
python3 Scripts/plugin-protocol-spec.py --probes
```

The probe must remain a hermetic Rust crate with its own lockfile and the
canonical `Plugins/_flash_plugin_rust/clippy.toml`. Add protocol regressions
as declarative scenarios under `../regressions/`; the probe is an executable
test fixture, not a second specification.
