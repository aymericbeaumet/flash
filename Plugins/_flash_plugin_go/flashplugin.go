// Package flashplugin is the shared Flash plugin SDK for Go (stdlib only) —
// no Flash business concepts, mirroring the Rust `flash_plugin` crate's role
// for Go plugins. Plugins depend on it through a go.mod replace directive:
//
//	require flashplugin v0.0.0
//	replace flashplugin => ../_flash_plugin_go
//
// Speaks the wire contract from docs/plugin-protocol.md, whose constants are
// pinned by Plugins/_flash_plugin_specs/protocol.json: protocol v1, one JSON
// object per newline-terminated line over stdio, 10 MiB line cap both
// directions. Frame triage: id+method is a host request, id alone resolves a
// CallHost waiter, method alone is a notification. The catalog is push-based
// (Publish replaces it whole), perform is the single effect method with its
// four kinds routed to OnResolve/OnCommand/OnAction/OnNavigate, and stdin
// EOF is the shutdown signal.
package flashplugin

import (
	"bufio"
	"encoding/json"
	"fmt"
	"os"
	"sync"
	"time"
)

// ── Constants ───────────────────────────────────────────────────────────

// ProtocolVersion is the one wire protocol version this SDK speaks, echoed
// verbatim in every initialize reply.
const ProtocolVersion = 1

// maxFrameBytes caps one NDJSON line in both directions
// (protocol.json quotas.frame_bytes).
const maxFrameBytes = 10 << 20

// defaultCallTimeoutMs bounds a CallHost round trip.
const defaultCallTimeoutMs = 5000

// ── Config / environment ────────────────────────────────────────────────

var (
	configOnce  sync.Once
	configValue map[string]any
)

// Config returns the plugin's `[plugin.<id>]` settings, parsed once from
// the FLASH_PLUGIN_CONFIG env var (empty when unset or invalid).
func Config() map[string]any {
	configOnce.Do(func() {
		configValue = map[string]any{}
		if raw := os.Getenv("FLASH_PLUGIN_CONFIG"); raw != "" {
			var parsed map[string]any
			if json.Unmarshal([]byte(raw), &parsed) == nil && parsed != nil {
				configValue = parsed
			}
		}
	})
	return configValue
}

// DataDir returns the host-provided writable data directory. It never
// defaults to "." — the host always provides the dir, and failing loudly
// beats scattering plugin state into an arbitrary working directory.
func DataDir() string {
	dir := os.Getenv("FLASH_PLUGIN_DATA_DIR")
	if dir == "" {
		fmt.Fprintln(os.Stderr,
			`flashplugin: FLASH_PLUGIN_DATA_DIR is unset — refusing to fall back to "."`)
		os.Exit(1)
	}
	return dir
}

// ── Framing ─────────────────────────────────────────────────────────────

type Plugin struct {
	mu          sync.Mutex // serializes the writer; guards nextID, pending, closed
	out         *bufio.Writer
	nextID      int
	pending     map[int]chan map[string]any
	closed      bool
	inbox       chan map[string]any
	handlers    Handlers       // set by Serve before the reader starts
	initialized bool           // reader-goroutine only
	startWG     sync.WaitGroup // tracks an in-flight OnStart
}

func New() *Plugin {
	return &Plugin{
		out:     bufio.NewWriter(os.Stdout),
		pending: map[int]chan map[string]any{},
		inbox:   make(chan map[string]any, 16),
	}
}

// readLine returns the next newline-terminated line without its newline. A
// line over the inbound cap is discarded through its next newline and
// reported as nil — the stream self-heals, never fatal. A non-nil error
// means stdin is done (an unterminated tail line is dropped with it).
func readLine(in *bufio.Reader) ([]byte, error) {
	var buf []byte
	oversized := false
	for {
		chunk, err := in.ReadSlice('\n')
		if !oversized {
			buf = append(buf, chunk...)
			if len(buf) > maxFrameBytes+1 { // +1: the trailing newline
				oversized, buf = true, nil
			}
		}
		if err == bufio.ErrBufferFull {
			continue
		}
		if err != nil {
			return nil, err
		}
		if oversized {
			return nil, nil
		}
		return buf[:len(buf)-1], nil
	}
}

// send marshals one frame onto stdout under the writer lock; reports false
// when encoding fails or the line would exceed the outbound cap (the frame
// is then not written at all — atomic rejection, never truncation).
func (p *Plugin) send(v map[string]any) bool {
	raw, err := json.Marshal(v)
	if err != nil || len(raw) > maxFrameBytes {
		return false
	}
	p.mu.Lock()
	p.out.Write(raw)
	p.out.WriteByte('\n')
	p.out.Flush()
	p.mu.Unlock()
	return true
}

// notify sends a method-only frame; an oversized notification is dropped.
func (p *Plugin) notify(method string, params map[string]any) {
	p.send(map[string]any{"method": method, "params": params})
}

