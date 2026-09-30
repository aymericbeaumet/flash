# Status format language

Flash uses the tmux **3.7c** format and style language, with values supplied by
Flash. `statusbar.template`, text [popups](popups.md) and
[desktop widgets](widgets.md) share one compiler. There
is no tmux runtime dependency, tmux configuration import, or implicit connection
to a tmux server. Terminal popup commands have a separate lifetime; see
[popups](popups.md#lifecycles).

## Authoring

Write the whole format inline in `template`. A long bar can span a multi-line
TOML string, one lane per line:

```toml
[statusbar]
enabled = true
template = """
#[align=left]#[pill]#{flash.mode}#[nopill] · #{flash.active_app_name}
#[align=right]#{flash.plugin.cpu.summary} · %H:%M
"""
```

The bar is one line: a newline the template writes is dropped from the drawn
text, as is one inside a value it shows, so the TOML string above draws as the
single format `#[align=left]…#{flash.active_app_name}#[align=right]…%H:%M`.
Write the separating space yourself where two lines meet; indentation is text.
Inside a style marker a newline separates tokens, as a space does. Text popups
preserve their interior newlines. A desktop widget draws each line as its own
status line: styles carry across a line break, alignment starts again on the
left. Style and alignment markers are interpreted **after** format expansion,
so a conditional can select an entire styled/aligned section. Ordinary value substitution does
not recursively execute formats or jobs from the value; intentional
re-expansion uses `E:` or `T:`. Rich plugin/source values may still contain
styles, links, and popup markers.

The outer format performs native `strftime` expansion, so `%H:%M` written in
the template is the time; no `T:` is needed. Write `%%` for a literal percent
sign in authored templates; text inserted through an ordinary value is not
time-expanded. This also matters when authoring percent-encoded inline popup
bodies directly in a template. Plugin-supplied inline bodies arrive as values.

Configuration supplies no tmux user options (`@name`): there is no
`[statusbar.options]` or `[widgets.<name>.options]` table, and a format that
reads `#{@name}` gets an empty value, as with any unset tmux option.

## Native language coverage

The compatibility baseline follows the `format.c`, `style.c`, `format-draw.c`,
`colour.c`, and `utf8.c` implementations at the upstream `3.7c` tag. The matrix
covers the parser branches and their evaluation/drawing paths:

| Family | Native syntax and behavior | Verification |
| --- | --- | --- |
| Values and escaping | `#{name}`, `#D/#F/#H/#I/#P/#S/#T/#W/#h`, nested formats, escaped hashes/commas/braces, missing values | Pinned expansion corpus; explicit context tests |
| Literals and conversion | `l:`, `a:`, `b:`, `d:`, `c:` | Expansion corpus, all 256 palette entries and native named colors |
| Conditionals and booleans | `?condition,value,...,fallback`, `!`, `!!`, n-ary `&&`/`||`; unevaluated branches stay inactive | Corpus; job/dependency branch tests |
| Comparisons and patterns | `==`, `!=`, `<`, `>`, `<=`, `>=` compare strings; `m` uses POSIX glob or extended regex, with `i`/`r` flags | Corpus with escapes, captures, invalid patterns, and Unicode |
| Arithmetic | `e` arithmetic/comparison operators, floating flag and precision | Integer/floating matrix, numeric-bound tests |
| Transformation | Ordered `s/pattern/replacement/flags`, shell/style/argument `q` quoting, semicolon modifier chains | Corpus including repeated substitutions and mixed transformations |
| Width and repetition | `=`, optional trim marker, signed `p`, `n`, `w`, `R` | Cell-width/byte-count, styles, hashes, controls, combining/wide text corpus |
| Re-expansion and time | `E:`, `T:`, `t:`, pretty/custom time flags, inherited time expansion | Corpus and fixed-clock context tests |
| Iteration | `S`, `W`, `P`, `L`, sort/reverse flags, active alternatives, `loop_last`, window neighbors | Explicit record-context tests |
| Name/pane lookup | `N` window/session queries; `C` pane substring/glob or POSIX regex search | Explicit context tests; absent context returns `0` |
| Shell output | `#(command)`, expanded command arguments, prior/latest line, output re-expansion with nested jobs disabled | Evaluator tests and owned-process lifecycle tests |
| Appearance | Native foreground/background/underline colors, ANSI/X11/RGB palette; all native attributes and compound attribute sets | Live drawing oracle and typed-run tests |
| Style state | `default`, one saved `push-default`/`pop-default`/`set-default`, attribute negation, transactional invalid-marker rollback, `ignore` | Live drawing oracle |
| Drawing | Left/centre/right/absolute-centre, fills, lists/focus/markers, native ranges, wide-cell clipping and combined grid characters | Live grid oracle at several widths and production surface tests |
| Width/pad styles | Native `width=` and `pad=` parse and retain their state; tmux 3.7c status drawing does not consume these fields | Explicit inert-style oracle cases |

A positive `p5` pads the value on its **right**; a negative `p-5` pads on its
left. `n:` measures UTF-8 bytes and `w:` measures native format cells, excluding
styles. Native format width counts scalars; final grid drawing also combines
emoji, variation selectors, flags, and joiners. These operations deliberately
use different width paths.

Native style markers use comma, space, or newline separators. A malformed marker
leaves the previous style intact. `ignore` causes following style markers,
including `#[noignore]`, to be displayed literally. Attributes accumulate;
underline variants are independent native bits. `default` resets appearance to
the current saved default without clearing layout/interaction state. Native
`range=user|name` carries a maximum of 15 UTF-8 bytes.

The matrix and differential cases are regression evidence, not a mathematical
proof for every possible string. When changing the language, add the failing
native case to the corpus and inspect the corresponding pinned parser branch.

## Context supplied by Flash

Flash supplies `flash.mode`, `flash.date`, `flash.active_app_name`,
`flash.active_bundle_identifier`, `flash.secure_input`,
`flash.plugin.<id>.<segment>`, `flash.plugin.loaded_count`,
`flash.plugin.ready_count`, `flash.plugin.error_count`,
`flash.source.<name>`, and `flash.history.<name>` for a source that keeps a
`history`. Inside a desktop widget, `flash.widget.name` and
`flash.widget.columns` name the widget and its width; elsewhere they are
unknown values. Host/user/process values and the process environment are
available through ordinary lookup.

`flash.secure_input` is `1` while secure input is on (a password field has
focus, so the keyboard tap sees no keys and a hint session reads keys through
the key window) and empty otherwise:
`#{?flash.secure_input,#[fg=red]SECURE#[default] ,}`. It is refreshed when the
keyboard tap reads it for a key and when a hint session starts; nothing polls
it.

Flash has no implicit tmux session, window, pane, client, or pane-history
inventory. Their missing values expand to empty strings, loops over absent
collections produce no text, and name/pane searches return `0`. The pure
`StatusFormatContext` accepts explicit record collections and pane lines to
exercise those language operations. Context absence is distinct from a rejected
format operator. There is no tmux option database: user options (`@name`) are
unset, and the language operations that read options only see ones supplied
explicitly to `StatusFormatContext`, as the conformance corpus does.

## Jobs, sources, and Flash styles

Native `#()` invokes `/bin/sh -c` asynchronously using Flash's environment. The
original command identifies its cached output; changing its expanded command
restarts the job while the previous output remains available. The latest complete
line is published while running, and a final partial line is accepted on exit.
Output is re-expanded as a format with nested jobs and extra time expansion
disabled. Output updates are coalesced to at most once per second. A new job with
no output can show tmux's not-ready text. Repeated executions follow Flash's
status refresh cadence. Unchanged jobs survive template/configuration reloads.
When a job leaves the evaluated template, its process and cached output are
removed. Reappearing jobs start afresh; changed expanded commands keep their
last output until replacement output arrives. Completion tokens prevent retired
jobs from changing replacement records.

For explicit argv, an independent cadence, environment, working directory, or
rotating lines, declare a source:

```toml
[statusbar]
template = "#[align=right]#{flash.source.news}"

[statusbar.sources.news]
command = ["./news.sh"]
interval = 300
cycle_interval = 60
```

Only evaluated source references start jobs. A source interval of zero runs
once; `cycle_interval` rotates the latest successful nonempty lines independently
and marks their typed runs as `#[cyc]` content for the carousel push. Failed/empty named source output keeps
the last good value. Named sources use the configured timeout; native shell jobs
and PTYs do not inherit that timeout. Only the executable and explicit working
directory resolve against the defining configuration file; remaining arguments
stay opaque. Home/environment expansion happens at execution. Use
`working_directory = "."` (a popup's `cwd = "."`) for arguments relative to the
configuration directory.
Inactive sources retain last-good output without running or rotating; only
evaluated sources and cycles contribute timer deadlines. `history = N` (2–512)
keeps the last N numeric outputs as `#{flash.history.<name>}`, space-separated
and oldest first; a run whose output is not a number leaves it unchanged, the
ring survives while the source is inactive, and it cannot combine with
`cycle_interval`. Reading the history runs the source like reading its value.
The bar and desktop widgets share one set of sources and jobs: a source or job
several surfaces show runs once, a job at the fastest of their intervals. Changed/removed jobs
are invalidated before their processes are stopped in one bounded batch.

The additional style tokens are `pill/nopill`, `shrink/noshrink`,
`cyc/nocyc`, `breathing/nobreathing`, `link=URL/nolink`,
`popup=name/nopopup` or `popup=inline:<percent-encoded-rich-text>`, and the
numeric drawings `meter=W[/MAX]/nometer` and `spark[=MIN/MAX]/nospark`
described under [Flash extensions](#flash-extensions).
Native `range=user|name` selects a `[statusbar.click]` action. The status renderer
reserves explicit mode-pill space and notch clearance, resolves overflow (see
[Overflow and `#[shrink]`](#overflow-and-shrink)), then draws the native cell
layout. The feed marks only its title `#[shrink]`, so it folds with an ellipsis
while the domain and outbound arrow stay visible. An absolute-centre component
owns its own columns plus a small gutter, and the side lanes stop `[statusbar]
notch_margin` short of them, the same points they clear a real housing by. That
reservation is drawn as a recessed notch — the bar fill sunk slightly — tracing
the hardware outline: widest flush with the top edge, flaring inward through the
top corners rather than meeting the bezel square, straight down the sides, and
rounded at the two bottom corners. It is never narrower than the real housing (a
connected notched display's, else the 16-inch MacBook Pro's 185 pt, which is
that widest measurement) and widens to hold a longer centred label. macOS
publishes the notch rect but neither radius, so both are constants. A screen
with a physical notch hides the centre and draws no recess, since the hardware
already supplies the gap. A bar too narrow to hold both lanes and that
reservation drops the reservation instead of erasing a lane. A lane re-budget
that only contracts or clamps a carousel row keeps the row in place; the
carousel pushes vertically only for a different article. These host surfaces
do not alter format evaluation.

Bare `#{flash.mode}` references retain their identity through template and
conditional expansion. The renderer resolves their text from the current mode in
the same paint as the pill's foreground, gradient and border. A queued status
update cannot restore an earlier mode label. Mode labels and pills change
immediately and never inherit a metric's crossfade or carousel animation.
Literal text and explicitly transformed format values keep their authored
meaning.

The bar itself is a vertical gradient over the `fill` colour with a hairline
along its bottom edge; default-background cells are transparent so both show
through. Mode pills are lit from the top. A hovered `#[link]` or `#[popup]` run
gets a faint rounded wash that appears, moves, and disappears immediately.
It fits the visible text inside the narrowest interactive span, excluding
outer separator spaces while preserving the span's click and popup targets.
A whole-row popup does not wash the row while the pointer sits on one of its
links, and a span wide enough to cover most of a lane is dimmed further.
Status updates refresh the wash under a stationary pointer using the new
layout. A metric or clock value changing in place crossfades over
100 ms, short enough that a 1 Hz metric reads as a snap rather than a
smear. A carousel article change is one vertical push over 450 ms: the old
line moves a full line height up and fades out while the next rises the same
distance from below and fades in, both on the standard ease-in-out curve. All
of it runs on the render server: no host timers, no per-frame CPU work.

Inline popup identities derive from their source origin and invocation, not the
current text or screen position. A changing source value refreshes an open
popup in place; separate expansions of the same format remain distinct anchors.
The bar, hit regions, and terminal document encoder consume the same typed runs.

## Native drawing

The status bar consumes the ordered typed format document through
`StatusFormatLayout`. Its cells determine painted positions and native
closed-range hit areas, including list focus/markers, fill colors, alignment
clipping, and absolute-centre overlays. Flash resolves overflow before native
drawing ([Overflow and `#[shrink]`](#overflow-and-shrink)), so native clipping
applies only to what cannot give way further. The mode pill requires explicit
`#[pill]` metadata. It keeps the
original point-based padding and centred label, reserving the longest
configured base-mode label; the transient TERMINAL label of a focused popup
uses that same width, so focusing a popup does not shift adjacent segments.
Pill backgrounds and interaction areas share the same geometry.

Each display uses the same pooled layer renderer. Non-ASCII cells have
independent origins, so font shaping cannot shift subsequent text or
interaction rectangles away from native columns. Notched displays suppress
centre content and clip other cells and hit areas around the notch margin.
Blink and breathing effects, carousel transitions, and in-place value
crossfades run on Core Animation without a redraw timer.

`monitor = "primary"` selects the display at desktop origin `(0, 0)`. Moving
keyboard focus to another display does not move the bar or reserve status-bar
space there. `monitor = "all"` draws a bar on every display. Use
`#[align=absolute-centre]` for a label at the physical centre of the screen;
native tmux `#[align=centre]` instead centres the space remaining between the
left and right content, so unequal side widths shift that label.

## Flash extensions

Flash adds meters, sparklines, and overflow control to the tmux language. Like
`pill` or `popup=`, they are Flash-only style tokens, which tmux rejects as a
malformed marker. Every other format evaluates as in tmux, which the pinned corpus
verifies: `#{E:@name,a}` reads one option literally named `@name,a`.

### Meters and sparklines

`#[meter=W]` … `#[nometer]` replaces the enclosed text with a bar of exactly
`W` cells (1–200) drawn with eighth blocks `▏▎▍▌▋▊▉█`: the first number of the
text over `0…100`, or over `0…MAX` with `#[meter=W/MAX]` (`MAX` > 0, decimals
allowed). The value clamps to the range and rounds to the nearest eighth; the
unfilled cells are spaces, so the marker's `bg=` paints the track.
`#[spark]` … `#[nospark]` replaces every number of the enclosed text with one
of `▁▂▃▄▅▆▇█`: `floor(value / largest × 7)` by default, where `largest` is the
greatest value or 0 (an all-zero series is flat, as the Rust SDK's
`sparkline_scaled`), and over a fixed `MIN…MAX` (`MIN` < `MAX`) with
`#[spark=MIN/MAX]`, clamped.

```text
CPU #[meter=20 fg=#A3BE8C bg=#3B4252]#{flash.plugin.cpu.percent}#[nometer default] #[spark=0/100]#{flash.plugin.cpu.history}#[nospark]
```

These are style tokens: they follow the marker rules above and combine with
other tokens in one marker, and a malformed one (`meter=0`, `meter=201`,
`meter=4/0`, `spark=5`, `spark=9/1`) rejects the whole marker. Only `nometer`
ends a meter and only `nospark` a sparkline; `default` leaves them open, and a
new `meter=` or `spark` token starts a new drawing. The drawing happens once
the expanded text is parsed into runs: the enclosed runs are merged line by
line, so a number split across values or styles reads as one, and the result
takes the first run's style. Text without a number is kept unchanged, and a
drawing never crosses a line break. Numbers are ASCII decimals; a `-` is a sign
unless it follows a digit or a point. The typed runs carry the drawn text, so
serialization emits no `meter`/`spark` tokens and hit testing, layout and the
terminal document encoder see ordinary one-cell block characters. The system
monospaced font draws every block glyph at one cell.

### Overflow and `#[shrink]`

A bar wider than its screen gives way before native drawing. By default each
section — the left lane, the centre or absolute centre, the right lane — is cut
at its own end, with `…`. `#[shrink]` … `#[noshrink]` marks where to cut
instead, in any section; unmarked text keeps its width until every marked span
that could make room is down to its ellipsis:

```text
#[align=absolute-centre]#[shrink]#{flash.active_app_name}#[noshrink]
```

Both passes — the `#[shrink]` spans first, then the section tails — repeatedly
narrow the widest span that relieves an overflow, ties in template order, each
keeping at least one cell and ending in `…`. Mode pills and native list content
are never cut. The constraints are the bar width, a physical notch, and the
absolute centre's reservation: its content plus gutters, never narrower than
the housing, centred on the bar, with each side lane ending `notch_margin` short
of it. Narrowing the centre therefore frees a column for both side lanes, while
narrowing a lane frees only that lane, so a centred label uses exactly the
columns the lanes leave and needs no fixed `#{=/N/…:…}` width. A cut is always
a prefix of the full text, so a re-budget never animates as a value change.

This is an extension rather than a tmux list: an absolute-centre `#[list=on]`
is trimmed against the full width and drawn over the side lanes, keeps the part
around its focus rather than the head, and allows one list per line, so it
cannot express "fit this label between the lanes".

## Time

Time is read on its own boundaries, never polled on an interval. Each
evaluation reports the finest unit it showed: seconds when a strftime seconds
conversion (`%S`, `%T`, `%s`, `%X`, `%r`, `%c`, `%+`) was expanded; days when
only date conversions or `#{flash.calendar}` were; minutes for anything else,
including `#{flash.date}` and `t:` times. A literal `%%` is not time. The
controller wakes at the next boundary of the finest unit any visible surface
shows; a day ends at local midnight or at a daylight-saving transition inside
it. Setting the clock, a time-zone change, a new calendar day and a wake
re-plan that boundary at once. `[statusbar] interval` and a widget's
`interval` govern only `#()` jobs and named sources.

## Implementation and validation

`StatusFormatProgram` owns the shared byte lexer, nested AST, diagnostics,
source spans, dependencies, and evaluator. `StatusFormatDocument` interprets the
expanded style stream once and retains marker-only transitions.
`StatusFormatLayout` computes native cells and ranges. Production drawing uses
these typed results directly; raw string parsing is an input boundary.

A publish first captures every value, job value, and (for
time-dependent formats) the current second that the previous evaluation read
(`FlashStatusBarTemplateEngine.EvaluationInputs`); an identical capture skips
the evaluation entirely, so a 1 Hz plugin sample that changes nothing the bar
references costs one dictionary comparison. Each text popup is memoized the
same way on its own dependency set, so a changed CPU sample re-evaluates the bar
and the CPU popup, not every popup. Time- and job-dependent popups are never
memoized.

The compiler cache is bounded to 256 entries/1 MiB of source text, and the POSIX
regex cache to 128 entries/256 KiB of patterns. Evaluation limits recursion to
100 levels and retains tmux's width/repeat bounds. Repeated output is capped at
16 MiB per operation. Job output buffers retain at most 1 MiB; each read callback
drains at most 256 KiB before yielding its utility queue. Reload and quit
terminate owned process groups with one bounded batch deadline and reap their
leaders; every wait there ends on the kernel's exit events for each group's
members (`ProcessExit`), so the grace period ends as soon as the groups leave
and nothing sleeps between checks. Successful shell completion also terminates
residual group children.

Unicode is pinned to **utf8proc 2.12.0 / Unicode 18.0**, with tmux 3.7c's width
overrides. Flash's data is modified into 482 compact non-unit width intervals,
uses tmux's one-cell private-use rule, and applies the 162 tmux overrides first.
This removes macOS-version-dependent `wcwidth` results. The source-data licenses
are retained in [utf8proc-LICENSE](../Resources/utf8proc-LICENSE) and
[tmux-LICENSE](../Resources/tmux-LICENSE), and accompany app builds.

The test-only oracle bootstrap pins tmux 3.7c and statically links utf8proc
2.12.0. Each oracle uses a disposable named socket with an empty tmux config;
it does not inspect a user's live server or panes:

```sh
export TMUX_ORACLE="$(./Scripts/build-tmux-oracle.sh)"
export FLASH_REQUIRE_TMUX_ORACLE=1
python3 Scripts/test-status-format-oracle.py
swift test --filter 'FormatConformanceTests|FormatCommandJobTests|StatusFormatLayoutTests|NativeStatusBarSurfaceTests'
```

`Tests/StatusFormatFixtures/tmux-3.7c.json` stores portable native expansion
results. `Scripts/test-status-format-oracle.py --record` updates that corpus
against the pinned binary. The drawing suite independently compares final text,
cell positions, colors, and attributes against an isolated attached tmux client.
CI requires the exact stamped oracle build; production never invokes tmux.
