//! Minimal Flash plugin protocol shim for Zig (stdlib only).
//!
//! Speaks the wire contract from docs/plugin-protocol.md: protocol v1,
//! newline-delimited JSON over stdio — one JSON object per `\n`-terminated
//! line, no envelope beyond id/method/params/result. Frame shapes: id+method
//! is a request, id alone is a response, method alone is a notification.
//! Host and plugin id counters are independent and may overlap, so responses
//! to plugin-initiated host RPCs are recognized through this shim's own
//! pending map (`callHost`/`takePending`). Uses raw POSIX read/write on
//! fds 0/1 and std.json both ways: inbound lines parse into `std.json.Value`
//! backed by a caller-supplied per-frame arena, and replies are built as
//! `std.json.Value` trees serialized with `std.json.Stringify` (values are
//! copied into the arena — no zero-copy framing).

const std = @import("std");

pub const protocol_version: i64 = 1;

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

/// Parse one inbound line into a Value living in `arena` (reset it per
/// frame); null when the line is not a JSON object.
pub fn parseFrame(arena: std.mem.Allocator, line: []const u8) ?Value {
    const v = std.json.parseFromSliceLeaky(Value, arena, line, .{}) catch return null;
    return switch (v) {
        .object => v,
        else => null,
    };
}

/// The plugin's `[plugin.<id>]` settings, delivered as a JSON object in
/// FLASH_PLUGIN_CONFIG; empty when unset or malformed.
pub fn config(arena: std.mem.Allocator) Value {
    const empty: Value = .{ .object = .empty };
    const raw = std.posix.getenv("FLASH_PLUGIN_CONFIG") orelse return empty;
    return parseFrame(arena, raw) orelse empty;
}

var in_storage: [1 << 20]u8 = undefined;
var in_len: usize = 0;
var in_pos: usize = 0;

/// Blocking read of the next `\n`-terminated line from stdin; null on EOF
/// (host gone) or an over-long line. Valid until the next call.
pub fn readLine() ?[]const u8 {
    while (true) {
        if (std.mem.indexOfScalarPos(u8, in_storage[0..in_len], in_pos, '\n')) |nl| {
            const line = in_storage[in_pos..nl];
            in_pos = nl + 1;
            return line;
        }
        if (in_pos > 0) {
            std.mem.copyForwards(u8, in_storage[0 .. in_len - in_pos], in_storage[in_pos..in_len]);
            in_len -= in_pos;
            in_pos = 0;
        }
        if (in_len == in_storage.len) return null;
        const n = std.c.read(0, in_storage[in_len..].ptr, in_storage.len - in_len);
        if (n <= 0) return null;
        in_len += @intCast(n);
    }
}

var out_storage: [1 << 20]u8 = undefined;

fn writeAll(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

/// Serialize one frame as a single minified JSON line onto stdout.
pub fn sendValue(v: Value) void {
    var writer: std.Io.Writer = .fixed(&out_storage);
    std.json.Stringify.value(v, .{}, &writer) catch return; // over-long frame: drop
    writer.writeByte('\n') catch return;
    writeAll(writer.buffered());
}

pub fn sendResult(arena: std.mem.Allocator, id: i64, result: Value) void {
    var frame: Value = .{ .object = .empty };
    frame.object.put(arena, "id", .{ .integer = id }) catch return;
    frame.object.put(arena, "result", result) catch return;
    sendValue(frame);
}

pub fn sendOk(arena: std.mem.Allocator, id: i64) void {
    var result: Value = .{ .object = .empty };
    result.object.put(arena, "ok", .{ .bool = true }) catch return;
    sendResult(arena, id, result);
}

pub fn sendError(arena: std.mem.Allocator, id: i64, message: []const u8) void {
    var result: Value = .{ .object = .empty };
    result.object.put(arena, "ok", .{ .bool = false }) catch return;
    result.object.put(arena, "error", .{ .string = message }) catch return;
    sendResult(arena, id, result);
}

pub fn sendNotification(arena: std.mem.Allocator, method: []const u8, params: Value) void {
    var frame: Value = .{ .object = .empty };
    frame.object.put(arena, "method", .{ .string = method }) catch return;
    frame.object.put(arena, "params", params) catch return;
    sendValue(frame);
}

pub fn sendLog(arena: std.mem.Allocator, level: []const u8, message: []const u8) void {
    var params: Value = .{ .object = .empty };
    params.object.put(arena, "level", .{ .string = level }) catch return;
    params.object.put(arena, "message", .{ .string = message }) catch return;
    params.object.put(arena, "fields", .{ .object = .empty }) catch return;
    sendNotification(arena, "flash.log", params);
}

const max_pending = 16;
var next_call_id: i64 = 1;
var pending_calls: [max_pending]i64 = undefined;
var pending_len: usize = 0;

/// Send a plugin→host RPC; returns the id whose eventual id-only response
/// frame `takePending` will claim, or null when the pending table is full.
pub fn callHost(arena: std.mem.Allocator, method: []const u8, params: Value) ?i64 {
    if (pending_len == max_pending) return null;
    const id = next_call_id;
    next_call_id += 1;
    var frame: Value = .{ .object = .empty };
    frame.object.put(arena, "id", .{ .integer = id }) catch return null;
    frame.object.put(arena, "method", .{ .string = method }) catch return null;
    frame.object.put(arena, "params", params) catch return null;
    pending_calls[pending_len] = id;
    pending_len += 1;
    sendValue(frame);
    return id;
}

/// Claim a response id if it belongs to one of our outstanding host calls.
pub fn takePending(id: i64) bool {
    for (pending_calls[0..pending_len], 0..) |pending_id, i| {
        if (pending_id == id) {
            pending_len -= 1;
            pending_calls[i] = pending_calls[pending_len];
            return true;
        }
    }
    return false;
}
