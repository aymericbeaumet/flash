# Status bar

Enable the bar independently of NORMAL mode. It occupies the top band of each
selected display; macOS's menu bar auto-hides and remains available by
reaching the top edge. Turning the Flash bar off restores the native setting
when Flash was the one that changed it.

```toml
[statusbar]
enabled = true
monitor = "all"
template = "#[align=left]#[pill]#{flash.mode}#[nopill] #{flash.focused_app_name}#[align=right]#{flash.plugin.sysinfo.cpu_summary} · %H:%M"
```

Use `monitor = "primary"` for only the primary display. The format can align
content left, center or right, set colors and attributes, and include plugin
values or your own command output. Center content yields to a physical camera
notch.

## Turn a label into an action

`#[link=URL]label#[nolink]` opens a URL. A named range binds an action:

```toml
[statusbar]
template = "#[range=user|search]Search#[norange]"

[statusbar.click]
search = ["flash", "mode", "flashlight"]
```

A link opens only `http`, `https` and `mailto` URLs. A plugin, a named
source, a `#()` job or a popup's program writes the URL, so any other scheme
is refused: a `file:` link would have macOS run what a program wrote, and a
custom scheme hands the URL to whichever app registered it. To trust one,
list it:

```toml
[statusbar]
link_schemes = ["slack", "x-apple.systempreferences"]
```

Each entry is the exact lowercase scheme name, once; the URL's own spelling
(`Slack://…`) is read case-insensitively. A refused link does nothing: the
log notes its scheme once, never the URL, and `flash resident doctor` lists
the schemes refused since launch with the setting that allows them. A
`[statusbar.click]` URL is your own configuration and opens any scheme,
like a mapping; the `$FLASH_STATUS_LINK` a [popup command](popups.md)
receives is text, not an open.

`#[popup=name]label#[nopopup]` connects a label to a [popup](popups.md).
Plugin summaries may already carry links, actions and detail popups. Inspect
the live [plugins](/plugins) page to see which are available and healthy.

Next: the [format language](status-format.md), [desktop widgets](widgets.md),
[status plugin values](status-plugins.md), and a
[complete example](examples/statusbar/README.md).