// respond sends the one reply an id'd request gets; a response over the
// outbound cap is replaced by the canonical frame-overflow error.
func (p *Plugin) respond(id int, result map[string]any) {
	if !p.send(map[string]any{"id": id, "result": result}) {
		p.send(map[string]any{"id": id, "result": Fail("response exceeded outbound frame limit")})
	}
}

// ── Pending / CallHost ──────────────────────────────────────────────────

// CallHost issues a plugin→host RPC and blocks for the result with the
// default 5 s deadline. It never fails out-of-band: capability NAKs, host
// death ("host closed stdin"), and the deadline ("host call timed out")
// all arrive as ordinary {"ok": false, "error": …} results.
func (p *Plugin) CallHost(method string, params map[string]any) map[string]any {
	return p.CallHostTimeout(method, params, defaultCallTimeoutMs)
}

// CallHostTimeout is CallHost with a per-call deadline in milliseconds.
func (p *Plugin) CallHostTimeout(method string, params map[string]any, timeoutMs int) map[string]any {
	p.mu.Lock()
	if p.closed {
		p.mu.Unlock()
		return Fail("host closed stdin")
	}
	p.nextID++
	id := p.nextID
	ch := make(chan map[string]any, 1)
	p.pending[id] = ch
	p.mu.Unlock()
	p.send(map[string]any{"id": id, "method": method, "params": params})
	select {
	case result := <-ch:
		return result
	case <-time.After(time.Duration(timeoutMs) * time.Millisecond):
		p.mu.Lock()
		delete(p.pending, id) // a late reply now drops silently
		p.mu.Unlock()
		return Fail("host call timed out")
	}
}

// ── Dispatch ────────────────────────────────────────────────────────────

// read pumps stdin on its own goroutine until EOF — the shutdown signal:
// in-flight CallHost waiters resolve to the canonical host-closed error and
// the inbox closes so Serve can drain out and run OnShutdown.
func (p *Plugin) read() {
	in := bufio.NewReaderSize(os.Stdin, 64*1024)
	for {
		line, err := readLine(in)
		if line != nil {
			var msg map[string]any
			if json.Unmarshal(line, &msg) == nil && msg != nil {
				p.route(msg)
			}
		}
		if err != nil {
			break
		}
	}
	p.mu.Lock()
	p.closed = true
	for id, ch := range p.pending {
		delete(p.pending, id)
		ch <- Fail("host closed stdin")
	}
	p.mu.Unlock()
	close(p.inbox)
}

// route triages one inbound frame: id+method → host request (lifecycle and
// ping answered inline on the reader so replies are immediate and ordered
// even while a handler runs), id alone → a CallHost response (unknown ids
// drop silently), method alone → notification. The rest queues for Serve.
func (p *Plugin) route(msg map[string]any) {
	id, hasID := jsonInt(msg["id"])
	method, hasMethod := msg["method"].(string)
	switch {
	case hasID && !hasMethod:
		p.mu.Lock()
		ch := p.pending[id]
		delete(p.pending, id)
		p.mu.Unlock()
		if ch != nil {
			result, _ := msg["result"].(map[string]any)
			if result == nil {
				result = Fail("malformed host reply")
			}
			ch <- result
		}
	case hasID && method == "ping":
		p.respond(id, Ok(nil))
	case hasID && method == "initialize":
		p.initialize(id, msg)
	default:
		p.inbox <- msg
	}
}

// initialize replies IMMEDIATELY from the reader — no warm-catalog wait, no
// startup work first. OnStart runs on its own goroutine after the reply.
func (p *Plugin) initialize(id int, msg map[string]any) {
	if p.initialized {
		// The one non-terminal protocol NAK: keep serving.
		p.respond(id, Fail("initialize may only be called once"))
		return
	}
	params, _ := msg["params"].(map[string]any)
	if hostVersion, _ := jsonInt(params["protocol_version"]); hostVersion != ProtocolVersion {
		p.respond(id, map[string]any{
			"ok":               false,
			"protocol_version": ProtocolVersion,
			"error": fmt.Sprintf(
				"protocol version mismatch: host v%d, plugin v%d",
				hostVersion, ProtocolVersion),
		})
		os.Exit(0) // terminal, already flushed: sends are synchronous
	}
	p.initialized = true
	p.respond(id, Ok(map[string]any{"protocol_version": ProtocolVersion}))
	if p.handlers.OnStart != nil {
		p.startWG.Add(1)
		go func() {
			defer p.startWG.Done()
			p.handlers.OnStart()
		}()
	}
}

// ── Handlers ────────────────────────────────────────────────────────────

// Handlers are the plugin-provided hooks; every field is optional.
type Handlers struct {
	// OnStart runs on its own goroutine AFTER the initialize reply (the
	// reply is immediate by contract) and typically ends with Publish.
	OnStart func()
	// OnShutdown runs after stdin EOF drains, before the process exits 0.
	OnShutdown func()
	// OnEvent receives host events filtered by the manifest's listen globs.
	OnEvent func(name string, payload map[string]any)
	// OnEvaluate answers evaluate: synchronous, CPU-only answers.
	OnEvaluate func(params map[string]any) []map[string]any
	// OnSearch answers search with live rows in catalog row shape.
	OnSearch func(params map[string]any) []map[string]any
	// OnHints answers hints with targets plus an optional context pid
	// (0 = none).
	OnHints func(params map[string]any) (targets []map[string]any, contextPID int)
	// The four perform kinds; an unregistered kind answers the canonical
	// {"ok": false, "unhandled": true}.
	OnResolve  func(params map[string]any) map[string]any
	OnCommand  func(params map[string]any) map[string]any
	OnAction   func(params map[string]any) map[string]any
	OnNavigate func(params map[string]any) map[string]any
}

