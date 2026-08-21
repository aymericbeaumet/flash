// Conformance probe, in TypeScript on Bun. See ../README.md — the normative
// behavior contract all seven per-language probes follow. Test fixture only:
// driven by Scripts/plugin-protocol-spec.py --probes, never shipped.

import {
  Plugin,
  config,
  fail,
  ok,
  unhandled,
  type Answer,
  type Reply,
  type Row,
  type Value,
} from "flashplugin"; // resolved via host-injected NODE_PATH

const SOURCE = "conformance.items";
const TARGET_PID = 4242;

let lastEvent = "";

// Compact JSON (JSON.stringify keeps non-ASCII raw) — the message encoder.
const j = (value: unknown): string => JSON.stringify(value) ?? "null";

function conformanceConfig(): { [key: string]: Value } {
  const section = config().conformance;
  return section !== null && typeof section === "object" && !Array.isArray(section)
    ? section
    : {};
}

function catalog(): Row[] {
  const conf = conformanceConfig();
  if (conf.empty_catalog === true) return [];
  if (typeof conf.catalog_rows === "number") {
    const pad = "x".repeat(typeof conf.row_pad === "number" ? conf.row_pad : 0);
    return Array.from({ length: conf.catalog_rows }, (_, i) => ({
      source: SOURCE,
      title: `row-${i + 1}${pad}`,
    }));
  }
  return [
    { source: SOURCE, title: "alpha", metadata: { k: "v1" } },
    { source: SOURCE, title: "béta ⚡ 名前" },
    {
      source: SOURCE,
      title: "gamma",
      url: "https://example.com/g",
      effect: { type: "open", url: "https://example.com/g" },
    },
  ];
}

function answer(title: string, subtitle?: string): Answer {
  const out: Answer = { title, effect: { type: "copy_text", text: title } };
  if (subtitle !== undefined) out.subtitle = subtitle;
  return out;
}

const arg = (args: string[], index: number, fallback = ""): string =>
  index < args.length ? args[index] : fallback;

const intArg = (args: string[], index: number, fallback: number): number => {
  const parsed = parseInt(arg(args, index), 10);
  return Number.isNaN(parsed) ? fallback : parsed;
};

// subcommand -> [host method, params builder over args]
const hostArms: { [sub: string]: [string, (args: string[]) => Value] } = {
  ping: ["host.ping", () => ({})],
  fetch: ["host.fetch", (args) => ({ url: arg(args, 0) })],
  open: ["host.open", (args) => ({ url: arg(args, 0) })],
  clipboard: ["host.clipboard_write", (args) => ({ text: arg(args, 0) })],
  notify: ["host.notify", (args) => ({ message: arg(args, 0) })],
  "storage-set": [
    "host.storage_set",
    (args) => ({ key: arg(args, 0), value: arg(args, 1) }),
  ],
  "storage-get": ["host.storage_get", (args) => ({ key: arg(args, 0) })],
  media: ["host.post_media_key", (args) => ({ key_code: intArg(args, 0, 16) })],
  ps: ["host.process_table", () => ({})],
  signal: ["host.signal", (args) => ({ pid: intArg(args, 0, TARGET_PID) })],
  keys: [
    "host.post_keys",
    () => ({ pid: TARGET_PID, keys: [{ key_code: 4, modifiers: ["command"] }] }),
  ],
  "global-key": ["host.post_global_key", () => ({ key_code: 4, modifiers: ["command"] })],
  "ax-snapshot": ["host.ax_snapshot", () => ({ pid: TARGET_PID, roots: "app" })],
  activate: ["host.activate", () => ({ pid: TARGET_PID })],
  "normal-mode-target": ["host.normal_mode_target", () => ({})],
};

const plugin: Plugin = new Plugin({
  onStart() {
    if (conformanceConfig().skip_publish === true) return;
    plugin.publish(catalog());
  },
  onEvent(name) {
    lastEvent = name;
  },
  onEvaluate(params) {
    switch (params.query ?? "") {
      case "conf:one":
        return [answer("one", "s")];
      case "conf:unicode":
        return [answer("héllo ⚡ 世界")];
      case "conf:many":
        return Array.from({ length: 17 }, (_, i) => answer(`a${i + 1}`));
      default:
        return [];
    }
  },
  onSearch(params) {
    const query = typeof params.query === "string" ? params.query : "";
    return catalog().filter((row) => row.title.includes(query));
  },
  onHints() {
    return [
      {
        id: "t1",
        frame: { x: -10.5, y: 20, width: 30, height: 40 },
        role: "AXLink",
        label: "one",
      },
      {
        id: "t2",
        frame: { x: 0, y: 0, width: 10, height: 10 },
        role: "FlashTerminalLink",
        label: "two",
      },
    ];
  },
  onResolve(params) {
    const row = (params.row ?? {}) as { [key: string]: Value };
    return row.title === "alpha" ? ok({ target_pid: TARGET_PID }) : unhandled();
  },
  onAction(params) {
    switch (params.name ?? "") {
      case "conf_performed":
        return ok({ target_pid: TARGET_PID });
      case "conf_failed":
        return fail("conformance failure probe");
      default:
        return unhandled();
    }
  },
  onNavigate(params) {
    return params.url === "conformance://ok" ? ok() : unhandled();
  },
  async onCommand(params): Promise<Reply> {
    const subcommand = typeof params.subcommand === "string" ? params.subcommand : "";
    const args = Array.isArray(params.args) ? params.args.map(String) : [];
    switch (subcommand) {
      case "echo":
        return ok({ message: j({ args, raw: params.raw ?? "" }) });
      case "env":
        return ok({ message: j(process.env) });
      case "env-has":
        return ok({ message: arg(args, 0) in process.env ? "present" : "absent" });
      case "config":
        return ok({ message: j(config()) });
      case "state":
        return ok({ message: lastEvent });
      case "target-pid":
        return ok({ target_pid: TARGET_PID });
      case "toast":
        return ok({ message: "hello from conformance" });
      case "sleep":
        await new Promise((resolve) => setTimeout(resolve, intArg(args, 0, 0)));
        return ok();
      case "crash":
        process.exit(intArg(args, 0, 1));
      case "exit-after-reply": {
        const code = intArg(args, 0, 0);
        setTimeout(() => process.exit(code), 250);
        return ok();
      }
      case "stderr":
        await Bun.write(Bun.stderr, "x".repeat(intArg(args, 0, 0) * 1024));
        return ok();
      case "log":
        plugin.log(arg(args, 0, "info"), args.slice(1).join(" "));
        return ok();
      case "status":
        plugin.status({ [arg(args, 0)]: arg(args, 1) });
        return ok();
      case "publish-extra":
        plugin.publish([...catalog(), { source: SOURCE, title: "delta" }]);
        return ok();
      default: {
        const armed = hostArms[subcommand];
        if (!armed) return fail(`unsupported subcommand: ${subcommand}`);
        const [method, build] = armed;
        return ok({ message: j(await plugin.callHost(method, build(args))) });
      }
    }
  },
  onShutdown() {
    plugin.log("info", "conformance shutdown");
  },
});

await plugin.serve();
