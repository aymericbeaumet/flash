# flashlight

`:flashlight` is a fast, typo-tolerant command bar for locations and plugin data. Its default results include apps, browser tabs, tmux windows, and other destinations. Narrow it to a [resource type](#narrow-to-a-resource-type) for richer searches:

```text
:flashlight @notes inbox
:flashlight @emojis fire
:flashlight @system
:flashlight @processes safari
:flashlight @windows invoice
```

`@windows` lists every window the [window switcher](windows.md#switch-to-any-window)
knows, searched by title and by app name, most recently focused first and the
window you are in last; picking one brings it forward as `window switch`
does, unminimizing it and unhiding its app. Minimized windows, hidden apps'
windows and windows on other Spaces are there with the same badges. Rows come
from memory: a query asks no app anything. Map it like any flashlight scope:

```toml
[mode.all.mappings]
"cmd+ctrl+[" = ["flash", "mode", "normal"]  # turns Flash's modes on; once per config
"cmd+ctrl+i" = ["flash", "mode", "insert"]

[mode.normal.mappings]
"<leader>w" = ["flash", "mode", "flashlight", "--query=@windows"]
```

`@system` lists Flash's system commands (`screen lock`, `system sleep`,
`system restart`, …); `@processes` lists every visible process with
its pid and CPU and memory shares. Both are live: Flash reads them only while
a query names them. Picking a restart, shut down, log out or empty-Trash row,
or a process, asks first in the centred alert: `y` runs it (a process gets
SIGTERM), any other key cancels.

`@notes`, `@reminders` and `@contacts` list your notes,
open reminders and contact cards while Notes, Reminders or Contacts runs;
picking a row shows it in its app. Flash keeps the last list in memory, so a
query never waits on the app, and relists it when the app launches, when you
leave it, and when the flashlight opens if the app is focused or the list is
a minute old; `notes refresh`, `reminders refresh` and `contacts refresh`
relist one at once. The first search of each asks macOS for access
(Automation of Notes, Reminders, Contacts); a refusal leaves it empty.

Browser history and bookmarks never join the default result pool: they reach
the flashlight through `@history` and `@bookmarks`, which read every
browser's, or a bang, which reads one browser's. The bundled `browsers` plugin copies Firefox `places.sqlite`
and Chrome `History` into its private cache (and reads Chrome `Bookmarks`) at
launch, when the flashlight opens, and when you leave Firefox or Chrome — at
most once a minute, and only when those stores changed; these sources stay
reachable while no browser runs.

```text
:flashlight @history rust
:flashlight @bookmarks docs
!fh rust      # Firefox history      (!fb bookmarks)
!ch docs      # Chrome history       (!cb bookmarks)
```

Files are found by name through Spotlight, which Flash queries only for an
explicit `!f` or `@files` search. The results are the first 200
files and folders with a word in their names starting with each typed word
(ignoring case and accents), in Spotlight's order; selecting one opens it. A
query that runs past `[flashlight] live_query_timeout_ms` lists the files
found so far.

```text
!f quarterly report
:flashlight @files invoice
```

Clipboard history is `!clip` (or `@clipboard`): pinned entries, then your
copies newest first, then the named registers, ranked by the query once you
type one. `<cr>` pastes the entry into the app the command line covered,
`<shift-cr>` pastes its plain text, `<alt-cr>` only puts it back on the
clipboard, and `<cmd-p>` pins or unpins it. The rows are kept in memory and
prepared once per copy, so typing never waits on the history: every pinned
entry and the newest 1000 others, each searched by its first line and the
start of what follows. See [clipboard](clipboard.md#paste-from-the-flashlight).

```text
!clip            # the history, newest first
!clip ssh key    # entries mentioning it
```

## Open it

- `flash mode flashlight` from a terminal, or `flash mode flashlight
  --query=@emojis` to open it scoped to one resource type.
- A mapping to `["flash", "mode", "flashlight"]`, with `--query=<text>` to
  pre-fill it (a `@type`, a `!bang` or text) and `--restore-mode` to
  return to the mode it opened from, such as INSERT, once it closes.
- `:flashlight <query>` in the command line.

`:open <args>` is unrelated: it forwards verbatim to `/usr/bin/open` (URLs,
files, `-a App`) with no finder smarts.

## Narrow to a resource type

Add one `@<type>` word *anywhere* in the query to restrict the pool to that
resource type: `:flashlight @notes inbox` searches only notes, and bare
`:flashlight @notes` lists every note. A type is one lowercase word, and it
names what the rows are, whoever feeds them: `@tabs` lists Safari's,
Chrome's and Firefox's tabs together, `@history` every browser's history.
Only the first `@<type>` counts; any other word is search text. A type
nothing feeds lists nothing.

Every row is labelled with its type, the word `@` filters by: `[tabs]`,
`[terminals]`, `[apps]`. When several sources feed a type, the one a row
comes from (`firefox`, `chrome`, `pinned`) is dimmed after it.

Typing an incomplete type such as `@ta` shows the types that match, each with
what feeds it (`[type] @tabs  chrome, firefox, safari`); `<tab>` or `<cr>`
inserts the selected one. Typing `!`
shows registered bang suggestions the same way, and adding a space locks the
bang for the rest of the query. A bang can be narrower than a type: `!fh`
reads Firefox's history alone, where `@history` reads every browser's.

| Type | Fed by | A row is |
| --- | --- | --- |
| `apps` | Flash | an installed or running app; selecting it opens or activates it |
| `windows` | Flash | a window of a running app; selecting it focuses that window |
| `clipboard` | Flash | a clipboard history entry, pinned entry or named register; selecting it pastes it |
| `notes`, `reminders`, `contacts` | Flash | a note, an open reminder or a contact card; selecting it opens it in its app |
| `files` | Flash | a file found by name through Spotlight; selecting it opens it |
| `processes` | Flash | a running process; selecting it offers to quit it |
| `menus` | Flash | a menu item of the frontmost app; selecting it presses it |
| `system` | Flash | a system action (lock, sleep, restart…); selecting it runs it |
| `tabs` | browsers plugin | an open browser tab, with its URL; selecting it switches to it |
| `history`, `bookmarks` | browsers plugin | a visited page or a bookmark, with its URL; selecting it opens it |
| `terminals` | terminals plugin | a tmux window; selecting it switches to it |
| `emojis` | emojis plugin | an emoji or symbol, by its Unicode name, shortcode or CLDR keyword (`idk`, `hooray`); selecting it types it |
| `bangs` | searchproviders plugin | a `!token` search shortcut; selecting it completes the bang |
| `snippets`, `shortcuts` | snippets, shortcuts plugins | a text snippet to type, or a Shortcuts app shortcut to run |
| `network` | sysinfo plugin | a network address of this Mac; selecting it copies it |

Plugins may feed these types and introduce their own; the rules every source
follows, and that Flash checks when a plugin loads, are in the
[plugin protocol](plugin-protocol.md#resource-types).

## Answers

Bare input also runs every pure query evaluator registered for the
flashlight. Evaluators return typed, additive answers rather than claiming
inputs with regular expressions. Flash gathers them for at most 50 ms, accepts
up to 16 answers per evaluator, and places them in a fixed lane above fuzzy
catalog matches; `!bang` and `@type` input bypasses that lane. The bundled
`answers` plugin handles arithmetic (`1+1`), units (`2 km to m`), currencies
(`10 euros`, `10 euros + 10 euros`), color conversions (`#ff8800`,
`rgb(255, 136, 0)`), and world clocks (`time in tokyo`). It loads cached
rates before becoming ready and refreshes them over the network only in the
background. Selecting an answer with `<tab>` or `<cr>` copies the exact
result.

## Selecting a row

Location rows are final destinations: `<tab>` or `<cr>` submits the selected
row directly, the same as `<cmd-cr>`. App switches and focused-window changes
feed Flash's movement history with the current location when a source can
identify it, so `ctrl-o` / `ctrl-i` can walk locations reached through
ordinary desktop switching.

Plugin catalogs are push-based: each candidate plugin publishes its full
catalog to the host whenever it changes, and Flash serves the flashlight from
its own in-memory store, so reading it performs no I/O and no plugin round
trip. On open the prompt appears immediately with its rows hidden while Flash
reads every default source, including the warm `core.apps` index. Flash
reveals the initial catalog exactly once, when every source settles or the
150 ms first-paint budget expires; later publishes merge in through a
coalesced refresh tick.

## Pick from a list

`menu choose` is a picker for scripts, as `dmenu` and `rofi -dmenu` are on
Linux: the flashlight lists the lines it is given, in their order, filters
them as you type with the same scorer, and the command answers with the line
you pick. In a terminal, `flash menu choose` reads the lines from standard
input (or `--file=<path>`), prints the pick and exits 0; Escape exits 1, so a
script stops there. Return with no matching line answers with what you typed.
While the list is up, `@`, `!` and `=` are plain text: only the given lines
are listed.

```sh
# Switch git branch.
git branch --format='%(refname:short)' | flash menu choose | xargs git switch

# Ask, and stop when cancelled.
choice=$(printf 'Wi-Fi\nBluetooth\nSound\n' | flash menu choose) || exit 1
open "x-apple.systempreferences:com.apple.$choice-Settings.extension"
```

From the command line or a mapping, `--file` names the list: `:menu choose
--file=~/projects.txt` opens it and shows the pick. A file holds up to 10,000
lines and 4 MB.

## Bangs

`!<bang> <query>` sends the query straight to a site. Alone, a bang opens the
site.

```text
!w rust ownership      # Wikipedia
!gh aymericbeaumet     # GitHub
!yt                    # YouTube's home page
!claude explain this   # a new Claude chat with the question filled in
```

Typing `!` lists the bangs; among equal matches, the ones DuckDuckGo users
pick most come first. A trigger has exactly one owner, tried in this order:

1. Flash's own `!f` and `!clip`, the file search and clipboard history above.
2. A bang a plugin declares by name: the `browsers` plugin's `!fh`, `!fb`,
   `!ch` and `!cb`, and every AI chat bang of `aiproviders`.
3. [Your own bangs](#your-own-bangs-and-quicklinks), `[flashlight.bangs]`.
4. The search bangs of `searchproviders`, which answers every other trigger.

### Your own bangs and quicklinks

[`[flashlight.bangs]`](config:flashlight.bangs) adds bangs of your own to
the list: an issue tracker, an internal search, a page you open ten times a
day. A name is one lowercase word of letters and digits; the value is an
http or https URL with `{query}` where the query goes, or a table that also
describes it for the list.

```toml
[flashlight.bangs]
jira = "https://example.atlassian.net/browse/{query}"
docs = { url = "https://docs.example.com/search?q={query}", description = "Search the docs" }
home = "https://intranet.example.com"
```

`!jira ABC-1` opens `https://example.atlassian.net/browse/ABC-1`. The query
is percent-encoded into every `{query}`, as a URL needs: letters, digits
and `-._~` stay, a space becomes `%20`, `&`, `/`, `?` and `+` their `%XX`
forms, so nothing you type can reach the site as URL syntax. With no query
the slot is empty. A URL without `{query}` is a quicklink: `!home` opens it
as written, and so does `!home anything`. The `!` list shows the
description, or the URL when there is none, and a typed `!jira ` underlines
as known. Braces other than `{query}` are reported, as is a name that
Flash's own `!f` and `!clip` or a bundled plugin's bang already owns —
`flash config check` names the owner. A plugin's search bang has no such
claim: `gh = "https://github.com/{query}"` makes `!gh` open a repository
page instead of GitHub's search.

`aiproviders` owns every AI chat bang in DuckDuckGo's and Kagi's lists:
Duck.ai as `!ai`, `!aichat`, `!chat`, `!duckai`, `!ddg-ai` and `!ddg-chat`;
`!chatgpt` (`!cgpt`), `!claude`, `!copilot`, `!felo`, `!grok`, `!ithy`,
`!lechat` (`!mistral`), `!lumo` (`!protonlumo`), `!perplexity` (`!pplx`,
`!ppx`), `!phind`, `!t3`, `!v0`, `!youai`, and Google's AI Mode as `!gai`
(`!googleai`, `!гии`). It adds `!gemini` and `!kagiassistant`. These open a
chat with the query filled in, then press Return 2.5 seconds later if the app
the page opened in still has focus. `!deepseek`, `!metaai`, `!huggingchat`,
`!qwen`, `!kimi`, `!poeai`, `!piai`, `!lmarena` and `!zai` open the
provider's home page; their URLs take no query. Kagi files OpenRouter's model
search (`!opr`) with its chatbots, but it opens no chat, so it stays a search
bang.

`searchproviders` knows every DuckDuckGo bang and every bang in Kagi's
community list, about 14,500 triggers, and turns each into the site's own
search URL on your Mac.
The query never passes through DuckDuckGo's or Kagi's redirect; only a bang
whose site is DuckDuckGo itself, such as `!i` for its image search, opens
there.

- Kagi's list (MIT License) ships with Flash at a pinned commit;
  `mise run update:bangs` refreshes the snapshot.
- DuckDuckGo publishes its list without a licence that allows shipping it.
  The plugin downloads `https://duckduckgo.com/bang.js`, which carries no
  query, and keeps a copy in its data directory. It downloads when the
  flashlight opens and the copy is missing or a week old, and after a failure
  waits an hour before trying again. Until the first download, Kagi's list
  answers alone.
- When both lists define a trigger, DuckDuckGo's wins. Kagi's list fills the
  triggers DuckDuckGo lacks. Kagi bangs that run a Kagi search, which needs a
  Kagi account, are left out.
- A trigger another owner declares is neither listed nor served, so `!fb`
  stays Firefox bookmarks rather than Facebook.
- Triggers ignore case. A DuckDuckGo bang encodes the query the way
  DuckDuckGo's redirect does: letters, digits and `!()*._~` stay, and a space
  becomes `%20`. With no query it opens the bang's domain. A template without
  a query slot opens as written. Kagi bangs follow their own format flags
  (`+` for a space by default). Kagi's three pattern bangs, such as
  `!rsr <subreddit> <query>`, fill each part of the query into its own place
  in the URL.

`@bangs` lists up to 10,000 bangs, the plugin catalog limit,
ranked by DuckDuckGo's usage. Every bang resolves whether it is listed or not.
A rare trigger outside the list still opens its site, but the flashlight
underlines it as unknown while you type it.

## Ranking

Results rank by what the query says about each row's own name first, and by
where the row comes from second:

1. A registered `!bang` the user typed.
2. Match tier against the row's name (title and aliases): exact, then a prefix
   of the name, then a word start inside it or every query word starting one of
   its words in any order (`flash github` finds `GitHub - aymericbeaumet/flash`),
   then a substring, then rows the query only touches through secondary text
   (URL, subtitle, source) or the typo-tolerant fuzzy matcher. Naming a source
   (`tmux` for the tmux windows) counts as an exact hit on its rows. The tier is
   strict: typing a tab's title lands on that tab above every app the query
   matches partially, and `mes` still puts Messages.app above a tab that merely
   contains "mes".
3. Source precedence inside one tier: the manifest `sources[].priority`
   (bundled: tmux windows `important`, apps and browser tabs `high`), a bonus
   for rows backed by a running process, and [`[flashlight.precedence]`](config:flashlight.precedence)
   overrides, which weigh resource types (`terminals = 200`). With no query this is the whole order: tmux windows, then running
   apps and open tabs, then installed apps, then other plugin locations.
4. Match score (how tightly the query fits the field) plus frecency, the
   recency-weighted count of past opens.
5. The source's own order, where it has one: clipboard history lists newest
   first, which is also the whole order of an empty `!clip`.

`app open --name=<text>` resolves app names precisely first, then ranks every
plugin location the same way and opens the first row.

Bare arithmetic, unit conversions, currency conversions, color conversions, and world clocks are answered inline by the bundled `answers` plugin. Use `:plugins` to inspect bundled integrations and their status, or `:about` to open the About Flash window.

The bundled tmux source automatically merges every attached local server.
Remote tmux sessions launched through SSH or Mosh join only for hosts listed in
`[plugins.terminals] ssh_hosts` (destinations as typed, without `user@`). Remote
inventory uses the plugin's own short noninteractive SSH calls, which can
prompt an SSH agent or hardware key and appear in the remote auth log, so
without that setting the plugin never inspects SSH/Mosh processes or runs
`ssh`. For a listed host it discovers terminal apps, PTYs, transports, tmux
paths, and windows from the live process graph—no terminal-specific
configuration is required. Catalogs refresh in the background, keep their last
good remote snapshot through brief disconnects, then expire it after two
minutes without a successful refresh. The interactive Mosh transport remains
independent of those inventory calls. Otherwise-identical windows are labelled
by host. The tmux source registers no keyboard mappings: terminal-native shortcuts
can send the user's normal tmux prefix bindings with zero Flash round trips.
Flash still resolves any discovered local or remote window from the finder.
Tmux hint discovery recognizes quoted absolute paths (including spaces and
Unicode), slash-separated relative paths, URLs, and ordinary filenames while
excluding dotted source identifiers such as `JumpTarget.isTextInput`.
Committing a terminal link with `f` sends Shift-click; `F` sends Command-Shift
so the terminal can open it in a new context. Flash does not open the value
itself.
Pane, window and link hints preserve the requested click modifiers. A click
on any of them keeps the mode: press `i` after a pane click to type into the
terminal.

See [normal mode](normal-mode.md) for shortcuts and mode behavior, and
[plugin configuration](plugin-cookbook.md) for extending the catalog.
