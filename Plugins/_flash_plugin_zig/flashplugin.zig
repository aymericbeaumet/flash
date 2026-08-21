//! Shared Flash plugin SDK for Zig (stdlib only) — no Flash business
//! concepts, mirroring the Rust `flash_plugin` crate's role for Zig
//! plugins. Scripts/build-plugins.sh links this file as the `flashplugin`
//! module next to each plugin's main.zig.
//!
//! Speaks the wire contract from docs/plugin-protocol.md, whose constants
//! are pinned by Plugins/_flash_plugin_specs/protocol.json: protocol v1,
//! one JSON object per newline-terminated line over stdio, 10 MiB line cap
//! both directions (heap buffers sized to the cap; an oversized inbound
//! line is discarded through its next newline — the stream self-heals,
//! never fatal). Frame triage: id+method is a host request, id alone
//! resolves a callHost waiter, method alone is a notification. The catalog
//! is push-based (publish replaces it whole), perform is the single effect
//! method with its four kinds routed to on_resolve/on_command/on_action/
//! on_navigate, and stdin EOF is the shutdown signal. Everything runs
//! single-threaded — fully conformant: pings never race in-flight requests
//! — and callHost BLOCKS, inline-pumping the read loop (interleaved host
//! requests and notifications flow through normal dispatch) with its
//! deadline enforced through poll(2) on stdin. Inbound frames parse into a
//! runtime arena reset only after each top-level dispatch fully unwinds,
//! so every Value a handler holds stays valid for as long as it runs.

const std = @import("std");

// ── Constants ───────────────────────────────────────────────────────────

/// The one wire protocol version this SDK speaks, echoed verbatim in every
/// initialize reply.
pub const protocol_version: i64 = 1;

/// One NDJSON line cap, both directions (protocol.json quotas.frame_bytes).
pub const max_frame_bytes: usize = 10 << 20;

/// Default callHost round-trip deadline.
pub const default_call_timeout_ms: i64 = 5000;

/// Concurrent callHost bound — calls only nest (single-threaded), so this
/// is recursion depth, not parallelism.
const max_pending = 16;

// ── JSON plumbing ───────────────────────────────────────────────────────

pub const Value = std.json.Value;

/// Object lookup that folds a miss to null — chainable:
/// `fp.asString(fp.field(fp.field(msg, "params"), "subcommand"))`.
pub fn field(v: Value, key: []const u8) Value {
    return switch (v) {
        .object => |entries| entries.get(key) orelse .null,
        else => .null,
    };
}

pub fn asString(v: Value) ?[]const u8 {
    return switch (v) {
        .string => |s| s,
        else => null,
    };
}

pub fn asInteger(v: Value) ?i64 {
    return switch (v) {
        .integer => |n| n,
        else => null,
    };
}

pub fn asBool(v: Value) ?bool {
    return switch (v) {
        .bool => |b| b,
        else => null,
    };
}

/// Insert into an object Value; allocation failure drops the entry (the
/// runtime arena is page-backed, so that is a true-OOM-only path).
pub fn put(arena: std.mem.Allocator, object: *Value, key: []const u8, value: Value) void {
    object.object.put(arena, key, value) catch {};
}

// ── Config / environment ────────────────────────────────────────────────

/// The plugin's `[plugin.<id>]` settings, delivered as a JSON object in
/// FLASH_PLUGIN_CONFIG; empty when unset or malformed.
pub fn config(arena: std.mem.Allocator) Value {
    const empty: Value = .{ .object = .empty };
    const raw = std.posix.getenv("FLASH_PLUGIN_CONFIG") orelse return empty;
    const parsed = std.json.parseFromSliceLeaky(Value, arena, raw, .{}) catch return empty;
    return switch (parsed) {
        .object => parsed,
        else => empty,
    };
}

/// The host-provided writable data directory. Never defaults to "." — the
/// host always provides the dir, and failing loudly beats scattering
/// plugin state into an arbitrary working directory.
pub fn dataDir() []const u8 {
    return std.posix.getenv("FLASH_PLUGIN_DATA_DIR") orelse
        std.process.fatal("FLASH_PLUGIN_DATA_DIR is unset — refusing to fall back to \".\"", .{});
}

// ── Framing / runtime ───────────────────────────────────────────────────

