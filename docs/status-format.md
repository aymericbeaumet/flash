# Status format language

Flash uses the tmux **3.7b** format and style language, with values supplied by
Flash. `statusbar.template` and named document popups share one compiler. There
is no tmux runtime dependency, tmux configuration import, or implicit connection
to a tmux server. Terminal popup commands have a separate lifetime; see
[terminal popups](terminal-popups.md).

## Authoring

Compose a short template with native user options when fragments improve clarity:

```toml
[statusbar]
enabled = true
template = "#[align=left]#{E:@left}#[align=right]#{T:@right}"

[statusbar.options]
"@left" = "#[pill]#{flash.mode}#[nopill] · #{flash.active_app_name}"
"@right" = "#{flash.plugin.cpu.summary} · %H:%M"
```

`#{@left}` inserts an option value. `#{E:@left}` additionally expands that value
as a format; `#{T:@left}` enables time expansion too. Options are optional: the
same format may be written directly in `template`. Values are strings, including
native option names supplied explicitly in `[statusbar.options]`.

Outer bar templates remove newlines for readable TOML. Named document popups
preserve their interior newlines. Style and alignment markers are interpreted
**after** format expansion, so a conditional or option can select an entire
styled/aligned section. Ordinary value substitution does not recursively execute
formats or jobs from the value; intentional re-expansion uses `E:` or `T:`.
Rich plugin/source values may still contain styles, links, and popup markers.

The outer format performs native `strftime` expansion. Write `%%` for a literal
percent sign in authored templates; text inserted through an ordinary value is
not time-expanded. This also matters when authoring percent-encoded inline popup
bodies directly in a template. Plugin-supplied inline bodies arrive as values.

## Native language coverage

The compatibility baseline follows the `format.c`, `style.c`, `format-draw.c`,
`colour.c`, and `utf8.c` implementations at the upstream `3.7b` tag. The matrix
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
| Width/pad styles | Native `width=` and `pad=` parse and retain their state; tmux 3.7b status drawing does not consume these fields | Explicit inert-style oracle cases |

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
`flash.active_bundle_identifier`, `flash.plugin.<id>.<segment>`,
`flash.plugin.loaded_count`, `flash.plugin.ready_count`,
`flash.plugin.error_count`, and `flash.source.<name>`. Host/user/process values
and the process environment are available through ordinary lookup.

Flash has no implicit tmux session, window, pane, client, or pane-history
inventory. Their missing values expand to empty strings, loops over absent
collections produce no text, and name/pane searches return `0`. The pure
`StatusFormatContext` accepts explicit record collections and pane lines to
exercise those language operations. Context absence is distinct from a rejected
format operator. Native options exist when provided by Flash configuration;
there is no hidden tmux option/default database.

## Jobs, sources, and Flash styles

Native `#()` invokes `/bin/sh -c` asynchronously using Flash's environment. The
original command identifies its cached output; changing its expanded command
restarts the job while the previous output remains available. The latest complete
line is published while running, and a final partial line is accepted on exit.
Output is re-expanded as a format with nested jobs and extra time expansion
disabled. Output updates are coalesced to at most once per second. A new job with
no output can show tmux's not-ready text. Repeated executions follow Flash's
status refresh cadence.

For explicit argv, an independent cadence, environment, working directory, or
rotating lines, declare a source:

```toml
[statusbar.options]
"@right" = "#{flash.source.news}"

[statusbar.sources.news]
command = ["./news.sh"]
interval = 300
cycle_interval = 60
```

Only evaluated source references start jobs. A source interval of zero runs
once; `cycle_interval` rotates the latest successful nonempty lines independently
and marks their typed runs for crossfade. Failed/empty named source output keeps
the last good value. Named sources use the configured timeout; native shell jobs
and PTYs do not inherit that timeout. Paths follow the defining configuration
file, with `~` and environment expansion at execution.

The additional style tokens are `pill/nopill`, `shrink/noshrink`,
`cyc/nocyc`, `breathing/nobreathing`, `link=URL/nolink`, and
`popup=name/nopopup` or `popup=inline:<percent-encoded-rich-text>`.
Native `range=user|name` selects a `[statusbar.click]` action. The status renderer
reserves explicit mode-pill space and notch clearance, then draws the native
cell layout. Elastic `#[shrink]` spans in the left lane reserve any fixed suffix
and stop before the notch or an absolute-centre component. The feed uses this
for title-only ellipsis with an always-visible outbound arrow. These host
surfaces do not alter format evaluation.

Inline popup identities derive from their source origin and invocation, not the
current text or screen position. A changing source value refreshes an open
popup in place; separate calls to the same fragment remain distinct anchors.
The bar, hit regions, and terminal document encoder consume the same typed runs.

## Implementation and validation

`StatusFormatProgram` owns the shared byte lexer, nested AST, diagnostics,
source spans, dependencies, and evaluator. `StatusFormatDocument` interprets the
expanded style stream once and retains marker-only transitions.
`StatusFormatLayout` computes native cells and ranges. Production drawing uses
these typed results directly; raw string parsing is an input boundary.

The compiler cache is bounded to 256 entries/1 MiB of source text, and the POSIX
regex cache to 128 entries/256 KiB of patterns. Evaluation limits recursion to
100 levels and retains tmux's width/repeat bounds. Repeated output is capped at
16 MiB per operation. Job output buffers retain at most 1 MiB; each read callback
drains at most 256 KiB before yielding its utility queue. Reload and quit
terminate owned process groups with one bounded batch deadline and reap their
leaders. Successful shell completion also terminates residual group children.

Unicode is pinned to **utf8proc 2.11.3 / Unicode 17.0**, with tmux 3.7b's width
overrides. Flash's data is modified into 472 compact non-unit width intervals,
uses tmux's one-cell private-use rule, and applies the 162 tmux overrides first.
This removes macOS-version-dependent `wcwidth` results. The source-data licenses
are retained in [utf8proc-LICENSE](../Resources/utf8proc-LICENSE) and
[tmux-LICENSE](../Resources/tmux-LICENSE), and accompany app builds.

The test-only oracle bootstrap pins tmux 3.7b and statically links utf8proc
2.11.3. Each oracle uses a disposable named socket with an empty tmux config;
it does not inspect a user's live server or panes:

```sh
export TMUX_ORACLE="$(./Scripts/build-tmux-oracle.sh)"
export FLASH_REQUIRE_TMUX_ORACLE=1
python3 Scripts/test-status-format-oracle.py
swift test --filter 'FormatConformanceTests|FormatCommandJobTests|StatusFormatLayoutTests|NativeStatusBarSurfaceTests'
```

`Tests/StatusFormatFixtures/tmux-3.7b.json` stores portable native expansion
results. `Scripts/test-status-format-oracle.py --record` updates that corpus
against the pinned binary. The drawing suite independently compares final text,
cell positions, colors, and attributes against an isolated attached tmux client.
CI requires the exact stamped oracle build; production never invokes tmux.
