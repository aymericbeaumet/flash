use flash_plugin::run;

// The whole point of `defaults` today is the manifest's `inline_keystrokes`
// table: the host translates each declared verb into a core keystroke action,
// without ever calling into this process. The plugin is loaded so the manifest
// declarations stay live, but no handler runs. Future default-layer behavior
// that belongs in plugins can land here without hard-coding it in the host.
struct Defaults;

flash_plugin::plugin!(Defaults);

impl FlashPlugin for Defaults {}

fn main() {
    run(Defaults);
}
