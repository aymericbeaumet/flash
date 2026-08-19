// Minimal Flash plugin protocol shim for Go (stdlib only).
//
// Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
// MessagePack over stdio (4-byte big-endian length + one value) and the
// protocol v3 lifecycle. Hand-rolls the MessagePack subset the protocol
// needs — nil/bool/int/str/array/map — so the module has zero dependencies
// and `go build` inside the sandboxed third-party install just works.
package main

import (
	"bufio"
	"encoding/binary"
	"fmt"
	"io"
	"math"
	"os"
)

const protocolVersion = 3

func mpEncode(out *[]byte, v any) {
	switch x := v.(type) {
	case nil:
		*out = append(*out, 0xc0)
	case bool:
		if x {
			*out = append(*out, 0xc3)
		} else {
			*out = append(*out, 0xc2)
		}
	case int:
		mpEncode(out, int64(x))
	case int64:
		if x >= 0 && x <= 127 {
			*out = append(*out, byte(x))
		} else if x < 0 && x >= -32 {
			*out = append(*out, byte(x))
		} else {
			*out = append(*out, 0xd3)
			*out = binary.BigEndian.AppendUint64(*out, uint64(x))
		}
	case string:
		raw := []byte(x)
		if len(raw) < 32 {
			*out = append(*out, 0xa0|byte(len(raw)))
		} else {
			*out = append(*out, 0xdb)
			*out = binary.BigEndian.AppendUint32(*out, uint32(len(raw)))
		}
		*out = append(*out, raw...)
	case []any:
		if len(x) < 16 {
			*out = append(*out, 0x90|byte(len(x)))
		} else {
			*out = append(*out, 0xdc)
			*out = binary.BigEndian.AppendUint16(*out, uint16(len(x)))
		}
		for _, e := range x {
			mpEncode(out, e)
		}
	case map[string]any:
		if len(x) < 16 {
			*out = append(*out, 0x80|byte(len(x)))
		} else {
			*out = append(*out, 0xde)
			*out = binary.BigEndian.AppendUint16(*out, uint16(len(x)))
		}
		for k, e := range x {
			mpEncode(out, k)
			mpEncode(out, e)
		}
	default:
		panic(fmt.Sprintf("unencodable %T", v))
	}
}

func mpDecode(buf []byte, pos int) (any, int) {
	b := buf[pos]
	pos++
	switch {
	case b == 0xc0:
		return nil, pos
	case b == 0xc2:
		return false, pos
	case b == 0xc3:
		return true, pos
	case b <= 0x7f:
		return int64(b), pos
	case b >= 0xe0:
		return int64(int8(b)), pos
	case b >= 0xa0 && b <= 0xbf:
		n := int(b & 0x1f)
		return string(buf[pos : pos+n]), pos + n
	case b == 0xd9:
		n := int(buf[pos])
		return string(buf[pos+1 : pos+1+n]), pos + 1 + n
	case b == 0xda:
		n := int(binary.BigEndian.Uint16(buf[pos:]))
		return string(buf[pos+2 : pos+2+n]), pos + 2 + n
	case b == 0xdb:
		n := int(binary.BigEndian.Uint32(buf[pos:]))
		return string(buf[pos+4 : pos+4+n]), pos + 4 + n
	case b >= 0x80 && b <= 0x8f, b == 0xde, b == 0xdf:
		n := int(b & 0x0f)
		if b == 0xde {
			n = int(binary.BigEndian.Uint16(buf[pos:]))
			pos += 2
		} else if b == 0xdf {
			n = int(binary.BigEndian.Uint32(buf[pos:]))
			pos += 4
		}
		out := make(map[string]any, n)
		for i := 0; i < n; i++ {
			k, p := mpDecode(buf, pos)
			v, p2 := mpDecode(buf, p)
			out[fmt.Sprint(k)] = v
			pos = p2
		}
		return out, pos
	case b >= 0x90 && b <= 0x9f, b == 0xdc, b == 0xdd:
		n := int(b & 0x0f)
		if b == 0xdc {
			n = int(binary.BigEndian.Uint16(buf[pos:]))
			pos += 2
		} else if b == 0xdd {
			n = int(binary.BigEndian.Uint32(buf[pos:]))
			pos += 4
		}
		out := make([]any, 0, n)
		for i := 0; i < n; i++ {
			var v any
			v, pos = mpDecode(buf, pos)
			out = append(out, v)
		}
		return out, pos
	case b == 0xcc, b == 0xd0:
		return int64(buf[pos]), pos + 1
	case b == 0xcd, b == 0xd1:
		return int64(binary.BigEndian.Uint16(buf[pos:])), pos + 2
	case b == 0xce, b == 0xd2:
		return int64(binary.BigEndian.Uint32(buf[pos:])), pos + 4
	case b == 0xcf, b == 0xd3:
		return int64(binary.BigEndian.Uint64(buf[pos:])), pos + 8
	case b == 0xca:
		// The host sends doubles (window frames on focus events); a missing
		// float case here is a process-killing panic one `listen:` line away.
		return float64(math.Float32frombits(binary.BigEndian.Uint32(buf[pos:]))), pos + 4
	case b == 0xcb:
		return math.Float64frombits(binary.BigEndian.Uint64(buf[pos:])), pos + 8
	}
	panic(fmt.Sprintf("unhandled msgpack byte 0x%02x", b))
}

