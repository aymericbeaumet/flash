# Shared Flash plugin SDK for Ruby (stdlib only) — no Flash business
# concepts, mirroring the Rust `flash_plugin` crate's role for Ruby plugins.
# Plugins require it by bare module name — the host (and the spec runner)
# inject RUBYLIB pointing at this directory at spawn, so the same require
# works from the checkout, the staged release bundle, and third-party roots:
#
#   require "flashplugin"
#
# Speaks the wire contract from docs/plugin-protocol.md (constants pinned by
# Plugins/_flash_plugin_specs/protocol.json): protocol v1, UTF-8 NDJSON over
# stdio, 10 MiB line cap both directions. Frame triage: id+method is a host
# request, id alone resolves a call_host pending, method alone is a
# notification. Registration is keyword args of lambdas on serve():
#
#   FlashPlugin.new.serve(on_start: -> {}, on_command: ->(params) {}, ...)
#
# `perform` routes by kind to on_resolve/on_command/on_action/on_navigate;
# those hooks return replies built with the class-level helpers
# FlashPlugin.ok(**fields)/FlashPlugin.unhandled/FlashPlugin.fail(msg)
# (class-level because a top-level `fail` would shadow Kernel#fail).
# on_hints returns either a target array or {"targets" => [...],
# "context_pid" => pid} — the SDK wraps both as {"ok" => true, "targets" =>
# [...]}. Hook errors never break the wire: request hooks answer
# fail("<method> hook failed") (evaluate answers empty — evaluators never
# error), lifecycle hooks log and continue. stdin EOF is the shutdown
# signal: on_shutdown runs, serve returns, the process exits 0. call_host
# never raises and never returns nil — timeouts and host death arrive as
# {"ok" => false, "error" => ...} results.

require "json"

# ── constants ──────────────────────────────────────────────────────────────

PROTOCOL_VERSION = 1
MAX_FRAME_BYTES = 10 * 1024 * 1024 # NDJSON line cap, both directions
HOST_CALL_TIMEOUT_MS = 5000

ERR_FRAME_OVERFLOW = "response exceeded outbound frame limit"
ERR_HOST_CLOSED = "host closed stdin"
ERR_HOST_TIMEOUT = "host call timed out"

