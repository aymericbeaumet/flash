# Minimal Flash plugin protocol shim for Ruby (stdlib only).
#
# Speaks the wire contract from docs/plugin-protocol.md: protocol v1,
# newline-delimited JSON over stdio — one JSON object per line, nothing
# beyond id/method/params/result. id+method is a request, id alone is a
# response, method alone is a notification. Host and plugin id counters
# are independent (and may overlap); replies to our own call_host requests
# are correlated through a pending map, so any id+method frame arriving on
# stdin is a host→plugin request.

require "json"

PROTOCOL_VERSION = 1

class FlashPlugin
  AWAITING = Object.new # sentinel: call_host reply not seen yet

  def initialize
    $stdin.binmode
    $stdout.binmode
    $stdout.sync = true
    @next_id = 0
    @pending = {}
    @shutdown = false
  end

  # Plugin config, parsed once from the FLASH_PLUGIN_CONFIG env var
  # (a JSON object; {} when unset or invalid).
  def config
    @config ||= begin
      parsed = JSON.parse(ENV.fetch("FLASH_PLUGIN_CONFIG", ""))
      parsed.is_a?(Hash) ? parsed : {}
    rescue JSON::ParserError
      {}
    end
  end

  def send_frame(obj)
    $stdout.write(JSON.generate(obj) + "\n")
  end

  def respond(id, result)
    send_frame("id" => id, "result" => result)
  end

  def notify(method, params)
    send_frame("method" => method, "params" => params)
  end

  def log(level, message)
    notify("flash.log", "level" => level, "message" => message, "fields" => {})
  end

  # Blocking plugin→host RPC: sends the request, then pumps the read loop —
  # dispatching interleaved host traffic — until our reply lands. Returns
  # the host's result (nil if stdin closes first).
  def call_host(method, params = {})
    id = (@next_id += 1)
    @pending[id] = AWAITING
    send_frame("id" => id, "method" => method, "params" => params)
    while @pending[id].equal?(AWAITING)
      line = $stdin.gets
      if line.nil? # host went away: unblock and let serve wind down
        @shutdown = true
        @pending[id] = nil
      else
        dispatch_line(line)
      end
    end
    @pending.delete(id)
  end

  # Blocking single-threaded serve loop; enough for command-style plugins.
  # The block receives command.invoke params and returns the result hash.
  def serve(&on_command)
    @on_command = on_command
    until @shutdown
      line = $stdin.gets
      break if line.nil? # host closed stdin: clean exit
      dispatch_line(line)
    end
  end

  private

  def dispatch_line(line)
    msg = (JSON.parse(line) rescue nil)
    return unless msg.is_a?(Hash)
    id = msg["id"]
    method = msg["method"]
    if method && id # host→plugin request
      handle_request(id, method, msg["params"] || {})
    elsif id && @pending.key?(id) # reply to one of our call_host requests
      @pending[id] = msg["result"]
    end # method-only notifications and stray responses: nothing to do
  end

  def handle_request(id, method, params)
    case method
    when "initialize"
      respond(id, "ok" => true, "protocol_version" => PROTOCOL_VERSION)
    when "heartbeat"
      respond(id, "ok" => true)
    when "shutdown"
      respond(id, "ok" => true)
      @shutdown = true
    when "command.invoke"
      respond(id, @on_command.call(params))
    else
      respond(id, "ok" => false, "error" => "unsupported method #{method}")
    end
  end
end
