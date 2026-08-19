// Minimal Flash plugin protocol shim for Go (stdlib only).
//
// Speaks the wire contract from docs/plugin-protocol.md: protocol v1, one
// JSON object per newline-terminated line over stdio. No envelope beyond
// id/method/params/result — id+method is a request, id alone a response,
// method alone a notification. Host and plugin id counters are independent,
// so CallHost replies are correlated through a local pending map.
package main

import (
	"bufio"
	"encoding/json"
	"os"
	"sync"
)

const protocolVersion = 1

type plugin struct {
	mu      sync.Mutex // guards out, nextID, pending
	out     *bufio.Writer
	nextID  int
	pending map[int]chan map[string]any
	inbox   chan map[string]any
	config  map[string]any
}

func newPlugin() *plugin {
	p := &plugin{
		out:     bufio.NewWriter(os.Stdout),
		pending: map[int]chan map[string]any{},
		inbox:   make(chan map[string]any, 16),
		config:  map[string]any{},
	}
	var parsed map[string]any
	if raw := os.Getenv("FLASH_PLUGIN_CONFIG"); raw != "" {
		if json.Unmarshal([]byte(raw), &parsed) == nil && parsed != nil {
			p.config = parsed
		}
	}
	go p.read()
	return p
}

// Config returns the host-provided plugin configuration, parsed once from
// the FLASH_PLUGIN_CONFIG env var (empty when unset or invalid).
func (p *plugin) Config() map[string]any { return p.config }

// read pumps stdin on its own goroutine: response frames (id, no method)
// resolve pending CallHost waiters; everything else feeds serve's inbox.
func (p *plugin) read() {
	in := bufio.NewScanner(os.Stdin)
	in.Buffer(make([]byte, 0, 64*1024), 10<<20)
	for in.Scan() {
		var msg map[string]any
		if json.Unmarshal(in.Bytes(), &msg) != nil {
			continue
		}
		if id, hasID := jsonInt(msg["id"]); hasID && msg["method"] == nil {
			p.mu.Lock()
			ch := p.pending[id]
			delete(p.pending, id)
			p.mu.Unlock()
			if ch != nil {
				result, _ := msg["result"].(map[string]any)
				ch <- result
			}
			continue
		}
		p.inbox <- msg
	}
	p.mu.Lock() // host closed stdin: unblock any in-flight CallHost
	for id, ch := range p.pending {
		delete(p.pending, id)
		ch <- map[string]any{"ok": false, "error": "host closed"}
	}
	p.mu.Unlock()
	close(p.inbox)
}

func (p *plugin) send(v map[string]any) {
	raw, _ := json.Marshal(v)
	p.mu.Lock()
	p.out.Write(raw)
	p.out.WriteByte('\n')
	p.out.Flush()
	p.mu.Unlock()
}

func (p *plugin) respond(id int, result map[string]any) {
	p.send(map[string]any{"id": id, "result": result})
}

// CallHost issues a plugin→host request and blocks until the host replies.
// Safe from command handlers: the read goroutine keeps pumping while the
// serve goroutine waits here.
func (p *plugin) CallHost(method string, params map[string]any) map[string]any {
	ch := make(chan map[string]any, 1)
	p.mu.Lock()
	p.nextID++
	id := p.nextID
	p.pending[id] = ch
	p.mu.Unlock()
	p.send(map[string]any{"id": id, "method": method, "params": params})
	return <-ch
}

// serve runs the blocking dispatch loop until shutdown or host exit.
func (p *plugin) serve(onCommand func(params map[string]any) map[string]any) {
	for msg := range p.inbox {
		method, _ := msg["method"].(string)
		id, hasID := jsonInt(msg["id"])
		params, _ := msg["params"].(map[string]any)
		if !hasID {
			continue // notification (e.g. "event"): nothing to reply to
		}
		switch method {
		case "initialize":
			p.respond(id, map[string]any{"ok": true, "protocol_version": protocolVersion})
		case "heartbeat":
			p.respond(id, map[string]any{"ok": true})
		case "shutdown":
			p.respond(id, map[string]any{"ok": true})
			return
		case "command.invoke":
			p.respond(id, onCommand(params))
		default:
			p.respond(id, map[string]any{"ok": false, "error": "unsupported method " + method})
		}
	}
}

// jsonInt narrows encoding/json's float64 numbers to the integer ids the
// protocol uses (they can be negative: heartbeats arrive with id -1).
func jsonInt(v any) (int, bool) {
	f, ok := v.(float64)
	return int(f), ok
}
