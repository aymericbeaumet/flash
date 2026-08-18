# Handout: 20260818-1433-rust-plugins-to-luau

> Resume: verify live state, then continue from **Next Actions**.

- Updated: 2026-08-18T14:33Z
- Working directory: `/Users/ab/workspace/aymericbeaumet/flash`
- Repository: `/Users/ab/workspace/aymericbeaumet/flash`
- Branch: `main`
- HEAD: `a447a56`
- Source session: `a5de3636-75b7-4cef-b283-d6acd3b5e9f3` (Claude Code)

## Objective

Decide on and plan the replacement of Flash's Rust subprocess plugin system with a single blessed language for both engine configuration ("configure with code", Neovim init.lua model) and the plugin ecosystem. Research and planning phase only — **no code has been changed**. The plan was written and presented via plan mode; the user interrupted approval to save this handout, so the plan is **not yet approved**.

## User Requirements

- One blessed language for config AND plugins; forcing it on the ecosystem is acceptable.
- Config becomes code: TOML + TOMLKit deleted entirely (no-backcompat rule 9 applies).
- ALL ~20 bundled Rust plugins are ported to the new language (user explicitly rejected absorbing tmux/firefox into Swift core).
- Strong sandboxing must remain: deny-by-default for third-party code.
- Dialect: **Luau** (user confirmed over PUC 5.5 / spike-both).
- Calculator: rewrite in pure Lua; drop fend-core; **zero Rust remains in the repo**.

## Current State

Research complete, plan file written, awaiting plan approval. Repo untouched (clean worktree at `a447a56`).

- Full plan: `/Users/ab/.claude/plans/i-m-considering-ditching-the-kind-reef.md` (outside repo — read it before executing).
- Research dossier (11-agent workflow `wf_a6442e9d-51f`, ~1M tokens: 3 codebase audits + 5 web deep-dives + 3-lens judge panel): full JSON at `/private/tmp/claude-501/-Users-ab-workspace-aymericbeaumet-flash/a5de3636-75b7-4cef-b283-d6acd3b5e9f3/tasks/wouwcxjjc.output` (`.result.{map,research,judges}`); per-agent results in `/Users/ab/.claude/projects/-Users-ab-workspace-aymericbeaumet-flash/a5de3636-75b7-4cef-b283-d6acd3b5e9f3/subagents/workflows/wf_a6442e9d-51f/journal.jsonl`. Both are tmp/session storage — may not survive; the plan file + this handout capture the conclusions.

## Decisions

