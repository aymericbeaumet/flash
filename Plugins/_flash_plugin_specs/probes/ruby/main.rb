#!/usr/bin/env ruby
# Conformance probe, in Ruby. See ../README.md — the normative behavior
# contract all seven per-language probes follow. Test fixture only: driven by
# Scripts/plugin-protocol-spec.py --probes, never shipped.

require "flashplugin" # resolved via host-injected RUBYLIB
require "json"

SOURCE = "conformance.items"
TARGET_PID = 4242

plugin = FlashPlugin.new
last_event = ""

# Compact JSON (JSON.generate keeps non-ASCII raw) — the message-field encoder.
j = ->(value) { JSON.generate(value) }

conformance_config = lambda do
  section = FlashPlugin.config["conformance"]
  section.is_a?(Hash) ? section : {}
end

catalog = lambda do
  conf = conformance_config.call
  return [] if conf["empty_catalog"] == true
  if (count = conf["catalog_rows"]).is_a?(Integer)
    pad = "x" * (conf["row_pad"].to_i)
    return (1..count).map { |i| { "source" => SOURCE, "title" => "row-#{i}#{pad}" } }
  end
  [
    { "source" => SOURCE, "title" => "alpha", "metadata" => { "k" => "v1" } },
    { "source" => SOURCE, "title" => "béta ⚡ 名前" },
    { "source" => SOURCE, "title" => "gamma", "url" => "https://example.com/g",
      "effect" => { "type" => "open", "url" => "https://example.com/g" } },
  ]
end

answer = lambda do |title, subtitle = nil|
  out = { "title" => title }
  out["subtitle"] = subtitle if subtitle
  out["effect"] = { "type" => "copy_text", "text" => title }
  out
end

arg = ->(args, index, default = "") { index < args.length ? args[index] : default }
int_arg = lambda do |args, index, default|
  Integer(arg.call(args, index), 10)
rescue ArgumentError, TypeError
  default
end

# subcommand -> [host method, params builder over args]
host_arms = {
  "ping" => ["host.ping", ->(_) { {} }],
  "fetch" => ["host.fetch", ->(args) { { "url" => arg.call(args, 0) } }],
  "open" => ["host.open", ->(args) { { "url" => arg.call(args, 0) } }],
  "clipboard" => ["host.clipboard_write", ->(args) { { "text" => arg.call(args, 0) } }],
  "notify" => ["host.notify", ->(args) { { "message" => arg.call(args, 0) } }],
  "storage-set" => ["host.storage_set",
                    ->(args) { { "key" => arg.call(args, 0), "value" => arg.call(args, 1) } }],
  "storage-get" => ["host.storage_get", ->(args) { { "key" => arg.call(args, 0) } }],
  "media" => ["host.post_media_key", ->(args) { { "key_code" => int_arg.call(args, 0, 16) } }],
  "ps" => ["host.process_table", ->(_) { {} }],
  "signal" => ["host.signal", ->(args) { { "pid" => int_arg.call(args, 0, TARGET_PID) } }],
  "keys" => ["host.post_keys",
             ->(_) { { "pid" => TARGET_PID, "keys" => [{ "key_code" => 4, "modifiers" => ["command"] }] } }],
  "global-key" => ["host.post_global_key", ->(_) { { "key_code" => 4, "modifiers" => ["command"] } }],
  "ax-snapshot" => ["host.ax_snapshot", ->(_) { { "pid" => TARGET_PID, "roots" => "app" } }],
  "activate" => ["host.activate", ->(_) { { "pid" => TARGET_PID } }],
  "normal-mode-target" => ["host.normal_mode_target", ->(_) { {} }],
}

plugin.serve(
  on_start: lambda do
    plugin.publish(catalog.call) unless conformance_config.call["skip_publish"] == true
  end,
  on_event: ->(name, _payload) { last_event = name },
  on_evaluate: lambda do |params|
    case params["query"] || ""
    when "conf:one" then [answer.call("one", "s")]
    when "conf:unicode" then [answer.call("héllo ⚡ 世界")]
    when "conf:many" then (1..17).map { |i| answer.call("a#{i}") }
    else []
    end
  end,
  on_search: lambda do |params|
    query = params["query"] || ""
    catalog.call.select { |row| row["title"].include?(query) }
  end,
  on_hints: lambda do |_params|
    [
      { "id" => "t1", "frame" => { "x" => -10.5, "y" => 20, "width" => 30, "height" => 40 },
        "role" => "AXLink", "label" => "one" },
      { "id" => "t2", "frame" => { "x" => 0, "y" => 0, "width" => 10, "height" => 10 },
        "role" => "FlashTerminalLink", "label" => "two" },
    ]
  end,
  on_resolve: lambda do |params|
    row = params["row"] || {}
    row["title"] == "alpha" ? FlashPlugin.ok(target_pid: TARGET_PID) : FlashPlugin.unhandled
  end,
  on_action: lambda do |params|
    case params["name"] || ""
    when "conf_performed" then FlashPlugin.ok(target_pid: TARGET_PID)
    when "conf_failed" then FlashPlugin.fail("conformance failure probe")
    else FlashPlugin.unhandled
    end
  end,
  on_navigate: lambda do |params|
    params["url"] == "conformance://ok" ? FlashPlugin.ok : FlashPlugin.unhandled
  end,
  on_command: lambda do |params|
    subcommand = params["subcommand"] || ""
    args = (params["args"] || []).map(&:to_s)
    case subcommand
    when "echo"
      FlashPlugin.ok(message: j.call({ "args" => args, "raw" => params["raw"] || "" }))
    when "env"
      FlashPlugin.ok(message: j.call(ENV.to_h))
    when "env-has"
      FlashPlugin.ok(message: ENV.key?(arg.call(args, 0)) ? "present" : "absent")
    when "config"
      FlashPlugin.ok(message: j.call(FlashPlugin.config))
    when "state"
      FlashPlugin.ok(message: last_event)
    when "target-pid"
      FlashPlugin.ok(target_pid: TARGET_PID)
    when "toast"
      FlashPlugin.ok(message: "hello from conformance")
    when "sleep"
      sleep(int_arg.call(args, 0, 0) / 1000.0)
      FlashPlugin.ok
    when "crash"
      exit!(int_arg.call(args, 0, 1))
    when "exit-after-reply"
      code = int_arg.call(args, 0, 0)
      Thread.new do
        sleep(0.25)
        exit!(code)
      end
      FlashPlugin.ok
    when "stderr"
      $stderr.write("x" * (int_arg.call(args, 0, 0) * 1024))
      $stderr.flush
      FlashPlugin.ok
    when "log"
      plugin.log(arg.call(args, 0, "info"), args[1..].to_a.join(" "))
      FlashPlugin.ok
    when "status"
      plugin.status({ arg.call(args, 0) => arg.call(args, 1) })
      FlashPlugin.ok
    when "publish-extra"
      plugin.publish(catalog.call + [{ "source" => SOURCE, "title" => "delta" }])
      FlashPlugin.ok
    else
      if (armed = host_arms[subcommand])
        method, build = armed
        FlashPlugin.ok(message: j.call(plugin.call_host(method, build.call(args))))
      else
        FlashPlugin.fail("unsupported subcommand: #{subcommand}")
      end
    end
  end,
  on_shutdown: -> { plugin.log("info", "conformance shutdown") },
)
