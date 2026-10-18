# Audio devices

The bundled media plugin can list and select the Mac's default microphone
and speaker device. Open the Flash command bar and run:

```text
:media input
:media output
:media input Studio Microphone
:media output Studio Speakers
```

The list marks the current default with `*` and shows each device's UID. A
selection must match a device name or UID exactly. If names are duplicated,
use the UID; an unknown or ambiguous name is rejected.

The same words are the `flash` command and a mapping:

```toml
[mode.all.mappings]
"cmd+alt+i" = ["flash", "media", "input", "Studio Microphone"]
"cmd+alt+o" = ["flash", "media", "output", "Studio Speakers"]
```

`flash media input` and `flash media output` without a device name request the
device list. Flash displays the plugin's response in its message overlay;
the CLI reports whether dispatch succeeded but does not print the list to the
terminal. For playback, volume, and mute commands, open `:plugins` and select
the media plugin.

`flash media volumeup` and `flash media volumedown` move one macOS volume-key
tick, the same 16 steps the keyboard uses between silence and full volume.
A value between ticks lands on the next tick, and the ends stay at 0% and
100%. Each step shows an alert with `volume` above the percent, and the
percent is centred on its line. The alert leaves after 3 seconds.
