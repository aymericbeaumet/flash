//! Conformance probe, in Zig. See ../README.md — the normative behavior
//! contract all seven per-language probes follow. Test fixture only: driven
//! by Scripts/plugin-protocol-spec.py --probes, never shipped.

const std = @import("std");
const fp = @import("flashplugin");

const source_name = "conformance.items";
const target_pid: i64 = 4242;

var last_event_buf: [256]u8 = undefined;
var last_event_len: usize = 0;

// ── helpers ─────────────────────────────────────────────────────────────

/// Linear scan of the libc environ block — the `env`/`env-has` probe
/// subcommands need arbitrary-name lookups, which is deliberately not SDK
/// surface. Config itself goes through fp.config() so the probe pins the
/// SDK accessor (the zig-0.16 getenv regression's permanent repro).
fn envValue(name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (std.c.environ[i]) |entry| : (i += 1) {
        const pair = std.mem.span(entry);
        const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
        if (std.mem.eql(u8, pair[0..eq], name)) return pair[eq + 1 ..];
    }
    return null;
}

/// The full parsed FLASH_PLUGIN_CONFIG object ({} when unset/invalid).
fn fullConfig(arena: std.mem.Allocator) fp.Value {
    return fp.config(arena);
}

fn confConfig(arena: std.mem.Allocator) fp.Value {
    return fp.field(fullConfig(arena), "conformance");
}

/// Minified JSON of `value` into an arena buffer of `cap` bytes — the
/// message-field encoder (std.json keeps non-ASCII raw by default).
fn jsonText(arena: std.mem.Allocator, value: fp.Value, cap: usize) ![]const u8 {
    const buf = try arena.alloc(u8, cap);
    var writer: std.Io.Writer = .fixed(buf);
    try std.json.Stringify.value(value, .{}, &writer);
    return writer.buffered();
}

fn argAt(params: fp.Value, index: usize) ?[]const u8 {
    return switch (fp.field(params, "args")) {
        .array => |items| if (index < items.items.len) fp.asString(items.items[index]) else null,
        else => null,
    };
}

fn intArg(params: fp.Value, index: usize, fallback: i64) i64 {
    const raw = argAt(params, index) orelse return fallback;
    return std.fmt.parseInt(i64, raw, 10) catch fallback;
}

fn okMessage(arena: std.mem.Allocator, message: []const u8) fp.Value {
    var reply = fp.ok(arena);
    fp.put(arena, &reply, "message", .{ .string = message });
    return reply;
}

fn okTargetPid(arena: std.mem.Allocator) fp.Value {
    var reply = fp.ok(arena);
    fp.put(arena, &reply, "target_pid", .{ .integer = target_pid });
    return reply;
}

fn sleepMs(ms: i64) void {
    if (ms <= 0) return;
    var ts: std.c.timespec = .{
        .sec = @intCast(@divTrunc(ms, 1000)),
        .nsec = @intCast(@mod(ms, 1000) * std.time.ns_per_ms),
    };
    var rem: std.c.timespec = undefined;
    while (std.c.nanosleep(&ts, &rem) != 0) ts = rem;
}

fn exitLater(code: u8) void {
    sleepMs(250);
    std.process.exit(code);
}

