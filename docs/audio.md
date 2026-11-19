# Audio devices

Flash can list and select the Mac's default microphone and speaker device.
Open the Flash command bar and run:

```text
:audio input
:audio output
:audio input --device=Studio Microphone
:audio output --device=Studio Speakers
```

The list marks the current default with `*` and shows each device's UID. A
selection must match a device name or UID exactly. If names are duplicated,
use the UID; an unknown or ambiguous name is rejected.

The same commands work from a terminal and in a mapping:

```toml
[mode.all.mappings]
"cmd+alt+i" = ["flash", "audio", "input", "--device=Studio Microphone"]
"cmd+alt+o" = ["flash", "audio", "output", "--device=Studio Speakers"]
```

`flash audio input` and `flash audio output` without `--device` list the
devices. From a terminal they print the list, as `flash media status` prints
what is playing and `flash volume up` the new volume; from a mapping the list
shows in a banner. `--device=` is the only argument these commands take:
anything else fails with the command's usage.

`flash volume up` and `flash volume down` move one macOS volume-key tick, the
same 16 steps the keyboard uses between silence and full volume. A value
between ticks lands on the next tick, and the ends stay at 0% and 100%. Each
step shows an alert with `volume` above the percent, and the percent is
centred on its line. The alert leaves after 3 seconds. A NORMAL count steps
that many ticks in one move, the whole scale at most. `flash volume mute`
toggles the output's mute.

Play, pause and skip are the function-row media keys:
`key system --key=media_play`, `media_next` and `media_previous`, which
HYPER binds to `8`, `9` and `7`. `flash media status` shows what Spotify,
Music, TV and Podcasts are playing, asking only the apps already running, and
the output volume; the first time it asks an app, macOS asks whether Flash may
control it. A player that does not answer within 8 seconds, or that you
refused, is listed as `unknown`.

## The media plugin

`volume`, `audio` and `media` are the commands of the bundled `media` plugin,
a sandboxed process that holds no audio access of its own. It asks Flash,
which reads and changes the devices through CoreAudio on a background queue,
never on its keyboard path, and runs the players' AppleScript itself
([plugin isolation](privacy.md#plugin-isolation)). The plugin runs from
launch, to follow which players are running.
`[plugins] disabled = ["media"]` removes the six commands; a mapping still
bound to one then runs nothing.
