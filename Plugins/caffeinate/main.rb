#!/usr/bin/env ruby
# Keep-awake control, in Ruby (one of the deliberately non-Rust official
# plugins exercising the language-agnostic wire protocol; see
# docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
#
# Owns at most one `/usr/bin/caffeinate -di` child (display + idle-sleep
# assertions); `on <minutes>` bounds it with `-t`, `off` (or stdin EOF —
# the shutdown signal, handled by the on_shutdown hook) kills it.
# caffeinate takes its power assertion through powerd, which the
# deny-default seatbelt profile cannot host — hence the unsandboxed
# `subprocess` capability shape (same as tmux/spotify). The `state` status
# segment renders through `#{plugin:caffeinate.state}` ("on"/"" so templates
# decorate it themselves).

require "flashplugin" # resolved via host-injected RUBYLIB

CAFFEINATE = "/usr/bin/caffeinate".freeze

plugin = FlashPlugin.new
child_pid = nil

alive = lambda do
  child_pid && Process.kill(0, child_pid) ? true : false
rescue Errno::ESRCH, Errno::EPERM
  false
end

stop = lambda do
  Process.kill("TERM", child_pid) if alive.call
  child_pid = nil
rescue Errno::ESRCH
  child_pid = nil
end

start = lambda do |minutes|
  stop.call
  argv = [CAFFEINATE, "-di"]
  argv += ["-t", (minutes * 60).to_s] if minutes
  child_pid = Process.spawn(*argv, in: :close, out: :close, err: :close)
  Process.detach(child_pid) # reap in the background; we only track the pid
end

emit_state = lambda do
  plugin.status("state" => alive.call ? "on" : "")
end

performed = lambda do
  FlashPlugin.ok(message: alive.call ? "caffeinate on (pid #{child_pid})" : "caffeinate off")
end

plugin.serve(
  on_command: lambda do |params|
    minutes = Integer(params["args"]&.first || "", exception: false)
    case params["subcommand"].to_s
    when "", "status"
      performed.call
    when "on"
      start.call(minutes)
      emit_state.call
      performed.call
    when "off"
      stop.call
      emit_state.call
      performed.call
    when "toggle"
      alive.call ? stop.call : start.call(minutes)
      emit_state.call
      performed.call
    else
      FlashPlugin.fail("unknown subcommand: #{params["subcommand"]}")
    end
  end,
  # stdin EOF is the shutdown signal — never orphan the assertion.
  on_shutdown: -> { stop.call },
)