- **Embed Luau in the Swift host**, VM-per-plugin (~20KB each) confined to per-plugin serial queues (mpv model); never cache `lua_State*` (Hammerspoon coroutine trap). Interrupt callbacks + allocator caps enforce the existing 10ms/50ms deadlines in-process (finer than today's 15s watchdog). Compile-from-source only; never accept plugin bytecode. Keep the `flash.*` API dialect-portable as a PUC 5.5 governance hedge.
- **Sandboxing becomes structural**: bare Luau VMs have zero ambient authority; capability-gated `flash.*` binding tables are injected per-plugin from the declared spec. Audit verified today's seatbelt is theater: profile is literally `(allow default)(deny network*)`, skipped for 5 of 20 plugins (calculator, processes, slack, spotify, tmux), `install` never sandboxed — so this is an upgrade, not a regression.
- **Warm catalog store stays Swift-side**: `flash.sources.publish()` converts Lua→Swift + runs existing quota validators once at publish; flashlight `sources.snapshot` never touches a VM (preserves O(memory) pull + 150ms first-paint barrier).
- **Plugin format**: directory with `plugin.lua` returning a spec table (mirrors manifest.json schema, strict unknown-key rejection kept); spec evaluated in a bare zero-binding VM, then gated APIs injected. No JSON manifest.
- Rejected (3-judge consensus, evidence in dossier): WASM (Swift second-class embedder, JIT-entitlement paradox, config-as-compiled-artifact fails the goal), native dylibs (`disable-library-validation` on the TCC-granted keyboard-tap process, unkillable stalls), TS sidecar (npm supply chain, 60–100MB runtime, config degenerates), LuaJIT (no MAP_JIT, permanent 5.1), JSC (runner-up; Phoenix precedent grew no ecosystem), status-quo-minus (keeps the real pain).

## Work Completed

- Measured scale: Rust side 15.7k LOC (SDK 3,323 + macros 352 + 20 crates 11,425; tmux 5,191, firefox 1,651; twelve plugins <350 LOC). Swift host plugin layer 5,610 LOC in `Sources/flash/App/Plugins/` (PluginProcess 1,891, PluginManifest 1,630, PluginManager 1,271, AXBroker 467, PluginFlashSource 295, MessagePackFrameCollector 56). Only ~2.3k LOC is subprocess-specific; ~3.3k survives any swap (manifest validation, dispatch indexes, AX broker, snapshot barrier, quota validators, git materializer).
- Noted AGENTS.md drift to fix during execution: `PluginSystem.swift` no longer exists; `--dev` build described as release but scripts run debug.
- Wrote the full migration plan (phases 0–F) in the plan file: Phase 0 Luau-in-SwiftPM spike with benchmark gates → runtime+bindings → config cutover → trivial-tier waves → heavies (tmux last) → delete subprocess layer → DX polish (`:lua` REPL, shipped `.d.luau`, docs).

## Key Locations

- `/Users/ab/.claude/plans/i-m-considering-ditching-the-kind-reef.md`: the complete approved-pending plan — architecture, `flash.*` binding inventory, phase details, risks, verification.
- `AGENTS.md`: plugin/warm-catalog/latency contracts that must survive the swap (lines ~287–560); hard rules incl. iteration-loop (deploy+commit each green change).
- `Sources/flash/App/Plugins/`: the 6-file host layer to split into deleted-vs-kept per the plan.
- `Plugins/_rust_flash_plugin/src/lib.rs`: SDK whose surface defines the `flash.*` binding inventory.
- `docs/plugins.md`: 263-line protocol spec to be replaced by Lua API docs.
- `Tests/FlashTests/PluginSystemTests.swift`: 1,549 LOC pinning the old subprocess contract; rewrite in Phase E.

## Verification

- Not run: any build/test — no code was changed; this session was research + planning only.

## Remaining Work

- Present the plan for approval (ExitPlanMode was interrupted, not rejected on the merits — re-present or revise per user feedback).
- Execute phases 0–F per the plan file. Phase 0 spike gates everything: Luau vendored as SwiftPM C++ target; benchmarks (sync evaluator ≤10ms round-trip, 10k-candidate publish conversion, interrupt-kill granularity, VM-per-thread confinement); prototype `subprocess` + `timer` bindings and port the `processes` plugin as proof.

## Blockers and Risks

- Plan not yet user-approved; do not start implementation without approval.
- Judge-flagged risks (details in plan file): binding layer becomes the safety-critical surface (async-by-construction, fuzz decoders); Luau governance (keep API dialect-portable); tmux port is the largest + only churn hotspot (port last, keep Rust crate until Lua port green); bounded migration overlap (each wave deletes its Rust crates when green); debugging story is the weakest DX pillar (REPL + source-mapped tracebacks are budgeted work, not polish).
- Unverified assumptions to validate in Phase 0: SwiftPM C++ interop friction with Luau; JSC-style per-VM memory numbers were never benchmarked (moot unless dialect changes).

## Next Actions

1. Re-enter plan mode context if needed; get the plan approved (or amended) by the user.
2. On approval: start Phase 0 spike exactly as specified in the plan file, publishing benchmark numbers before proceeding.
3. Follow the repo iteration rule during execution: each green change → `./Scripts/install.sh --dev` → commit → push.

## Suggested Skills

- `handout`: load this via `/handout 20260818-1433-rust-plugins-to-luau`.
- `commit` / `push`: per-wave commits during execution (iteration-loop rule).
