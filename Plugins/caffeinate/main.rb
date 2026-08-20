#!/usr/bin/env ruby
# Keep-awake control, in Ruby (one of the deliberately non-Rust official
# plugins exercising the language-agnostic wire protocol; see
# docs/plugin-protocol.md and AGENTS.md — Rust stays the default).
#
# Owns at most one `/usr/bin/caffeinate -di` child (display + idle-sleep
# assertions); `on <minutes>` bounds it with `-t`, `off`/shutdown kill it.
# caffeinate takes its power assertion through powerd, which the
# deny-default seatbelt profile cannot host — hence the unsandboxed
# `subprocess` capability shape (same as tmux/spotify). The `state` status
# segment renders through `#{plugin:caffeinate.state}` ("on"/"" so templates
# decorate it themselves).

require_relative "../_ruby_flash_plugin/flashplugin"

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
  plugin.emit_status_segments("state" => alive.call ? "on" : "")
end

status_result = lambda do
  { "ok" => true, "stdout" => alive.call ? "caffeinate on (pid #{child_pid})" : "caffeinate off" }
end

plugin.serve do |params|
  minutes = Integer(params["args"]&.first || "", exception: false)
  case params["subcommand"].to_s
  when "", "status"
    status_result.call
  when "on"
    start.call(minutes)
    emit_state.call
    status_result.call
  when "off"
    stop.call
    emit_state.call
    status_result.call
  when "toggle"
    alive.call ? stop.call : start.call(minutes)
    emit_state.call
    status_result.call
  else
    { "ok" => false, "error" => "unknown subcommand: #{params["subcommand"]}" }
  end
end

# serve returned: host shutdown or stdin EOF — never orphan the assertion.
stop.call
