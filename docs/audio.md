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

The same operations have verbs for mappings and the `flash` CLI:

```toml
[mode.all.mappings]
"cmd+alt+i" = ["flash", "media_input", "--device=Studio Microphone"]
"cmd+alt+o" = ["flash", "media_output", "--device=Studio Speakers"]
```

`flash media_input` and `flash media_output` without `--device` request the
device list. Flash displays the plugin's response in its message overlay;
the CLI reports whether dispatch succeeded but does not print the list to the
terminal. For playback, volume, and mute commands, open `:plugins` and select
the media plugin.
