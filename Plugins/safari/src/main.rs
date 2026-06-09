use flash_plugin::{run, CommandResponse, Context, Plugin, Request, Response};

// Safari exposes no candidates or hints of its own; it exists purely to
// register the manifest mapping that overrides the built-in hard-refresh
// binding (`R`) while Safari is focused. Safari's "Reload Page From Origin"
// is ⌘⌥R, not the ⌘⇧R that Firefox/Chrome use, so the manifest rebinds `R`
// to `flash://send_key?keys=cmd+option+r` at plugin priority (above the
// config default). The process just idles so the host keeps the mapping live.
struct Safari;

impl Plugin for Safari {
    async fn handle(&self, _ctx: Context, _request: Request) -> Response {
        CommandResponse::error("unsupported request").into()
    }
}

fn main() {
    run(Safari);
}