# Blocking single-threaded plugin runtime — fully conformant: pings never
# race in-flight requests, so no locks and one write path.
class FlashPlugin
  PERFORM_KINDS = %w[resolve command action navigate].freeze
  TIMEOUT = Object.new  # read_line sentinel: deadline passed before a line
  AWAITING = Object.new # call_host sentinel: reply not yet received

  # ── reply helpers ────────────────────────────────────────────────────────

  def self.ok(**fields) = { "ok" => true }.merge(fields.transform_keys(&:to_s))

  def self.unhandled = { "ok" => false, "unhandled" => true }

  def self.fail(message) = { "ok" => false, "error" => message }

  # ── config / env accessors ───────────────────────────────────────────────

  # The hash parsed once from FLASH_PLUGIN_CONFIG ({} when unset/invalid).
  def self.config
    @config ||= begin
      parsed = JSON.parse(ENV.fetch("FLASH_PLUGIN_CONFIG", ""))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end

  # The plugin's writable data directory; never defaults (a silent "." would
  # scatter state into whatever cwd the plugin happened to spawn in).
  def self.data_dir
    dir = ENV["FLASH_PLUGIN_DATA_DIR"]
    raise "FLASH_PLUGIN_DATA_DIR is not set" if dir.nil? || dir.empty?
    dir
  end

  def initialize
    $stdin.binmode
    $stdout.binmode
    $stdout.sync = true
    @buf = String.new(encoding: Encoding::BINARY)
    @skipping = false # inside an oversized inbound line
    @next_id = 0
    @pending = {} # call_host id -> AWAITING | host result
    @hooks = {}
    @initialized = false
    @done = false
  end

  # ── framing ──────────────────────────────────────────────────────────────

  # The single write path: one JSON object, one line, flushed ($stdout.sync).
  # Returns false when the encoded frame exceeds the outbound cap.
  private def send_frame(obj)
    data = JSON.generate(obj)
    return false if data.bytesize > MAX_FRAME_BYTES
    $stdout.write(data + "\n")
    true
  rescue Errno::EPIPE, IOError
    @done = true # host is gone; stdin EOF follows
    true
  end

  private def respond(id, result)
    return if send_frame("id" => id, "result" => result)
    send_frame("id" => id, "result" => FlashPlugin.fail(ERR_FRAME_OVERFLOW))
  end

  private def notify(method, params)
    send_frame("method" => method, "params" => params) # oversized: dropped
  end

  # The next in-cap line (newline stripped), nil at EOF, or TIMEOUT once
  # `deadline` (monotonic seconds) passes. Oversized lines are discarded
  # chunk by chunk — never buffered whole — and the stream self-heals at the
  # next newline.
  private def read_line(deadline = nil)
    loop do
      nl = @buf.index("\n")
      if nl
        line = @buf.slice!(0..nl).chomp
        if @skipping
          @skipping = false # tail of an oversized line
        elsif line.bytesize <= MAX_FRAME_BYTES
          return line.force_encoding(Encoding::UTF_8)
        end
        next
      end
      if @skipping || @buf.bytesize > MAX_FRAME_BYTES
        @buf.clear
        @skipping = true
      end
      if deadline
        remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
        return TIMEOUT if remaining <= 0 || IO.select([$stdin], nil, nil, remaining).nil?
      end
      begin
        @buf << $stdin.sysread(65_536)
      rescue EOFError, IOError, Errno::EBADF
        return nil if @buf.empty? || @skipping
        line = @buf.dup # a valid unterminated tail still parses
        @buf.clear
        return line.force_encoding(Encoding::UTF_8)
      end
    end
  end

  # ── pending map / call_host ──────────────────────────────────────────────

  # Blocking plugin→host RPC: sends the request, then pumps the read loop
  # (dispatching interleaved host traffic) until the reply, the deadline, or
  # EOF. Never raises and never returns nil — timeouts and host death arrive
  # as {"ok" => false, "error" => ...} result objects.
  def call_host(method, params = {}, timeout_ms: HOST_CALL_TIMEOUT_MS)
    id = (@next_id += 1)
    return FlashPlugin.fail(ERR_HOST_CLOSED) if @done
    @pending[id] = AWAITING
    unless send_frame("id" => id, "method" => method, "params" => params)
      @pending.delete(id)
      return FlashPlugin.fail(ERR_FRAME_OVERFLOW)
    end
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout_ms / 1000.0
    while @pending[id].equal?(AWAITING) && !@done
      line = read_line(deadline)
      break if line.equal?(TIMEOUT)
      line.nil? ? handle_eof : dispatch_line(line)
    end
    result = @pending.delete(id)
    if result.equal?(AWAITING) || result.nil?
      return FlashPlugin.fail(@done ? ERR_HOST_CLOSED : ERR_HOST_TIMEOUT)
    end
    result.is_a?(Hash) ? result : FlashPlugin.fail("malformed host reply")
  end

  private def handle_eof
    @done = true
    @pending.each_key do |id|
      @pending[id] = FlashPlugin.fail(ERR_HOST_CLOSED) if @pending[id].equal?(AWAITING)
    end
  end

  # ── dispatch ─────────────────────────────────────────────────────────────

  private def dispatch_line(line)
    msg = JSON.parse(line) rescue nil # wire noise is dropped, never fatal
    return unless msg.is_a?(Hash)
    id = msg["id"]
    method = msg["method"]
    if method && id # host→plugin request
      handle_request(id, method, msg["params"] || {})
    elsif id # response to one of our call_host requests
      @pending[id] = msg["result"] if @pending[id]&.equal?(AWAITING)
    elsif method == "event" # notification; unknown methods are ignored
      hook = @hooks[:on_event]
      return unless hook
      params = msg["params"] || {}
      begin
        hook.call(params["name"].to_s, params["payload"])
      rescue StandardError
        log("error", "event hook failed")
      end
    end
  end

  # ── handler registry ─────────────────────────────────────────────────────

  private def handle_request(id, method, params)
    case method
    when "initialize"
      handle_initialize(id, params)
    when "ping"
      respond(id, FlashPlugin.ok)
    when "evaluate"
      hook = @hooks[:on_evaluate]
      answers = begin
        hook ? hook.call(params) : []
      rescue StandardError
        [] # evaluators are additive, never error paths
      end
      respond(id, FlashPlugin.ok(answers:))
    when "search"
      hook = @hooks[:on_search]
      begin
        respond(id, FlashPlugin.ok(rows: hook ? hook.call(params) : []))
      rescue StandardError
        respond(id, FlashPlugin.fail("search hook failed"))
      end
    when "hints"
      respond(id, hints_reply(params))
    when "perform"
      respond(id, perform_reply(params))
    else
      respond(id, FlashPlugin.fail("unknown method: #{method}"))
    end
  end

  private def handle_initialize(id, params)
    host_version = params["protocol_version"]
    if host_version != PROTOCOL_VERSION
      respond(id, "ok" => false, "protocol_version" => PROTOCOL_VERSION,
                  "error" => "protocol version mismatch: host v#{host_version}," \
                             " plugin v#{PROTOCOL_VERSION}")
      exit 0 # terminal: reply already flushed; host parks us in failed
    end
    if @initialized
      respond(id, FlashPlugin.fail("initialize may only be called once"))
      return
    end
    @initialized = true
    respond(id, "ok" => true, "protocol_version" => PROTOCOL_VERSION)
    begin
      @hooks[:on_start]&.call # after the reply, per contract
    rescue StandardError
      log("error", "start hook failed")
    end
  end

  private def hints_reply(params)
    hook = @hooks[:on_hints]
    return FlashPlugin.ok(targets: []) unless hook
    reply = begin
      hook.call(params)
    rescue StandardError
      return FlashPlugin.fail("hints hook failed")
    end
    if reply.is_a?(Hash) # {"targets" => [...], "context_pid" => pid}
      { "ok" => true }.merge(reply.transform_keys(&:to_s))
    else
      FlashPlugin.ok(targets: reply || [])
    end
  end

  private def perform_reply(params)
    kind = params["kind"]
    return FlashPlugin.fail("unknown perform kind: #{kind}") unless PERFORM_KINDS.include?(kind)
    hook = @hooks[:"on_#{kind}"]
    return FlashPlugin.unhandled unless hook
    reply = begin
      hook.call(params)
    rescue StandardError
      return FlashPlugin.fail("perform hook failed") # mine-but-broke: no fallback
    end
    reply.nil? ? FlashPlugin.ok : reply
  end

  # ── emitters ─────────────────────────────────────────────────────────────

  # Full-replacement catalog push; each row carries a first-class "source"
  # naming a manifest sources[].name.
  def publish(rows)
    notify("publish", "rows" => rows)
  end

  def status(segments)
    notify("status", "segments" => segments)
  end

  def log(level, message, fields = {})
    notify("log", "level" => level, "message" => message, "fields" => fields)
  end

  # ── serve loop ───────────────────────────────────────────────────────────

  # Registers the keyword hooks (lambdas), then reads frames until stdin EOF
  # — the shutdown signal: on_shutdown runs, serve returns, exit 0.
  def serve(on_start: nil, on_shutdown: nil, on_event: nil,
            on_evaluate: nil, on_search: nil, on_hints: nil,
            on_resolve: nil, on_command: nil, on_action: nil,
            on_navigate: nil)
    { on_start:, on_shutdown:, on_event:, on_evaluate:, on_search:,
      on_hints:, on_resolve:, on_command:, on_action:,
      on_navigate: }.each { |name, hook| @hooks[name] = hook if hook }
    until @done
      line = read_line
      line.nil? ? handle_eof : dispatch_line(line)
    end
    begin
      @hooks[:on_shutdown]&.call
    rescue StandardError
      nil # exiting anyway; stdout may already be gone
    end
  end
end
