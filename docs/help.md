# Browser help

Flash's browser help combines feature guides with the state of the running
resident. `flash help_show` opens its homepage; `:help` works after opening
the command line with `flash enter_command_mode` or a user-defined shortcut.
The default NORMAL `?` mapping opens
the effective mapping table, as does `:mappings`; the mapping syntax guide
remains available through `:help mappings`.

`:help <topic>` opens a guide directly:

```text
:help plugins
:help normal-mode
:help widgets
:help config
```

The homepage is one checklist for this Mac. It marks permissions, the config
file, shortcuts, plugins, and the status bar from the resident's state, and it
remembers which guides this browser has opened. Guides
cover hints, grid/pointer control, modes, flashlight, mappings, configuration,
status formats, the status bar, widgets, popups, plugins, privacy,
troubleshooting and development. Items in "What is missing" open their linked
guide or page when they have one; otherwise they jump to their checklist step.
Plugin manifests add their own topics.

## Live reference

| Page | What it describes |
| --- | --- |
| Mappings | Effective bindings after defaults, plugin contributions and user overrides, grouped by mode. A blank search stays alphabetical by command. The search ranks what a binding does, including typos. Each row has a small copy control for a TOML snippet that changes the binding; the Source column links plugin origins to their details and config origins to the live editor |
| Keyboard | The `[keyboard] layout` drawn as keys, each showing what it does in the mode Flash is in: the bindings of that mode and `all`, the hint alphabet with each key's ease while labels are up, the grid block while the grid is up, the adjust, pointer and search keys in their sessions, and the zone of `label_order = "zones"`. Follows the resident's mode and hint session over the event stream, or a mode picked by hand. Selecting a key lists its bindings. Nothing typed is shown, only what Flash is ready for |
| Commands | Built-in and installed plugin command definitions, sorted alphabetically |
| Plugins | Loaded manifests, process health, errors and capabilities. Selecting Inspect details opens a dialog; Escape or its close button dismisses it |
| Runtime | Current mode, app, configuration diagnostics, permissions, input capture, hints and window state. Resolved configuration is JSON: default values keep the base colour, and an override is marked with the layer that set it. Config provenance links jump to the editor on the same page; Purge defaults removes bundled values in the editor and Save writes the file |
| Logs | Recent structured diagnostics and interaction traces |
| Clipboard | Recent text, images, formatted copies, and files from the clipboard plugin. The page requests history directly on opening, loads the full configured history in pages, can refresh it, and can copy back or delete each entry |

