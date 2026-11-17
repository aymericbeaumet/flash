# Browser help internals

How the browser help serves the documentation and the live pages, and how both
copies of the documentation are built. For using the help, see
[browser help](help.md).

## Writing pages

Every link stays on its own site. In the help, the sidebar, a page's
relative `.md` links, `:help <page>` code, search results, the live pages'
Documentation links and plugin guides' references all lead to `/docs/<page>` and
navigate in place
from the bundle the page loaded once; a link written as a published-site URL
becomes the local page too. On the published site the same links lead to
`/flash/<page>/` and work without JavaScript; client-side navigation takes
over once the whole documentation has loaded. Only genuinely external links, such as
the repository or "Edit on GitHub", leave either site; the resident's copy
pins a link into the repository's `main` (a source file that is not a page,
such as `AGENTS.md`) to the commit it was built from.

A page may link the help's live pages as absolute paths (`[key mappings](/mappings)`,
`/state`, `/plugins`, `/logs`, `/monitors`, `/clipboard`, `/commands`, `/`):
the resident's help links them, and the published site, which has no resident,
names them as text marked as a live page of Flash's own help. Any other
absolute path is an error. An alias (`docs/nav.json` `aliases`) shows its
page and settles on the page's path; on the published site it is a stub that
moves to the page.

