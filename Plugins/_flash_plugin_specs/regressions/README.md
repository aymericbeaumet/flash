# Regression specs

**The rule: a protocol bug found in ANY SDK gets its minimal repro here
FIRST, then the fix lands in every affected SDK, then any temporary
`overrides.json` xfail entry is deleted.** An xfail that starts passing fails
the run, so parity debt can only shrink — this directory is the permanent,
growing proof that fixed bugs stay fixed in the host and Rust SDK.

Conventions:

- Filename: `<yyyy-mm-dd>-<slug>.json`.
- `contract` (required, as everywhere): the clause the bug violated.
- `issue` (required here): the bug link or a one-line inline description
  when no tracker entry exists.
- `requires`: chosen so the spec runs against every SDK that has the
  surface — most repros reduce to lifecycle/wire scenarios and run
  everywhere, probes included.
- If the fix must be staged across SDKs, land the spec first with per-SDK
  `xfail` entries in `overrides.json` (reason linking the issue); delete
  each entry as its fix lands.

The scenario language is documented in `../schema.json`.
