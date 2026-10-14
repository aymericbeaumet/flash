# Security policy

Flash holds the Accessibility permission, runs a keyboard event tap while it
owns input, and runs plugins as child processes. Bugs in those areas deserve a
private report.

## Reporting

Use [GitHub private vulnerability reporting](https://github.com/aymericbeaumet/flash/security/advisories/new)
rather than a public issue.
Please include the Flash version (`flash status`), macOS version and steps to
reproduce. You will get an acknowledgement within a week.

## In scope

- Keystrokes from other apps reaching a log, a file, a plugin or the network.
- A plugin escaping its declared capabilities or sandbox profile.
- Synthesized input landing in the wrong app or as stray terminal text.
- Flash reading screen pixels by any path. It is designed never to.

[docs/privacy.md](docs/privacy.md) is the public inventory of permissions,
network destinations and stored data; a discrepancy between that page and the
code is also a bug.

## Supported versions

Only the latest nightly build is supported until the first tagged release.