The browser follows the resident's event stream: Flash pushes a snapshot when
something it shows changes, never on a timer, and the page derives uptimes
from the start times it carries. Plugin CPU time and memory change without an
event, so they read as of the last snapshot; Refresh on the runtime page and
Resample on a plugin's details ask for a fresh one. A disconnected browser
keeps its last snapshot and marks the connection state with a small warning
icon in the top bar. The icon's title explains that the snapshot may be stale;
the page must not present that snapshot as current. Runtime state can include private app or clipboard data;
see [privacy](privacy.md#local-inspector) before sharing it.

## Routes and ownership

The inspector listens on loopback (port 4242 by default), starting when one of
the browser commands needs it, or at launch with
`[debug] http_inspector_enabled = true`. It stays available until Flash quits.

| Path | Destination |
| --- | --- |
| `/` | Help homepage: a live onboarding checklist |
| `/docs`, `/docs/<topic>` | Guide index; documentation topic, including aliases |
| `/mappings`, `/commands` | Key mappings: your keyboard with what each key does in the mode picked under it (NORMAL, VISUAL, DRAG, HYPER, INSERT, COMMAND, TERMINAL or all), tinted by purpose, with free keys dashed and NORMAL's counts marked. Modifier buttons show the Shift, Control, Option and Command layers; a key that starts longer bindings opens what can follow it; picking a key lists its bindings, and a free key offers the TOML to map it. The list below follows the mode and key, groups bindings by purpose, leads with what each does, and copies the TOML that rebinds or removes it. A search ranks the whole mode and lights the keys it matches. The page also shows how each action resolves in the focused app, and never follows the live mode. Command catalog. Opening mappings focuses its search. `?q=<text>` starts the list filtered |
| `/plugins`, `/plugins/<id>` | Plugin list; a direct plugin link opens that plugin's details in a dialog |
| `/state`, `/clipboard` | Runtime and clipboard pages |
| `/logs` | Live logs. The record list fills the page height, and its search field is focused when the page opens |
| `/search?q=<text>` | Results across guide sections, commands, mappings and plugins. Typing in the top bar rewrites the query in place, so a search reloads and can be shared; `↓` `↑` `↩` pick a result |
| `/api/state`, `/api/logs`, `/api/traces`, `/api/events` | JSON snapshots and the server-sent event stream the pages read; `/api/state?refresh=1` takes a fresh snapshot |
| `/api/clipboard/<id>` | `GET` returns one history image. `DELETE` removes that entry. The id is 32 lowercase hex characters |
| `/api/clipboard/history?offset=<n>` | Up to 100 history entries from newest to oldest, plus the next offset or null at the end |

The page routes itself with the History API: same-origin page links navigate
in place, back/forward restore each page's scroll position, and modified,
middle or new-window clicks keep the browser's behavior. The top bar shows
the path as a breadcrumb (page › group › guide), hidden on Home, and the tab title
names the guide. After a navigation focus moves to the main region and the
new title is announced to assistive technology. Shortcuts outside a text
field: `/` or `⌘K` search, `[` and `]` previous and next guide, `g` then a
letter jumps to a page, `?` opens the shortcut sheet. Escape blurs a focused
field so these page shortcuts work again. The server answers
a direct load or reload of any page with the app, an unknown path with the
app's not-found page and a 404 status, and an unknown `/api/` path with a
plain 404. `DebugServer.Page` and `Inspector/src/lib/routes.ts` hold the same
page table; change them together.

Fragments are in-page anchors. Guide headings take GitHub-style slugs, so
`/docs/normal-mode#input-capture-and-latency` opens a guide at a section, and a
guide's `#heading` links and `other-guide.md#heading` references resolve.

`HelpDocs.allTopics` merges built-in and manifest topics in reading order:
`HelpDocs.groups` names each built-in topic's section and position, and
plugin topics follow under one group. The snapshot carries `group` and
`manual` with each topic; the browser groups the sidebar and index from
them and derives previous/next links, so a new built-in guide only joins
`groups` (a test rejects one left out). The browser also remembers, in its
own localStorage, a hash of each guide it has shown: a guide whose body
changed since is marked updated and an unknown one new, until opened, and
the guide index lists them with a link to the release notes. A name or alias
may identify only one accepted topic: built-ins take precedence, then the
first plugin topic claiming the name wins. The browser's navigation and search use
that installed inventory. Links between guides use `/docs/<topic>`; links to
runtime companions use their page paths, such as `/mappings` or `/state`.
Long-form references link to the published manual through
`HelpDocs.manual("<page>")`, which is `docs/` built by mkdocs at
<https://aymericbeaumet.github.io/flash/> from `main`; the `manual` topic
(`:help manual`, aliases `docs`, `reference`, `alternatives`) is its table
of contents. Source files that are not manual pages, such as `AGENTS.md`,
keep absolute repository links pinned to the bundle's `FlashGitCommit`.

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
builds a separate unminified page and stages it into the app at
`Contents/Resources/Flash_flash.bundle/inspector.html`. The resident reads
that copy. The generated `Bundle.module` path does not, so leaving the new
page only in `.build` does not change what the installed app serves.

Check browser routes (direct loads, back/forward, heading anchors), search,
guide links, live/disconnected states, narrow layouts and print preview after
UI changes. Below 1300 px the outline folds into a disclosure above the
article; below 1000 px the guide list becomes a drawer under a toggle; below
700 px the sidebar becomes a scrimmed drawer and the breadcrumb keeps its
last crumb. Nothing is set below 12 px and interactive targets are at least
40 px tall. `node --test Inspector/*.test.ts` runs the pure tests (search,
reading state, onboarding, mapping search, keyboard). The page must remain self-contained and must render
plugin-authored Markdown as untrusted content.
