# Wire conformance corpus

Two files, read by both ends of the plugin protocol:

- `host-frames.ndjson`: frames the host sends (requests, `event`
  notifications, replies to `host.*` calls).
- `plugin-frames.ndjson`: frames a plugin sends (replies, `publish`,
  `status`, `poll` and `log` notifications, `host.*` requests).

The SDK reads them in `src/conformance.rs`: host frames go through the real
serve loop and decoders, and the SDK's encoders must write the plugin frames
shown here. The host reads them in `Tests/FlashTests/PluginSchemaTests.swift`:
every line is checked against the schemas in `docs/schema/plugin/`, plugin
frames go through the host's decoders, and each `host.*` request is answered
by the real dispatcher.

Field-value rules (what counts as a pid, a boolean, a frame) stay pinned by
`../fixtures/wire-values.fixture`. This corpus pins whole frames.

## Line format

One JSON object per line:

| Key | Meaning |
| --- | --- |
| `name` | Unique within the file. Tests refer to lines by name. |
| `expect` | `accept` or `reject`: what the receiving end does with the frame. |
| `reply_to` | On a reply frame, the request method it answers. |
| `reply` | On a request, the name of the line in the other file the reference receiver answers with. |
| `schema` | `accept` or `reject`, only where the schema verdict differs from `expect`. |
| `frame` | The frame. Always the last key. |

`frame` comes last so a reader can take the frame's bytes as written: the
text after the first `, "frame": ` up to the line's final `}`. Both tests send
those bytes, not a re-encoding, so a number spelled `30.0` stays `30.0`.

`reject` means the receiver refuses the frame: a host decoder returns nothing
or throws, the SDK answers `ok: false` without running a handler (or answers
nothing, for an id it cannot reply to), and a rejected host reply reaches the
caller as `invalid host response`. A well-formed frame that reports a failure
(`{"ok": false, "error": …}`) is `accept`.

`schema` differs from `expect` in two cases. The SDK reads leniently, so a
host frame with a key or event name it does not know is `accept` while the
schema, which describes exactly what the host sends, rejects it. And some
rules need context a schema lacks (a row's source against the manifest, a
text line against its grid), so the schema accepts a frame the host rejects.

## Fixture

The lines describe one plugin and one moment:

- Plugin `example`, sources `example.items` and `example.tabs`, status
  segments `summary` and `feed`.
- Focused app `com.example.app`, pid 512, window 4021, front window
  `{x: 0, y: 25, width: 1440, height: 875}` on a 2x display.
- Wi-Fi network `Atelier`; fetch allowlist `https://api.example.com/`;
  Apple Events targets `com.apple.Safari`, `com.apple.Music`,
  `com.apple.shortcuts.events` and `com.apple.systemevents`; `https:` URLs open in `com.apple.Safari`; a script
  prints `Focus\nRest\n`.
- Output devices `MacBook Pro Speakers` (`built-in`, the default) and
  `USB Audio` (`usb-1`), the same two as inputs; the output at 38%, not
  muted. A step of two ticks lands on 50%.
- A menu-bar snapshot (`host.ax_snapshot` with `root: menu_bar`) is pinned
  as a frame and never answered here: the host would walk the menu bar of
  whichever app owns it.
- The host carries out a system action without touching the Mac; no
  confirmed perform is in flight, so a destructive one is refused.
- No process is signalled: with no confirmed perform in flight, the host
  refuses a signal to pid 4242.
- macOS grants Calendars access. From 2027-01-15 08:00 UTC (1800000000) the
  calendar holds `Standup` at 08:12 in `Work`, with a URL, the location
  `Room 4` and a Zoom link in its notes, and `Lunch` at 10:00 in `Home`.
- Only `https:` URLs have an application: `host.open` with `if_handled`
  refuses a `zoommtg:` link.
- macOS grants Notes, Reminders and Contacts access. Notes holds `Groceries`
  and `Taxes 2026`; Reminders holds `Buy milk` in `Inbox`, created at
  1800000000, and `Ship release` in `Work`; Contacts holds `Ada Lovelace`
  and `Grace Hopper`. A `show` brings no app forward.
- Evaluating `2+2` answers `4`; any other query answers nothing.
- Searching the live source `example.live` for `ro` answers two rows; any
  other query answers none. The corpus pins frames, so its one plugin answers
  for pushed and live sources alike, which no manifest may declare together.
- Command `tab next --index=3` succeeds in the focused app, `example decline`
  is unhandled, `example break` fails, `example repeat` answers its count and
  `example confirm` answers whether the user confirmed it.
- The row `Restart` of `example.items` asks `Restart this Mac?` before it is
  resolved.

Request ids are fixed per method (`initialize` 1, `ping` 2, `evaluate` 3,
`hints` 4, `text_grid` 5, `perform` 6, `search` 7); every `host.*` call is
id 1, the first call of a fresh plugin.

## Changing the wire

Add or change the corpus line first and watch both suites fail, then change
the schema, the host and the SDK together. A method added to
`protocol.json` fails both suites until it has a schema and lines here.