fn writeStderr(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(2, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

// ── fixed data ──────────────────────────────────────────────────────────

fn catalogRows(arena: std.mem.Allocator) !fp.Value {
    var rows = std.json.Array.init(arena);
    const conf = confConfig(arena);
    if (fp.asBool(fp.field(conf, "empty_catalog")) orelse false) {
        return .{ .array = rows };
    }
    if (fp.asInteger(fp.field(conf, "catalog_rows"))) |count| {
        const pad_len: usize = @intCast(fp.asInteger(fp.field(conf, "row_pad")) orelse 0);
        const pad = try arena.alloc(u8, pad_len);
        @memset(pad, 'x');
        var i: i64 = 1;
        while (i <= count) : (i += 1) {
            var row: fp.Value = .{ .object = .empty };
            try row.object.put(arena, "source", .{ .string = source_name });
            const title = try std.fmt.allocPrint(arena, "row-{d}{s}", .{ i, pad });
            try row.object.put(arena, "title", .{ .string = title });
            try rows.append(row);
        }
        return .{ .array = rows };
    }
    var alpha: fp.Value = .{ .object = .empty };
    try alpha.object.put(arena, "source", .{ .string = source_name });
    try alpha.object.put(arena, "title", .{ .string = "alpha" });
    var metadata: fp.Value = .{ .object = .empty };
    try metadata.object.put(arena, "k", .{ .string = "v1" });
    try alpha.object.put(arena, "metadata", metadata);
    try rows.append(alpha);
    var beta: fp.Value = .{ .object = .empty };
    try beta.object.put(arena, "source", .{ .string = source_name });
    try beta.object.put(arena, "title", .{ .string = "béta ⚡ 名前" });
    try rows.append(beta);
    var gamma: fp.Value = .{ .object = .empty };
    try gamma.object.put(arena, "source", .{ .string = source_name });
    try gamma.object.put(arena, "title", .{ .string = "gamma" });
    try gamma.object.put(arena, "url", .{ .string = "https://example.com/g" });
    var effect: fp.Value = .{ .object = .empty };
    try effect.object.put(arena, "type", .{ .string = "open" });
    try effect.object.put(arena, "url", .{ .string = "https://example.com/g" });
    try gamma.object.put(arena, "effect", effect);
    try rows.append(gamma);
    return .{ .array = rows };
}

fn answer(arena: std.mem.Allocator, title: []const u8, subtitle: ?[]const u8) !fp.Value {
    var out: fp.Value = .{ .object = .empty };
    try out.object.put(arena, "title", .{ .string = title });
    if (subtitle) |s| try out.object.put(arena, "subtitle", .{ .string = s });
    var effect: fp.Value = .{ .object = .empty };
    try effect.object.put(arena, "type", .{ .string = "copy_text" });
    try effect.object.put(arena, "text", .{ .string = title });
    try out.object.put(arena, "effect", effect);
    return out;
}

fn hintTarget(
    arena: std.mem.Allocator,
    id: []const u8,
    x: fp.Value,
    y: fp.Value,
    width: fp.Value,
    height: fp.Value,
    role: []const u8,
    label: []const u8,
) !fp.Value {
    var frame: fp.Value = .{ .object = .empty };
    try frame.object.put(arena, "x", x);
    try frame.object.put(arena, "y", y);
    try frame.object.put(arena, "width", width);
    try frame.object.put(arena, "height", height);
    var out: fp.Value = .{ .object = .empty };
    try out.object.put(arena, "id", .{ .string = id });
    try out.object.put(arena, "frame", frame);
    try out.object.put(arena, "role", .{ .string = role });
    try out.object.put(arena, "label", .{ .string = label });
    return out;
}

// ── handlers ────────────────────────────────────────────────────────────

fn onStart(rt: *fp.Runtime, arena: std.mem.Allocator) void {
    if (fp.asBool(fp.field(confConfig(arena), "skip_publish")) orelse false) return;
    const rows = catalogRows(arena) catch return;
    rt.publish(arena, rows);
}

fn onEvent(rt: *fp.Runtime, arena: std.mem.Allocator, name: []const u8, payload: fp.Value) void {
    _ = rt;
    _ = arena;
    _ = payload;
    const n = @min(name.len, last_event_buf.len);
    @memcpy(last_event_buf[0..n], name[0..n]);
    last_event_len = n;
}

fn onEvaluate(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    _ = rt;
    var answers = std.json.Array.init(arena);
    const query = fp.asString(fp.field(params, "query")) orelse "";
    if (std.mem.eql(u8, query, "conf:one")) {
        answers.append(answer(arena, "one", "s") catch return .{ .array = answers }) catch {};
    } else if (std.mem.eql(u8, query, "conf:unicode")) {
        answers.append(
            answer(arena, "héllo ⚡ 世界", null) catch return .{ .array = answers },
        ) catch {};
    } else if (std.mem.eql(u8, query, "conf:many")) {
        var i: usize = 1;
        while (i <= 17) : (i += 1) {
            const title = std.fmt.allocPrint(arena, "a{d}", .{i}) catch break;
            answers.append(answer(arena, title, null) catch break) catch break;
        }
    }
    return .{ .array = answers };
}

fn onSearch(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    _ = rt;
    var rows = std.json.Array.init(arena);
    const query = fp.asString(fp.field(params, "query")) orelse "";
    const all = catalogRows(arena) catch return .{ .array = rows };
    for (all.array.items) |row| {
        const title = fp.asString(fp.field(row, "title")) orelse continue;
        if (std.mem.indexOf(u8, title, query) != null) rows.append(row) catch {};
    }
    return .{ .array = rows };
}

fn onHints(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.HintsReply {
    _ = rt;
    _ = params;
    var targets = std.json.Array.init(arena);
    const empty: fp.HintsReply = .{ .targets = .{ .array = std.json.Array.init(arena) } };
    targets.append(hintTarget(
        arena,
        "t1",
        .{ .float = -10.5 },
        .{ .integer = 20 },
        .{ .integer = 30 },
        .{ .integer = 40 },
        "AXLink",
        "one",
    ) catch return empty) catch return empty;
    targets.append(hintTarget(
        arena,
        "t2",
        .{ .integer = 0 },
        .{ .integer = 0 },
        .{ .integer = 10 },
        .{ .integer = 10 },
        "FlashTerminalLink",
        "two",
    ) catch return empty) catch return empty;
    return .{ .targets = .{ .array = targets } };
}

fn onResolve(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    _ = rt;
    const title = fp.asString(fp.field(fp.field(params, "row"), "title")) orelse "";
    if (std.mem.eql(u8, title, "alpha")) return okTargetPid(arena);
    return fp.unhandled(arena);
}

fn onAction(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    _ = rt;
    const name = fp.asString(fp.field(params, "name")) orelse "";
    if (std.mem.eql(u8, name, "conf_performed")) return okTargetPid(arena);
    if (std.mem.eql(u8, name, "conf_failed")) return fp.fail(arena, "conformance failure probe");
    return fp.unhandled(arena);
}

fn onNavigate(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    _ = rt;
    const url = fp.asString(fp.field(params, "url")) orelse "";
    if (std.mem.eql(u8, url, "conformance://ok")) return fp.ok(arena);
    return fp.unhandled(arena);
}

/// One host-RPC arm: canonical params per ../README.md, reply message =
/// verbatim host result as JSON.
fn hostArm(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value, sub: []const u8) ?fp.Value {
    var call: fp.Value = .{ .object = .empty };
    var method: []const u8 = "";
    if (std.mem.eql(u8, sub, "ping")) {
        method = "host.ping";
    } else if (std.mem.eql(u8, sub, "fetch")) {
        method = "host.fetch";
        fp.put(arena, &call, "url", .{ .string = argAt(params, 0) orelse "" });
    } else if (std.mem.eql(u8, sub, "open")) {
        method = "host.open";
        fp.put(arena, &call, "url", .{ .string = argAt(params, 0) orelse "" });
    } else if (std.mem.eql(u8, sub, "clipboard")) {
        method = "host.clipboard_write";
        fp.put(arena, &call, "text", .{ .string = argAt(params, 0) orelse "" });
    } else if (std.mem.eql(u8, sub, "notify")) {
        method = "host.notify";
        fp.put(arena, &call, "message", .{ .string = argAt(params, 0) orelse "" });
    } else if (std.mem.eql(u8, sub, "storage-set")) {
        method = "host.storage_set";
        fp.put(arena, &call, "key", .{ .string = argAt(params, 0) orelse "" });
        fp.put(arena, &call, "value", .{ .string = argAt(params, 1) orelse "" });
    } else if (std.mem.eql(u8, sub, "storage-get")) {
        method = "host.storage_get";
        fp.put(arena, &call, "key", .{ .string = argAt(params, 0) orelse "" });
    } else if (std.mem.eql(u8, sub, "media")) {
        method = "host.post_media_key";
        fp.put(arena, &call, "key_code", .{ .integer = intArg(params, 0, 16) });
    } else if (std.mem.eql(u8, sub, "ps")) {
        method = "host.process_table";
    } else if (std.mem.eql(u8, sub, "signal")) {
        method = "host.signal";
        fp.put(arena, &call, "pid", .{ .integer = intArg(params, 0, target_pid) });
    } else if (std.mem.eql(u8, sub, "keys")) {
        method = "host.post_keys";
        fp.put(arena, &call, "pid", .{ .integer = target_pid });
        var chord: fp.Value = .{ .object = .empty };
        fp.put(arena, &chord, "key_code", .{ .integer = 4 });
        var modifiers = std.json.Array.init(arena);
        modifiers.append(.{ .string = "command" }) catch {};
        fp.put(arena, &chord, "modifiers", .{ .array = modifiers });
        var chords = std.json.Array.init(arena);
        chords.append(chord) catch {};
        fp.put(arena, &call, "keys", .{ .array = chords });
    } else if (std.mem.eql(u8, sub, "global-key")) {
        method = "host.post_global_key";
        fp.put(arena, &call, "key_code", .{ .integer = 4 });
        var modifiers = std.json.Array.init(arena);
        modifiers.append(.{ .string = "command" }) catch {};
        fp.put(arena, &call, "modifiers", .{ .array = modifiers });
    } else if (std.mem.eql(u8, sub, "ax-snapshot")) {
        method = "host.ax_snapshot";
        fp.put(arena, &call, "pid", .{ .integer = target_pid });
        fp.put(arena, &call, "roots", .{ .string = "app" });
    } else if (std.mem.eql(u8, sub, "activate")) {
        method = "host.activate";
        fp.put(arena, &call, "pid", .{ .integer = target_pid });
    } else if (std.mem.eql(u8, sub, "normal-mode-target")) {
        method = "host.normal_mode_target";
    } else {
        return null;
    }
    const result = rt.callHost(arena, method, call, null);
    const message = jsonText(arena, result, 1 << 20) catch
        return fp.fail(arena, "host result encode failed");
    return okMessage(arena, message);
}

fn onCommand(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    const sub = fp.asString(fp.field(params, "subcommand")) orelse "";
    if (std.mem.eql(u8, sub, "echo")) {
        var payload: fp.Value = .{ .object = .empty };
        fp.put(arena, &payload, "args", fp.field(params, "args"));
        fp.put(arena, &payload, "raw", .{
            .string = fp.asString(fp.field(params, "raw")) orelse "",
        });
        const message = jsonText(arena, payload, 8 << 20) catch
            return fp.fail(arena, "echo encode failed");
        return okMessage(arena, message);
    }
    if (std.mem.eql(u8, sub, "env")) {
        var env: fp.Value = .{ .object = .empty };
        var i: usize = 0;
        while (std.c.environ[i]) |entry| : (i += 1) {
            const pair = std.mem.span(entry);
            const eq = std.mem.indexOfScalar(u8, pair, '=') orelse continue;
            env.object.put(arena, pair[0..eq], .{ .string = pair[eq + 1 ..] }) catch {};
        }
        const message = jsonText(arena, env, 1 << 20) catch
            return fp.fail(arena, "env encode failed");
        return okMessage(arena, message);
    }
    if (std.mem.eql(u8, sub, "env-has")) {
        const name = argAt(params, 0) orelse "";
        const present = envValue(name) != null;
        return okMessage(arena, if (present) "present" else "absent");
    }
    if (std.mem.eql(u8, sub, "config")) {
        const message = jsonText(arena, fullConfig(arena), 1 << 20) catch
            return fp.fail(arena, "config encode failed");
        return okMessage(arena, message);
    }
    if (std.mem.eql(u8, sub, "state")) {
        const name = arena.dupe(u8, last_event_buf[0..last_event_len]) catch
            return fp.fail(arena, "state copy failed");
        return okMessage(arena, name);
    }
    if (std.mem.eql(u8, sub, "target-pid")) {
        return okTargetPid(arena);
    }
    if (std.mem.eql(u8, sub, "toast")) {
        return okMessage(arena, "hello from conformance");
    }
    if (std.mem.eql(u8, sub, "sleep")) {
        sleepMs(intArg(params, 0, 0));
        return fp.ok(arena);
    }
    if (std.mem.eql(u8, sub, "crash")) {
        std.process.exit(@intCast(intArg(params, 0, 1)));
    }
    if (std.mem.eql(u8, sub, "exit-after-reply")) {
        const code: u8 = @intCast(intArg(params, 0, 0));
        const thread = std.Thread.spawn(.{}, exitLater, .{code}) catch
            return fp.fail(arena, "exit thread spawn failed");
        thread.detach();
        return fp.ok(arena);
    }
    if (std.mem.eql(u8, sub, "stderr")) {
        const kib: usize = @intCast(intArg(params, 0, 0));
        const chunk = arena.alloc(u8, 1024) catch return fp.fail(arena, "stderr alloc failed");
        @memset(chunk, 'x');
        var remaining = kib;
        while (remaining > 0) : (remaining -= 1) writeStderr(chunk);
        return fp.ok(arena);
    }
    if (std.mem.eql(u8, sub, "log")) {
        const level = argAt(params, 0) orelse "info";
        var message = std.array_list.Managed(u8).init(arena);
        var index: usize = 1;
        while (argAt(params, index)) |word| : (index += 1) {
            if (index > 1) message.append(' ') catch break;
            message.appendSlice(word) catch break;
        }
        rt.log(arena, level, message.items, null);
        return fp.ok(arena);
    }
    if (std.mem.eql(u8, sub, "status")) {
        var segments: fp.Value = .{ .object = .empty };
        fp.put(arena, &segments, argAt(params, 0) orelse "", .{
            .string = argAt(params, 1) orelse "",
        });
        rt.status(arena, segments);
        return fp.ok(arena);
    }
    if (std.mem.eql(u8, sub, "publish-extra")) {
        var rows = (catalogRows(arena) catch return fp.fail(arena, "catalog build failed"));
        var delta: fp.Value = .{ .object = .empty };
        fp.put(arena, &delta, "source", .{ .string = source_name });
        fp.put(arena, &delta, "title", .{ .string = "delta" });
        rows.array.append(delta) catch return fp.fail(arena, "catalog append failed");
        rt.publish(arena, rows);
        return fp.ok(arena);
    }
    if (hostArm(rt, arena, params, sub)) |reply| {
        return reply;
    }
    const message = std.fmt.allocPrint(arena, "unsupported subcommand: {s}", .{sub}) catch
        "unsupported subcommand";
    return fp.fail(arena, message);
}

fn onShutdown(rt: *fp.Runtime, arena: std.mem.Allocator) void {
    rt.log(arena, "info", "conformance shutdown", null);
}

pub fn main() void {
    fp.serve(.{
        .on_start = onStart,
        .on_event = onEvent,
        .on_evaluate = onEvaluate,
        .on_search = onSearch,
        .on_hints = onHints,
        .on_resolve = onResolve,
        .on_command = onCommand,
        .on_action = onAction,
        .on_navigate = onNavigate,
        .on_shutdown = onShutdown,
    });
}
