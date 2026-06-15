use flash_plugin::run;

// Safari exposes no candidates or hints of its own; it exists purely to
// register the manifest mapping that overrides the built-in hard-refresh
// binding (`R`) while Safari is focused. Safari's "Reload Page From Origin"
// is ⌘⌥R, not the ⌘⇧R that Firefox/Chrome use, so the manifest rebinds `R`
// to `["flash", "send_key", "keys=cmd+option+r"]` at plugin priority (above
// the config default). The process just idles so the host keeps the mapping
// live.
struct Safari;

flash_plugin::plugin!(Safari);

// No providers drive a handler — the manifest mapping is all Safari needs — so
// every trait method keeps its default.
impl FlashPlugin for Safari {}

fn main() {
    run(Safari);
}
