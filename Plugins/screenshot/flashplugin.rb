# Minimal Flash plugin protocol shim for Ruby (stdlib only).
#
# Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
# MessagePack over stdio (4-byte big-endian length + one value) and the
# protocol v3 lifecycle. Hand-rolls the MessagePack subset the protocol
# needs — nil/bool/int/str/array/map — so a plugin author needs nothing
# beyond the mise-pinned ruby.

PROTOCOL_VERSION = 3

module MsgPack
  module_function

  def encode(obj)
    case obj
    when nil then "\xC0".b
    when true then "\xC3".b
    when false then "\xC2".b
    when Integer
      if obj >= 0 && obj <= 127 then [obj].pack("C")
      elsif obj >= -32 && obj < 0 then [obj].pack("c")
      else "\xD3".b + [obj].pack("q>")
      end
    when String
      raw = obj.encode("UTF-8").b
      head = raw.bytesize < 32 ? [0xA0 | raw.bytesize].pack("C") : "\xDB".b + [raw.bytesize].pack("N")
      head + raw
    when Array
      head = obj.size < 16 ? [0x90 | obj.size].pack("C") : "\xDC".b + [obj.size].pack("n")
      head + obj.map { |x| encode(x) }.join
    when Hash
      head = obj.size < 16 ? [0x80 | obj.size].pack("C") : "\xDE".b + [obj.size].pack("n")
      head + obj.map { |k, v| encode(k.to_s) + encode(v) }.join
    else
      raise TypeError, "unencodable #{obj.class}"
    end
  end

  def decode(buf, pos = 0)
    b = buf.getbyte(pos)
    pos += 1
    return [nil, pos] if b == 0xC0
    return [false, pos] if b == 0xC2
    return [true, pos] if b == 0xC3
    return [b, pos] if b <= 0x7F
    return [b - 256, pos] if b >= 0xE0
    if b.between?(0xA0, 0xBF) || [0xD9, 0xDA, 0xDB].include?(b)
      n =
        if b <= 0xBF then b & 0x1F
        elsif b == 0xD9 then (pos += 1; buf.getbyte(pos - 1))
        elsif b == 0xDA then (pos += 2; buf.byteslice(pos - 2, 2).unpack1("n"))
        else (pos += 4; buf.byteslice(pos - 4, 4).unpack1("N"))
        end
      return [buf.byteslice(pos, n).force_encoding("UTF-8"), pos + n]
    end
    if b.between?(0x80, 0x8F) || [0xDE, 0xDF].include?(b)
      n =
        if b <= 0x8F then b & 0x0F
        elsif b == 0xDE then (pos += 2; buf.byteslice(pos - 2, 2).unpack1("n"))
        else (pos += 4; buf.byteslice(pos - 4, 4).unpack1("N"))
        end
      out = {}
      n.times do
        k, pos = decode(buf, pos)
        v, pos = decode(buf, pos)
        out[k] = v
      end
      return [out, pos]
    end
    if b.between?(0x90, 0x9F) || [0xDC, 0xDD].include?(b)
      n =
        if b <= 0x9F then b & 0x0F
        elsif b == 0xDC then (pos += 2; buf.byteslice(pos - 2, 2).unpack1("n"))
        else (pos += 4; buf.byteslice(pos - 4, 4).unpack1("N"))
        end
      out = []
      n.times do
        v, pos = decode(buf, pos)
        out << v
      end
      return [out, pos]
    end
    case b
    when 0xCC, 0xD0 then [buf.getbyte(pos), pos + 1]
    when 0xCD, 0xD1 then [buf.byteslice(pos, 2).unpack1("n"), pos + 2]
    when 0xCE, 0xD2 then [buf.byteslice(pos, 4).unpack1("N"), pos + 4]
    when 0xCF, 0xD3 then [buf.byteslice(pos, 8).unpack1("q>"), pos + 8]
    when 0xCA then [buf.byteslice(pos, 4).unpack1("g"), pos + 4]
    when 0xCB then [buf.byteslice(pos, 8).unpack1("G"), pos + 8]
    else raise "unhandled msgpack byte 0x#{b.to_s(16)}"
    end
  end
end

class FlashPlugin
  def initialize
    $stdout.binmode
    $stdin.binmode
  end

  def send_frame(obj)
    payload = MsgPack.encode(obj)
    $stdout.write([payload.bytesize].pack("N") + payload)
    $stdout.flush
  end

  def respond(id, result)
    send_frame({ "jsonrpc" => "2.0", "id" => id, "result" => result })
  end

  def log(level, message)
    send_frame(
      "jsonrpc" => "2.0",
      "method" => "flash.log",
      "params" => { "level" => level, "message" => message, "fields" => {} }
    )
  end

  # Blocking single-threaded serve loop; enough for command-style plugins.
  def serve(&on_command)
    loop do
      header = $stdin.read(4)
      return if header.nil? || header.bytesize < 4 # host closed stdin

      payload = $stdin.read(header.unpack1("N"))
      msg, = MsgPack.decode(payload)
      method = msg["method"]
      id = msg["id"]
      case method
      when "initialize"
        version = msg.dig("params", "protocol_version")
        if version != PROTOCOL_VERSION
          respond(id, "ok" => false, "error" => "protocol #{version} != #{PROTOCOL_VERSION}")
          return
        end
        respond(id, "ok" => true, "protocol_version" => PROTOCOL_VERSION, "published_sources" => [])
      when "heartbeat"
        respond(id, "ok" => true)
      when "shutdown"
        respond(id, "ok" => true)
        return
      when "command.invoke"
        respond(id, on_command.call(msg["params"] || {}))
      else
        respond(id, "ok" => false, "error" => "unsupported method #{method}") unless id.nil?
      end
    end
  end
end
