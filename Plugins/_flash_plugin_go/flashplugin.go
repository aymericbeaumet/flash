// Package flashplugin is the shared Flash plugin SDK for Go (stdlib only) —
// no Flash business concepts, mirroring the Rust `flash_plugin` crate's role
// for Go plugins. Plugins depend on it through a go.mod replace directive:
//
//	require flashplugin v0.0.0
//	replace flashplugin => ../_flash_plugin_go
//
// Speaks the wire contract from docs/plugin-protocol.md: protocol v1, one
// JSON object per newline-terminated line over stdio. No envelope beyond
// id/method/params/result — id+method is a request, id alone a response,
// method alone a notification. Host and plugin id counters are independent,
// so CallHost replies are correlated through a local pending map.
package flashplugin

import (
	"bufio"
	"encoding/json"
	"os"
	"sort"
	"sync"
)

const protocolVersion = 1

// Handlers are the plugin-provided hooks; every field is optional.
type Handlers struct {
	// OnStart runs when initialize arrives, BEFORE the reply — a sources
	// plugin must populate its warm store here (the readiness gate).
	OnStart func()
	// OnCommand answers command.invoke; the result map is the wire result.
	OnCommand func(params map[string]any) map[string]any
	// OnEvent receives host events filtered by the manifest's listen globs.
	OnEvent func(name string, payload map[string]any)
}

type Plugin struct {
	mu      sync.Mutex // guards out, nextID, pending
	out     *bufio.Writer
	nextID  int
	pending map[int]chan map[string]any
	inbox   chan map[string]any
	config  map[string]any
	warmMu  sync.Mutex // guards warm
	warm    map[string][]map[string]any
}

func New() *Plugin {
	p := &Plugin{
		out:     bufio.NewWriter(os.Stdout),
		pending: map[int]chan map[string]any{},
		inbox:   make(chan map[string]any, 16),
		config:  map[string]any{},
		warm:    map[string][]map[string]any{},
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
func (p *Plugin) Config() map[string]any { return p.config }

// SetLocations atomically replaces one warm-store catalog entry; rows are
// full candidate objects ({title, url?, metadata, effect?}).
func (p *Plugin) SetLocations(sourceID string, rows []map[string]any) {
	p.warmMu.Lock()
	p.warm[sourceID] = rows
	p.warmMu.Unlock()
}

// InvalidateSources declares the warm catalog stale: an open flashlight
// session re-pulls this plugin's snapshot (rate-limited host-side).
func (p *Plugin) InvalidateSources() {
	p.send(map[string]any{"method": "sources.invalidated", "params": map[string]any{}})
}

func (p *Plugin) Log(level, message string) {
	p.send(map[string]any{
		"method": "flash.log",
		"params": map[string]any{"level": level, "message": message, "fields": map[string]any{}},
	})
}

// read pumps stdin on its own goroutine: response frames (id, no method)
// resolve pending CallHost waiters; everything else feeds Serve's inbox.
// Undecodable lines are wire noise — dropped, never fatal.
func (p *Plugin) read() {
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

func (p *Plugin) send(v map[string]any) {
	raw, _ := json.Marshal(v)
	p.mu.Lock()
	p.out.Write(raw)
	p.out.WriteByte('\n')
	p.out.Flush()
	p.mu.Unlock()
}

func (p *Plugin) respond(id int, result map[string]any) {
	p.send(map[string]any{"id": id, "result": result})
}

// CallHost issues a plugin→host request and blocks until the host replies.
// Safe from command handlers: the read goroutine keeps pumping while the
// serve goroutine waits here.
func (p *Plugin) CallHost(method string, params map[string]any) map[string]any {
	ch := make(chan map[string]any, 1)
	p.mu.Lock()
	p.nextID++
	id := p.nextID
	p.pending[id] = ch
	p.mu.Unlock()
	p.send(map[string]any{"id": id, "method": method, "params": params})
	return <-ch
}

// Serve runs the blocking dispatch loop until shutdown or host exit.
func (p *Plugin) Serve(h Handlers) {
	for msg := range p.inbox {
		method, _ := msg["method"].(string)
		id, hasID := jsonInt(msg["id"])
		params, _ := msg["params"].(map[string]any)
		if !hasID {
			if method == "event" && h.OnEvent != nil {
				name, _ := params["name"].(string)
				payload, _ := params["payload"].(map[string]any)
				h.OnEvent(name, payload)
			}
			continue // notifications carry nothing to reply to
		}
		switch method {
		case "initialize":
			if version, _ := jsonInt(params["protocol_version"]); version != protocolVersion {
				p.respond(id, map[string]any{"ok": false, "error": "protocol version mismatch"})
				return
			}
			if h.OnStart != nil {
				h.OnStart() // blocks the reply until the warm store is loaded
			}
			p.respond(id, map[string]any{"ok": true, "protocol_version": protocolVersion})
		case "heartbeat":
			p.respond(id, map[string]any{"ok": true})
		case "shutdown":
			p.respond(id, map[string]any{"ok": true})
			return
		case "sources.snapshot":
			p.warmMu.Lock()
			keys := make([]string, 0, len(p.warm))
			for key := range p.warm {
				keys = append(keys, key)
			}
			sort.Strings(keys)
			candidates := []map[string]any{}
			for _, key := range keys {
				candidates = append(candidates, p.warm[key]...)
			}
			p.warmMu.Unlock()
			p.respond(id, map[string]any{"candidates": candidates})
		case "command.invoke":
			if h.OnCommand == nil {
				p.respond(id, map[string]any{"ok": false, "error": "no command handler"})
				continue
			}
			p.respond(id, h.OnCommand(params))
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