/// Monotonic clock in milliseconds (libc clock_gettime; deadlines only).
fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn writeAll(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

pub const Runtime = struct {
    handlers: Handlers,
    arena_state: std.heap.ArenaAllocator,
    in_buf: []u8,
    out_buf: []u8,
    in_len: usize = 0,
    in_pos: usize = 0,
    discarding: bool = false,
    eof: bool = false,
    initialized: bool = false,
    next_call_id: i64 = 1,
    pending: [max_pending]Pending = [_]Pending{.{}} ** max_pending,

    const Pending = struct {
        id: i64 = 0,
        active: bool = false,
        result: ?Value = null,
    };

    fn init(handlers: Handlers) Runtime {
        const heap = std.heap.page_allocator;
        return .{
            .handlers = handlers,
            .arena_state = std.heap.ArenaAllocator.init(heap),
            .in_buf = heap.alloc(u8, max_frame_bytes + 1) catch
                std.process.fatal("flashplugin: cannot allocate the inbound frame buffer", .{}),
            .out_buf = heap.alloc(u8, max_frame_bytes + 1) catch
                std.process.fatal("flashplugin: cannot allocate the outbound frame buffer", .{}),
        };
    }

    /// The dispatch arena: reset only after a top-level frame's handler
    /// chain fully unwinds, so handler-held Values stay valid throughout.
    pub fn arena(self: *Runtime) std.mem.Allocator {
        return self.arena_state.allocator();
    }

    /// Next newline-terminated line (sans newline), valid until the next
    /// call. Blocks when `deadline_ms` is null; otherwise returns null once
    /// the wall clock passes it (poll(2) on stdin bounds each wait) or at
    /// EOF (`self.eof` distinguishes the two). A line over the inbound cap
    /// is discarded through its next newline and never surfaces — the
    /// stream self-heals instead of dying.
    fn readLine(self: *Runtime, deadline_ms: ?i64) ?[]const u8 {
        while (true) {
            while (std.mem.indexOfScalarPos(u8, self.in_buf[0..self.in_len], self.in_pos, '\n')) |nl| {
                const line = self.in_buf[self.in_pos..nl];
                self.in_pos = nl + 1;
                if (self.discarding) { // the tail of an oversized line: drop it, healed
                    self.discarding = false;
                    continue;
                }
                return line;
            }
            if (self.discarding) {
                self.in_len = 0; // still inside the oversized line: drop it all
                self.in_pos = 0;
            } else if (self.in_pos > 0) {
                std.mem.copyForwards(u8, self.in_buf[0 .. self.in_len - self.in_pos], self.in_buf[self.in_pos..self.in_len]);
                self.in_len -= self.in_pos;
                self.in_pos = 0;
            }
            if (self.in_len == self.in_buf.len) {
                // The buffer holds a full cap's worth with no newline: this
                // line can never be legal. Discard to the next newline.
                self.in_len = 0;
                self.discarding = true;
            }
            if (self.eof) return null;
            if (deadline_ms) |deadline| {
                const remaining = deadline - nowMs();
                if (remaining <= 0) return null;
                var fds = [_]std.posix.pollfd{.{ .fd = 0, .events = std.posix.POLL.IN, .revents = 0 }};
                const ready = std.posix.poll(&fds, @intCast(@min(remaining, std.math.maxInt(i32)))) catch continue;
                if (ready == 0) return null; // deadline passed with no frame
            }
            const n = std.c.read(0, self.in_buf[self.in_len..].ptr, self.in_buf.len - self.in_len);
            if (n < 0) continue; // EINTR and friends: retry
            if (n == 0) {
                self.eof = true;
                return null;
            }
            self.in_len += @intCast(n);
        }
    }

    /// Serialize one frame as a minified JSON line onto stdout; false when
    /// it would exceed the outbound cap (the frame is then not written at
    /// all — atomic rejection, never truncation).
    fn sendFrame(self: *Runtime, frame: Value) bool {
        var writer: std.Io.Writer = .fixed(self.out_buf);
        std.json.Stringify.value(frame, .{}, &writer) catch return false;
        writer.writeByte('\n') catch return false;
        writeAll(writer.buffered());
        return true;
    }

    /// Method-only frame; an oversized notification is dropped.
    fn sendNotification(self: *Runtime, alloc: std.mem.Allocator, method: []const u8, params: Value) void {
        var frame: Value = .{ .object = .empty };
        put(alloc, &frame, "method", .{ .string = method });
        put(alloc, &frame, "params", params);
        _ = self.sendFrame(frame);
    }

    /// The one reply an id'd request gets; a response over the outbound
    /// cap is replaced by the canonical frame-overflow error.
    fn sendResult(self: *Runtime, alloc: std.mem.Allocator, id: i64, result: Value) void {
        var frame: Value = .{ .object = .empty };
        put(alloc, &frame, "id", .{ .integer = id });
        put(alloc, &frame, "result", result);
        if (!self.sendFrame(frame)) {
            var fallback: Value = .{ .object = .empty };
            put(alloc, &fallback, "id", .{ .integer = id });
            put(alloc, &fallback, "result", fail(alloc, "response exceeded outbound frame limit"));
            _ = self.sendFrame(fallback);
        }
    }

    // ── Pending / callHost ──

    /// Plugin→host RPC on our own id counter. Blocks single-threadedly:
    /// writes the request, then pumps the read loop in place — interleaved
    /// host requests and notifications flow through normal dispatch (and
    /// may nest further callHosts, each on its own pending slot) — until
    /// the matching response lands, stdin closes, or the deadline passes.
    /// Never fails out-of-band: capability NAKs, host death ("host closed
    /// stdin"), and the deadline ("host call timed out") all arrive as
    /// ordinary {"ok": false, "error": …} results — the caller always gets
    /// the host's actual verdict, never a fire-and-forget guess.
    pub fn callHost(self: *Runtime, alloc: std.mem.Allocator, method: []const u8, params: Value, timeout_ms: ?i64) Value {
        if (self.eof) return fail(alloc, "host closed stdin");
        const slot = self.acquireSlot() orelse
            return fail(alloc, "host call slots exhausted");
        const id = self.next_call_id;
        self.next_call_id += 1;
        slot.* = .{ .id = id, .active = true, .result = null };
        var frame: Value = .{ .object = .empty };
        put(alloc, &frame, "id", .{ .integer = id });
        put(alloc, &frame, "method", .{ .string = method });
        put(alloc, &frame, "params", params);
        _ = self.sendFrame(frame); // an oversized request is dropped: the deadline settles it
        const deadline = nowMs() + (timeout_ms orelse default_call_timeout_ms);
        while (true) {
            if (slot.result) |result| {
                slot.active = false;
                return switch (result) {
                    .object => result,
                    else => fail(alloc, "malformed host reply"),
                };
            }
            if (self.eof) {
                slot.active = false;
                return fail(alloc, "host closed stdin");
            }
            if (nowMs() >= deadline) {
                slot.active = false; // a late reply now drops silently
                return fail(alloc, "host call timed out");
            }
            const line = self.readLine(deadline) orelse continue; // timeout/EOF: loop re-checks
            self.dispatchLine(line);
        }
    }

    fn acquireSlot(self: *Runtime) ?*Pending {
        for (&self.pending) |*slot| {
            if (!slot.active) return slot;
        }
        return null;
    }

    /// Resolve one pending call; responses to unknown ids drop silently.
    /// The stored Value stays valid: the arena resets only after the whole
    /// dispatch chain (including the waiting callHost) unwinds.
    fn settle(self: *Runtime, id: i64, result: Value) void {
        for (&self.pending) |*slot| {
            if (slot.active and slot.id == id) {
                slot.result = result;
                return;
            }
        }
    }

    // ── Dispatch ──

    /// Frame triage: id+method → host request, id alone → callHost
    /// response, method alone → notification. Undecodable lines are wire
    /// noise — dropped, never fatal.
    fn dispatchLine(self: *Runtime, line: []const u8) void {
        const alloc = self.arena();
        const msg = std.json.parseFromSliceLeaky(Value, alloc, line, .{}) catch return;
        if (msg != .object) return;
        const id = asInteger(field(msg, "id"));
        const params = field(msg, "params");
        if (asString(field(msg, "method"))) |method| {
            if (id) |request_id| {
                self.handleRequest(alloc, request_id, method, params);
            } else {
                self.handleNotification(alloc, method, params);
            }
        } else if (id) |response_id| {
            self.settle(response_id, field(msg, "result"));
        }
    }

    fn handleRequest(self: *Runtime, alloc: std.mem.Allocator, id: i64, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "initialize")) {
            if (self.initialized) {
                // The one non-terminal protocol NAK: keep serving.
                self.sendResult(alloc, id, fail(alloc, "initialize may only be called once"));
                return;
            }
            const host_version = asInteger(field(params, "protocol_version")) orelse 0;
            if (host_version != protocol_version) {
                const message = std.fmt.allocPrint(
                    alloc,
                    "protocol version mismatch: host v{d}, plugin v{d}",
                    .{ host_version, protocol_version },
                ) catch "protocol version mismatch";
                var result = fail(alloc, message);
                put(alloc, &result, "protocol_version", .{ .integer = protocol_version });
                self.sendResult(alloc, id, result);
                std.process.exit(0); // already flushed: writes are raw syscalls
            }
            self.initialized = true;
            var result = ok(alloc);
            put(alloc, &result, "protocol_version", .{ .integer = protocol_version });
            self.sendResult(alloc, id, result);
            // AFTER the reply; running it synchronously is conformant —
            // a blocking single-threaded plugin never races a ping.
            if (self.handlers.on_start) |hook| hook(self, alloc);
            return;
        }
        if (std.mem.eql(u8, method, "ping")) {
            self.sendResult(alloc, id, ok(alloc));
            return;
        }
        if (std.mem.eql(u8, method, "evaluate")) {
            const answers: Value = if (self.handlers.on_evaluate) |hook|
                hook(self, alloc, params)
            else
                .{ .array = std.json.Array.init(alloc) };
            var result = ok(alloc);
            put(alloc, &result, "answers", answers);
            self.sendResult(alloc, id, result);
            return;
        }
        if (std.mem.eql(u8, method, "search")) {
            const rows: Value = if (self.handlers.on_search) |hook|
                hook(self, alloc, params)
            else
                .{ .array = std.json.Array.init(alloc) };
            var result = ok(alloc);
            put(alloc, &result, "rows", rows);
            self.sendResult(alloc, id, result);
            return;
        }
        if (std.mem.eql(u8, method, "hints")) {
            const reply: HintsReply = if (self.handlers.on_hints) |hook|
                hook(self, alloc, params)
            else
                .{ .targets = .{ .array = std.json.Array.init(alloc) } };
            var result = ok(alloc);
            put(alloc, &result, "targets", reply.targets);
            if (reply.context_pid) |pid| put(alloc, &result, "context_pid", .{ .integer = pid });
            self.sendResult(alloc, id, result);
            return;
        }
        if (std.mem.eql(u8, method, "perform")) {
            self.sendResult(alloc, id, self.perform(alloc, params));
            return;
        }
        const message = std.fmt.allocPrint(alloc, "unknown method: {s}", .{method}) catch "unknown method";
        self.sendResult(alloc, id, fail(alloc, message));
    }

    /// The single effect method's kind routing. An unregistered kind is
    /// "not mine" (the host may fall back); an unknown kind is an error
    /// (the host must not fall back on garbage).
    fn perform(self: *Runtime, alloc: std.mem.Allocator, params: Value) Value {
        const kind = asString(field(params, "kind")) orelse "";
        const registered: ?PerformFn = if (std.mem.eql(u8, kind, "resolve"))
            self.handlers.on_resolve
        else if (std.mem.eql(u8, kind, "command"))
            self.handlers.on_command
        else if (std.mem.eql(u8, kind, "action"))
            self.handlers.on_action
        else if (std.mem.eql(u8, kind, "navigate"))
            self.handlers.on_navigate
        else {
            const message = std.fmt.allocPrint(alloc, "unknown perform kind: {s}", .{kind}) catch "unknown perform kind";
            return fail(alloc, message);
        };
        const hook = registered orelse return unhandled(alloc);
        return hook(self, alloc, params);
    }

    fn handleNotification(self: *Runtime, alloc: std.mem.Allocator, method: []const u8, params: Value) void {
        if (std.mem.eql(u8, method, "event")) {
            if (self.handlers.on_event) |hook| {
                const name = asString(field(params, "name")) orelse "";
                hook(self, alloc, name, field(params, "payload"));
            }
            return;
        }
        // Unknown notifications are wire noise: ignored.
    }

    // ── Emitters ──

    /// Replace the plugin's entire catalog (push-based; the host owns the
    /// store). Every row carries the first-class "source" field naming a
    /// manifest sources[].name; an empty array is an authoritative empty.
    /// On a transient refresh failure, simply don't publish — the host
    /// keeps the last-good catalog.
    pub fn publish(self: *Runtime, alloc: std.mem.Allocator, rows: Value) void {
        var params: Value = .{ .object = .empty };
        put(alloc, &params, "rows", rows);
        self.sendNotification(alloc, "publish", params);
    }

    /// Feed manifest-declared status segments; "" clears one.
    pub fn status(self: *Runtime, alloc: std.mem.Allocator, segments: Value) void {
        var params: Value = .{ .object = .empty };
        put(alloc, &params, "segments", segments);
        self.sendNotification(alloc, "status", params);
    }

    /// Structured, content-free logging: counts, stages, elapsed ms —
    /// never query text or candidate data. `fields` null means none.
    pub fn log(self: *Runtime, alloc: std.mem.Allocator, level: []const u8, message: []const u8, fields: ?Value) void {
        var params: Value = .{ .object = .empty };
        put(alloc, &params, "level", .{ .string = level });
        put(alloc, &params, "message", .{ .string = message });
        put(alloc, &params, "fields", fields orelse .{ .object = .empty });
        self.sendNotification(alloc, "log", params);
    }

    // ── Serve internals ──

    fn run(self: *Runtime) void {
        while (true) {
            const line = self.readLine(null) orelse {
                if (self.eof) break;
                continue;
            };
            self.dispatchLine(line);
            _ = self.arena_state.reset(.retain_capacity);
        }
        // stdin EOF is the shutdown signal: cleanup, then exit 0 via main.
        if (self.handlers.on_shutdown) |hook| hook(self, self.arena());
    }
};