Pages render tables (with column alignment), admonitions
(`!!! note "Title"` over four-space-indented content), heading permalinks,
highlighted TOML, shell, JSON, Rust and Lua code blocks with a copy button,
images and other files under `docs/` (TOML, JSON, text and raster images,
served as they are: `/docs/examples/statusbar/flash.toml` and
`/flash/examples/statusbar/flash.toml`; no SVG or HTML runs in the help's
origin), and raw `<details>`, `<summary>`, `<kbd>` and a few other tags
without attributes. An HTML comment renders nothing:
`<!-- modes: assumed on -->` is a note to the tests
([development](development.md#verification)).

## Routes and ownership

The inspector listens on loopback (port 4242 by default), starting when one of
the browser commands needs it, or at launch with
`[debug] http_inspector_enabled = true`. It stays available until Flash quits.

Every account and process on the Mac shares the loopback address, so every
`/api/` route except `/api/docs` answers only a request carrying the access
token (`HelpAccess`), 401 otherwise: `Authorization: Bearer <token>`, or
`?token=<token>` for an event stream or an image. The token is 32 random
bytes in `~/Library/Application Support/Flash/help-token` (`0600`), kept
across launches. The address Flash opens carries it once; the page moves it
into `localStorage`, which is per origin and so per port (never a cookie,
which every port of the host would receive), and drops it from the address.
The page shell and the bundled documentation need no token. Scripts and
oracles read the file and send the header. A connection sends its whole request within 10 seconds,
or it is closed, and at most 32 may be waiting to: a process holding
connections open cannot use up Flash's file descriptors.
Finite responses advertise `Connection: close` because the server handles one
request per connection. Text and byte replies share the same header builder;
the event stream keeps its separate `keep-alive` connection. The page shell
and the bundled documentation change only with the app: they carry an `ETag`
and `Cache-Control: no-cache`, so a browser keeps its copy, revalidates it on
each load, and an unchanged one is a bodiless 304. Runtime data is
`no-store`. Nothing is compressed: over loopback, compressing only adds
time ([performance](performance.md#browser-help)).

| Path | Destination |
| --- | --- |
| `/` | Help homepage: a live onboarding checklist |
| `/docs`, `/docs/<page>` | The documentation: its home page (`docs/README.md`) and every other page by its path under `docs/`, at any depth, or by alias; else a plugin's guide by name or alias. A path whose last segment has an extension (`/docs/examples/statusbar/flash.toml`) is that file of `docs/`, sent as it is |
| `/mappings`, `/commands` | Key mappings: your keyboard with what each key does in the mode picked under it (NORMAL, Text, VISUAL, HOLD, HYPER, INSERT, COMMAND, TERMINAL, each of your layers or all), tinted by purpose, with free keys dashed and NORMAL's counts marked. Modifier buttons show the Shift, Control, Option and Command layers; a key that starts longer bindings opens what can follow it; picking a key lists its bindings, and a free key offers the TOML to map it. The list below follows the mode and key, groups bindings by purpose, leads with what each does, and copies the TOML that rebinds or removes it. A search ranks the whole mode and lights the keys it matches. The page also shows how each action resolves in the focused app, and never follows the live mode. Command catalog. Opening mappings focuses its search. `?q=<text>` starts the list filtered |
| `/plugins`, `/plugins/<id>` | Plugin list; a direct plugin link opens that plugin's details in a dialog |
| `/state`, `/monitors`, `/telemetry`, `/clipboard` | Runtime, monitors, telemetry and clipboard pages |
| `/logs` | Live logs. The record list fills the page height, and its search field is focused when the page opens |
| `/search?q=<text>` | Results across documentation sections, plugin guides, commands, mappings and plugins. Typing in the top bar rewrites the query in place, so a search reloads and can be shared; `↓` `↑` `↩` pick a result |
| `/api/state`, `/api/logs`, `/api/traces`, `/api/events` | JSON snapshots and the server-sent event stream the pages read; `/api/state?refresh=1` takes a fresh snapshot. A stream sends `state`, the whole snapshot, once, then a `patch` per snapshot: `{"base": <snapshot_seq>, "set": {…}, "unset": […]}`, the top-level sections that changed since snapshot `base`; and `logs`, then one `log` per record |
| `/api/clipboard/<id>` | `GET` returns one history image. `DELETE` removes that entry. The id is 32 lowercase hex characters |
| `/api/clipboard/<id>/pin` | `PUT` pins that entry, `DELETE` unpins it; 409 with the reason when pins would fill the history |
| `/api/clipboard/history?offset=<n>` | Up to 100 history entries, pinned ones first, then from newest to oldest, plus the next offset or null at the end |
| `/api/docs`, `/api/docs/search` | The bundled documentation (`docs.json`: navigation, pages and their Markdown) and its search sections, read from `Contents/Resources/docs` off the main thread |
| `/api/telemetry` | What the OTLP receiver holds: every metric with its series, history and derived values, then the retained log records and spans, oldest first ([telemetry](telemetry.md#the-telemetry-page)) |

The page routes itself with the History API: same-origin page links navigate
in place, back/forward restore each page's scroll position, and modified,
middle or new-window clicks keep the browser's behavior. The top bar shows
the path as a breadcrumb (page › group › page), hidden on Home, and the tab title
names the page. After a navigation focus moves to the main region and the
new title is announced to assistive technology. Shortcuts outside a text
field: `/` or `⌘K` search, `[` and `]` previous and next page, `g` then a
letter jumps to a page, `?` opens the shortcut sheet. Escape blurs a focused
field so these page shortcuts work again. The server answers
a direct load or reload of any page with the app, an unknown path with the
app's not-found page and a 404 status, and an unknown `/api/` path with a
plain 404. `DebugServer.Page` and `Inspector/src/lib/routes.ts` hold the same
page table; change them together.

Fragments are in-page anchors. Headings take the slugs the published documentation
has always used (Python-Markdown's: accents folded to ASCII, punctuation
dropped, a repeated heading suffixed `_1`), so
`/docs/input-internals#input-capture-and-latency` opens a page at a section on
either site, and `#heading` and `other-page.md#heading` references resolve.

Everything Flash documents is this documentation; there is no help prose in the
Swift sources. The build writes `routes.json` beside the bundled documentation: every
page path and alias, which the resident reads once at launch
(`HelpDocs.manualNames`) for `:help` completion. A plugin's `help.topics[]`
are the only other help: the snapshot carries them, a topic named like a page
path or alias the documentation routes stays the documentation's and the first plugin
claiming a name keeps it
(`HelpDocs.pluginTopics`), and the browser renders them at `/docs/<topic>`
as untrusted Markdown. The browser also remembers, in its own localStorage, a
hash of each page and plugin guide it has shown: one whose text changed since
is marked updated and an unknown one new, in the sidebar and the
Documentation count, until opened. While any is, the documentation view shows
a toast explaining the mark, with Mark all as read; its dismissal is stored
under a hash of every page and guide (`readingKey`), so it returns only when
the documentation changes.

Command and mapping inventories derive from the effective runtime
definitions; do not maintain parallel hard-coded reference tables. When
adding a feature, document it in the page that owns the subject (or a new
page joined to `docs/nav.json`, with aliases for the short names `:help`
should take), link its live companion when available, and keep routes unique.
The tests cover link resolution on both sites, every former topic name, alias
rules, plugin topic collisions, browser URL construction and the server's
page, endpoint and not-found routing.

## Design

The help is dark only: deep ink surfaces with parchment text, brass for
emphasis and links, verdigris for what is healthy, amber for warnings and an
oxidised red for errors. The interface uses the system sans and values, keys
and code the system monospace, so the page loads no fonts. Panels are hairline
bordered and lightly engraved; brass rivets mark page and section heads, a
short tick ruler sits under each title, and the monitors draw gauge dials.
Motion is limited to short colour and opacity changes, all off under
`prefers-reduced-motion`.

A report that needs no answer is a toast, never a popup (Flash's popups are
terminal surfaces) and never a banner in the page. `Toaster.svelte`, mounted
once by the app shell on both sites, draws the page's one stack
(`toasts.svelte.ts`) in a polite live region that is always present, and is
a Notifications landmark while it holds a toast; `Toast.svelte` draws one,
and `toast.ts` is the stack with its clock and storage passed in. A caller
gives a message, an optional icon with or without an accessible label, a
tone, actions (label and handler, closing the toast unless kept open), the
dismiss control's name, an optional `persist` key under which the reader's
dismissal sticks in localStorage, an optional timeout that pointing or
focus holds, and an optional group whose next toast replaces the last. The
shared wording lives beside the stack: `copyText` and `copiedToast`
(`Copied <subject>.`), `doneToast` for a confirmation on one five-second
clock, `failedToast` for a failure that stays until dismissed. A toast
never takes focus; one closing with focus inside hands it to the toast now
in its place, else back where it came from, else to the main region. While
a toast that stays is up, the shell leaves the stack's height free under the
last line of every page, so it covers nothing for good; a passing toast
leaves by itself and moves nothing. A caller closes its toasts when what they say
stops being true and when it unmounts, so no action outlives its owner.
Toasts sit under scrims and dialogs; a modal dialog makes them inert, so
what happens inside one is reported inside it.

Every page leads with its data. Its head is a title, one line of purpose, the
page's controls and a Help toggle: the explanation folds behind it, with a
link to the page of the documentation that covers it (`Documentation →`). Sections fold their own explanation behind a small
`?`. The toggle remembers, per page, whether this browser left it open.

## Frontend changes

`Inspector/` is a Svelte app. Run `mise run test:inspector` (its type check
and unit tests), then `mise run build:inspector` to update the
committed `Sources/flash/Resources/inspector.html`. Plain SwiftPM builds serve
that resource; CI checks that it matches the frontend source. A dev install
builds a separate unminified page and stages it into the app at
`Contents/Resources/Flash_flash.bundle/inspector.html`. The resident reads
that copy. The generated `Bundle.module` path does not, so leaving the new
page only in `.build` does not change what the installed app serves.

Check browser routes (direct loads, back/forward, heading anchors, aliases),
search, page links, live/disconnected states, narrow layouts and print preview after
UI changes. Below 1300 px the outline folds into a disclosure above the
article; below 1000 px the page list becomes a drawer under a toggle; below
700 px the sidebar becomes a scrimmed drawer and the breadcrumb keeps its
last crumb. Nothing is set below 12 px except the 11 px notes printed on
the mapping keyboard's keycaps. List rows and navigation links are at least
36 px tall and every other control at least 26 px, so dense pages stay dense.
`mise run test:inspector` runs the pure tests (search,
reading state, onboarding, mapping search, keyboard, request retry, clipboard
history paging and resume, monitors, toasts, state patches, and the documentation: rendering, routes on
both sites and every link of every page), renders the toast components on the server and holds the
committed page to its size budget (`Inspector/budget.test.ts`). The page must remain
self-contained and must render plugin-authored Markdown as untrusted content.

## Keeping it fast

Browsing the help stays within a frame or two; [performance](performance.md#browser-help)
has the numbers and how to measure them. What keeps it there:

- The state and the logs are immutable values (`$state.raw`). A stream
  patch replaces only the sections it carries, so a derived value that reads
  an unchanged section keeps its result; the store shows what arrived once
  per animation frame. Never copy a whole section to change one field.
- Work that depends only on the data is prepared when the data arrives, not
  per keystroke or per render: the mapping search's normalized fields, the
  command and clipboard search text, log search text, and the reading state's
  page hashes, which the build writes into `docs.json` (`ManualPage.hash`).
- The resident's help builds a page's Markdown tree with plain DOM calls
  (`Markdown.svelte`); the server render and the published site, which
  hydrates it, use the template. Neither parses a string as HTML.
- A manual page renders while its link is pointed at or focused
  (`prepareOnIntent`), and the search sections load as the search field
  takes focus.
- The page shell is one file the browser revalidates; keep it within its
  budget, and keep the bundled documentation and runtime data behind their
  endpoints rather than in the page.

## Building the documentation

`Inspector/scripts/site.ts` turns `docs/` into both copies of the documentation with
the inspector's own renderer and components:

- `mise run build:inspector` bundles it into `build/docs` (`docs.json`,
  with each page's Markdown and its hash, `search.json` and `files/`), which
  the app assembly copies to `Contents/Resources/docs` for `/api/docs` and
  `/docs/<file>`.
- `mise run build:site` builds the published site into `build/site`: the
  same App in its site mode, rendered on the server for every page (plus
  search and 404) and hydrated in the browser, with the documentation, its search
  index and the files under `docs/`. `.github/workflows/pages.yml` deploys
  it; the CI documentation job runs the same build.

Both fail on a broken link or anchor, an absolute link inside the documentation, a
Markdown file neither in `docs/nav.json` nor listed there as `unlisted`, or a
navigation entry without its file. The site build also renders every page
for both sites and fails on any link that leaves the site, names a missing
file or heading, points at a local help route from the published site, or at
the published site from the help. A new page joins `docs/nav.json`.
