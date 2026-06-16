use flash_plugin::run;

// The whole point of `default-keystrokes` is the manifest's `inline_keystrokes`
// table: the host translates each declared verb into `input.send_key` directly,
// without ever calling into this process. The plugin is loaded so the manifest
// declarations stay live, but no handler runs — every trait method keeps its
// default. Future verbs that need conditional logic (a per-bundle override
// table, or a force-flag variant) can plug a real `on_command` in here without
// disturbing the inline-keystroke fast path.
struct DefaultKeystrokes;

flash_plugin::plugin!(DefaultKeystrokes);

impl FlashPlugin for DefaultKeystrokes {}

fn main() {
    run(DefaultKeystrokes);
}
