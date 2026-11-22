## What and why

<!-- What this changes, and the problem it solves. Link an issue if there is one. -->

## Checks

- [ ] `mise run check` passes (format, lint, guardrails, plugin gate, Swift suite).
- [ ] Behavior changes come with a test that failed before the fix.
- [ ] Docs, `config.default.toml` and `CHANGELOG.md` say what changed for users;
      a rename lists the new spelling under "Unreleased".
- [ ] `docs/privacy.md` is updated if this adds a permission prompt, a network
      destination, stored data or an unsandboxed plugin.
- [ ] It respects the hard constraints in [AGENTS.md](https://github.com/aymericbeaumet/flash/blob/main/AGENTS.md).