type plugin struct {
	out *bufio.Writer
}

func newPlugin() *plugin {
	return &plugin{out: bufio.NewWriter(os.Stdout)}
}

func (p *plugin) send(v map[string]any) {
	var payload []byte
	mpEncode(&payload, any(v))
	var header [4]byte
	binary.BigEndian.PutUint32(header[:], uint32(len(payload)))
	p.out.Write(header[:])
	p.out.Write(payload)
	p.out.Flush()
}

func (p *plugin) respond(id any, result map[string]any) {
	p.send(map[string]any{"jsonrpc": "2.0", "id": id, "result": any(result)})
}

func (p *plugin) logMessage(level, message string) {
	p.send(map[string]any{
		"jsonrpc": "2.0",
		"method":  "flash.log",
		"params": any(map[string]any{
			"level": level, "message": message, "fields": any(map[string]any{}),
		}),
	})
}

// serve runs the blocking dispatch loop until shutdown or host exit.
func (p *plugin) serve(onCommand func(params map[string]any) map[string]any) {
	in := bufio.NewReader(os.Stdin)
	for {
		var header [4]byte
		if _, err := io.ReadFull(in, header[:]); err != nil {
			return // host closed stdin
		}
		payload := make([]byte, binary.BigEndian.Uint32(header[:]))
		if _, err := io.ReadFull(in, payload); err != nil {
			return
		}
		raw, _ := mpDecode(payload, 0)
		msg, _ := raw.(map[string]any)
		method, _ := msg["method"].(string)
		id := msg["id"]
		params, _ := msg["params"].(map[string]any)
		switch method {
		case "initialize":
			if v, _ := params["protocol_version"].(int64); v != protocolVersion {
				p.respond(id, map[string]any{
					"ok": false, "error": fmt.Sprintf("protocol %v != %d", v, protocolVersion),
				})
				return
			}
			p.respond(id, map[string]any{
				"ok":                true,
				"protocol_version":  protocolVersion,
				"published_sources": any([]any{}),
			})
		case "heartbeat":
			p.respond(id, map[string]any{"ok": true})
		case "shutdown":
			p.respond(id, map[string]any{"ok": true})
			return
		case "command.invoke":
			p.respond(id, onCommand(params))
		default:
			if id != nil {
				p.respond(id, map[string]any{
					"ok": false, "error": "unsupported method " + method,
				})
			}
		}
	}
}