// ── Handlers ────────────────────────────────────────────────────────────

pub const PerformFn = *const fn (rt: *Runtime, arena: std.mem.Allocator, params: Value) Value;

pub const HintsReply = struct {
    /// Array Value of target objects.
    targets: Value,
    context_pid: ?i64 = null,
};

/// The plugin-provided hooks; every field is optional. Handlers receive
/// the runtime plus the dispatch arena their Values must be built from.
pub const Handlers = struct {
    /// Runs synchronously AFTER the initialize reply (the reply is
    /// immediate by contract) and typically ends with rt.publish(rows).
    on_start: ?*const fn (rt: *Runtime, arena: std.mem.Allocator) void = null,
    /// Runs after stdin EOF, before the process exits 0.
    on_shutdown: ?*const fn (rt: *Runtime, arena: std.mem.Allocator) void = null,
    on_event: ?*const fn (rt: *Runtime, arena: std.mem.Allocator, name: []const u8, payload: Value) void = null,
    /// evaluate: return the answers array (synchronous, CPU-only).
    on_evaluate: ?*const fn (rt: *Runtime, arena: std.mem.Allocator, params: Value) Value = null,
    /// search: return the rows array in catalog row shape.
    on_search: ?*const fn (rt: *Runtime, arena: std.mem.Allocator, params: Value) Value = null,
    /// hints: return targets plus an optional context pid.
    on_hints: ?*const fn (rt: *Runtime, arena: std.mem.Allocator, params: Value) HintsReply = null,
    /// The four perform kinds; an unregistered kind answers the canonical
    /// {"ok": false, "unhandled": true}.
    on_resolve: ?PerformFn = null,
    on_command: ?PerformFn = null,
    on_action: ?PerformFn = null,
    on_navigate: ?PerformFn = null,
};

// ── Reply helpers ───────────────────────────────────────────────────────

/// {"ok": true} — extend with put().
pub fn ok(arena: std.mem.Allocator) Value {
    var result: Value = .{ .object = .empty };
    put(arena, &result, "ok", .{ .bool = true });
    return result;
}

/// perform's "not my context" reply — the host MAY fall back.
pub fn unhandled(arena: std.mem.Allocator) Value {
    var result: Value = .{ .object = .empty };
    put(arena, &result, "ok", .{ .bool = false });
    put(arena, &result, "unhandled", .{ .bool = true });
    return result;
}

/// The ok:false error reply; keep messages content-free.
pub fn fail(arena: std.mem.Allocator, message: []const u8) Value {
    var result: Value = .{ .object = .empty };
    put(arena, &result, "ok", .{ .bool = false });
    put(arena, &result, "error", .{ .string = message });
    return result;
}

// ── Serve loop ──────────────────────────────────────────────────────────

/// Run the plugin: blocks until stdin EOF (the shutdown signal), runs the
/// on_shutdown hook, and returns so main exits 0.
pub fn serve(handlers: Handlers) void {
    var rt = Runtime.init(handlers);
    rt.run();
}