// Ok builds an {"ok": true} result carrying fields (nil for none).
func Ok(fields map[string]any) map[string]any {
	result := map[string]any{"ok": true}
	for key, value := range fields {
		result[key] = value
	}
	return result
}

// Unhandled is perform's "not my context" reply — the host MAY fall back.
func Unhandled() map[string]any {
	return map[string]any{"ok": false, "unhandled": true}
}

// Fail is the ok:false error reply; keep messages content-free.
func Fail(message string) map[string]any {
	return map[string]any{"ok": false, "error": message}
}

// ── Emitters ────────────────────────────────────────────────────────────

// Publish replaces the plugin's entire catalog (push-based; the host owns
// the store). Every row carries the first-class "source" field naming a
// manifest sources[].name; empty rows is an authoritative empty. On a
// transient refresh failure, simply don't publish — the host keeps the
// last-good catalog.
func (p *Plugin) Publish(rows []map[string]any) {
	if rows == nil {
		rows = []map[string]any{}
	}
	p.notify("publish", map[string]any{"rows": rows})
}

// Status feeds manifest-declared status segments; "" clears one.
func (p *Plugin) Status(segments map[string]string) {
	p.notify("status", map[string]any{"segments": segments})
}

// Log emits the structured log notification. Content-free by contract:
// counts, stages, elapsed ms — never query text or candidate data.
func (p *Plugin) Log(level, message string, fields map[string]string) {
	if fields == nil {
		fields = map[string]string{}
	}
	p.notify("log", map[string]any{"level": level, "message": message, "fields": fields})
}

// ── Serve loop ──────────────────────────────────────────────────────────

// Serve stores the handlers, starts the reader, and runs the blocking
// dispatch loop until stdin EOF: remaining frames drain, an in-flight
// OnStart finishes (its publish matters), OnShutdown runs, and Serve
// returns so main exits 0.
func (p *Plugin) Serve(h Handlers) {
	p.handlers = h
	go p.read()
	for msg := range p.inbox {
		method, _ := msg["method"].(string)
		params, _ := msg["params"].(map[string]any)
		if params == nil {
			params = map[string]any{}
		}
		id, hasID := jsonInt(msg["id"])
		if !hasID {
			if method == "event" && h.OnEvent != nil {
				name, _ := params["name"].(string)
				payload, _ := params["payload"].(map[string]any)
				h.OnEvent(name, payload)
			}
			continue // unknown notifications are wire noise
		}
		switch method {
		case "evaluate":
			var answers []map[string]any
			if h.OnEvaluate != nil {
				answers = h.OnEvaluate(params)
			}
			if answers == nil {
				answers = []map[string]any{}
			}
			p.respond(id, Ok(map[string]any{"answers": answers}))
		case "search":
			var rows []map[string]any
			if h.OnSearch != nil {
				rows = h.OnSearch(params)
			}
			if rows == nil {
				rows = []map[string]any{}
			}
			p.respond(id, Ok(map[string]any{"rows": rows}))
		case "hints":
			var targets []map[string]any
			contextPID := 0
			if h.OnHints != nil {
				targets, contextPID = h.OnHints(params)
			}
			if targets == nil {
				targets = []map[string]any{}
			}
			result := Ok(map[string]any{"targets": targets})
			if contextPID != 0 {
				result["context_pid"] = contextPID
			}
			p.respond(id, result)
		case "perform":
			p.respond(id, perform(h, params))
		default:
			p.respond(id, Fail("unknown method: "+method))
		}
	}
	p.startWG.Wait()
	if h.OnShutdown != nil {
		h.OnShutdown()
	}
}

// perform routes the single effect method's four kinds. An unregistered
// kind is "not mine" (the host may fall back); an unknown kind is an error
// (the host must not fall back on garbage).
func perform(h Handlers, params map[string]any) map[string]any {
	kind, _ := params["kind"].(string)
	var handler func(map[string]any) map[string]any
	switch kind {
	case "resolve":
		handler = h.OnResolve
	case "command":
		handler = h.OnCommand
	case "action":
		handler = h.OnAction
	case "navigate":
		handler = h.OnNavigate
	default:
		return Fail("unknown perform kind: " + kind)
	}
	if handler == nil {
		return Unhandled()
	}
	if result := handler(params); result != nil {
		return result
	}
	return Fail("perform handler returned no result")
}

// jsonInt narrows encoding/json's float64 numbers to the integer ids the
// protocol uses.
func jsonInt(v any) (int, bool) {
	f, ok := v.(float64)
	return int(f), ok
}
