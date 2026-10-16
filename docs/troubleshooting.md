# Troubleshooting

- **Start with `flash doctor`.** It checks permissions, key capture, secure
  input, your configuration, hotkeys taken by other apps, and plugins.
- **No hints at all.** Check that Flash is enabled under Accessibility and
  that a hotkey is mapped. Then see `~/Library/Logs/Flash/flash.log`.
- **Hints stopped after an update.** An ad-hoc signed build (the nightly
  cask) can lose the Accessibility grant after `brew upgrade` while the toggle
  still shows as on. Remove Flash from the list with **−** and add it again.
  Notarized releases keep the grant.
- **Missing or misplaced hints in one app.** Set
  `[debug] show_hints_bounds = true` to draw what Flash sees, and please
  [open an issue](https://github.com/aymericbeaumet/flash/issues) with the app
  name and version.
- **A hotkey does nothing.** Another app may own it; `flash doctor` lists
  refused hotkeys. Flash reports invalid mappings when you save the file.
- **Hints ignore your keys under a non-Latin input source.** Set
  `[app] keyboard_layout = "auto"` (the default) or name a layout explicitly.

