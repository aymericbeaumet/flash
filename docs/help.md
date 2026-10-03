# Browser help

Flash's browser help combines feature guides with the state of the running
resident. `:help` opens its homepage. The default NORMAL `?` mapping opens
the effective mapping table, as does `:mappings`; the mapping syntax guide
remains available through `:help mappings`.

`:help <topic>` opens a guide directly:

```text
:help plugins
:help normal-mode
:help widgets
:help config
```

The homepage links first steps, feature guides, and live diagnostics. Guides
cover hints, grid/pointer control, modes, flashlight, mappings, configuration,
status formats, the status bar, widgets, popups, plugins, privacy,
troubleshooting and development. Plugin manifests add their own topics.

## Live reference

| Page | What it describes |
| --- | --- |
| Mappings | Effective bindings after defaults, plugin contributions and user overrides |
| Commands | Built-in and installed plugin command definitions |
| Plugins | Loaded manifests, process health, errors and capabilities |
| Runtime | Current mode, app, configuration diagnostics, permissions, input capture, hints and window state |
| Logs | Recent structured diagnostics and interaction traces |
| Clipboard | Recent entries supplied by the clipboard plugin |

The browser follows the resident's event stream: Flash pushes a snapshot when
something it shows changes, never on a timer, and the page derives uptimes
from the start times it carries. Plugin CPU time and memory change without an
event, so they read as of the last snapshot; Refresh on the runtime page and
Resample on a plugin's details ask for a fresh one. A disconnected browser
keeps its last snapshot and marks the connection state; it must not present
that snapshot as current. Runtime state can include private app or clipboard data;
see [privacy](privacy.md#local-inspector) before sharing it.

## Routes and ownership

The inspector listens on loopback (port 4242 by default), starting when one of
the browser commands needs it, or at launch with
`[debug] http_inspector_enabled = true`. It stays available until Flash quits.

| Path | Destination |
| --- | --- |
| `/` | Help homepage |
| `/docs`, `/docs/<topic>` | Guide index; documentation topic, including aliases |
| `/mappings`, `/commands` | Effective mappings and how each action resolves in the focused app; command catalog. `?q=<text>` starts the list filtered |
| `/plugins`, `/plugins/<id>` | Plugin list; one plugin's details |
| `/state`, `/logs`, `/clipboard` | Runtime, logs and clipboard pages |
| `/api/state`, `/api/logs`, `/api/traces`, `/api/events` | JSON snapshots and the server-sent event stream the pages read; `/api/state?refresh=1` takes a fresh snapshot |

The page routes itself with the History API: same-origin page links navigate
in place, back/forward restore each page's scroll position, and modified,
middle or new-window clicks keep the browser's behavior. The server answers
a direct load or reload of any page with the app, an unknown path with the
app's not-found page and a 404 status, and an unknown `/api/` path with a
plain 404. `DebugServer.Page` and `Inspector/src/lib/routes.ts` hold the same
page table; change them together.

Fragments are in-page anchors. Guide headings take GitHub-style slugs, so
`/docs/normal-mode#input-capture-and-latency` opens a guide at a section, and a
guide's `#heading` links and `other-guide.md#heading` references resolve.

`HelpDocs.allTopics` merges built-in and manifest topics. A name or alias may
identify only one accepted topic: built-ins take precedence, then the first
plugin topic claiming the name wins. The browser's navigation and search use
that installed inventory. Links between guides use `/docs/<topic>`; links to
runtime companions use their page paths, such as `/mappings` or `/state`.
Repository references use absolute links pinned to the bundle's
`FlashGitCommit` when available, so they work from a locally served page and
follow the installed source revision.

Built-in prose lives in `HelpDocs.swift` or beside the feature that owns it
(`Config.helpTopic`, `NormalModeDispatcher.helpTopic`,
`URLEventHandler.helpTopic`, `PluginManager.helpTopic`). Command and mapping
inventories derive from the effective runtime definitions; do not maintain
parallel hard-coded reference tables. The full engineering contracts stay
in `docs/` and are linked from the concise browser guides.

When adding a feature, update its owning topic or add a topic to `HelpDocs`,
link its live companion when available, and keep routes unique. The help
tests cover core workflow discoverability, alias resolution, plugin collisions,
internal guide links, mapping resolution, browser URL construction and the
server's page, endpoint and not-found routing.

## Printing

Every page prints in full: print styles release the app shell's fixed-height
scroll container, drop the navigation, search, filters and connection status,
repeat table headers across pages and keep rows whole. The log list prints
every filtered record rather than its visible window. Printing the mappings
page gives a complete reference of the effective bindings; filter it first to
print a subset.

## Frontend changes

`Inspector/` is a Svelte app. Run `pnpm check` there, then run
`Scripts/build-inspector.sh --release` from the repository root to update the
committed `Sources/flash/Resources/inspector.html`. Plain SwiftPM builds serve
that resource; CI checks that it matches the frontend source. A dev install
builds a separate unminified page and stages it into the installed app.

Check browser routes (direct loads, back/forward, heading anchors), search,
guide links, live/disconnected states, narrow layouts and print preview after
UI changes. The page must remain self-contained and must render
plugin-authored Markdown as untrusted content.
