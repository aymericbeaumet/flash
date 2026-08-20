//! HTTP status code reference, in Zig (one of the deliberately non-Rust
//! official plugins exercising the language-agnostic wire protocol — v1
//! JSON lines, see docs/plugin-protocol.md and AGENTS.md — Rust stays the
//! default).
//!
//! Like the searchengines plugin, `@embedFile` bakes the vendored
//! statuses.tsv in at compile time and it is parsed once at startup, so the
//! warm catalog exists before `initialize` is answered and never changes at
//! runtime. Rows carry the MDN reference page as their openable URL; the
//! host owns opening it on selection, so this plugin needs no capabilities
//! and no host RPCs at all.

const std = @import("std");
const fp = @import("flashplugin");

const statuses_tsv = @embedFile("statuses.tsv");
const max_statuses = 128;

const Status = struct { code: []const u8, reason: []const u8, category: []const u8 };

var statuses_storage: [max_statuses]Status = undefined;
var statuses: []Status = &.{};

// Per-frame arena: inbound requests are small; the catalog snapshot reply
// (~60 rows × a few hundred bytes of Value tree) dominates, far under this.
var arena_storage: [1 << 20]u8 = undefined;

fn parseStatuses() void {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, statuses_tsv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.splitScalar(u8, line, '\t');
        const code = fields.next() orelse continue;
        const reason = fields.next() orelse continue;
        const category = fields.next() orelse continue;
        if (count == max_statuses) break;
        statuses_storage[count] = .{ .code = code, .reason = reason, .category = category };
        count += 1;
    }
    statuses = statuses_storage[0..count];
}

/// The `sources.snapshot` result: `{"candidates": [...]}`. Rows carry no
/// source_id — routing ids are host-stamped; `metadata.source` matches the
/// manifest's `sources[].name`, and `url` is the canonical openable
/// destination (the MDN reference page).
fn buildCatalog(arena: std.mem.Allocator) !fp.Value {
    var candidates = std.json.Array.init(arena);
    for (statuses) |status| {
        var metadata: fp.Value = .{ .object = .empty };
        try metadata.object.put(arena, "source", .{ .string = "httpstatus.codes" });
        try metadata.object.put(arena, "kind", .{ .string = "http_status" });
        const subtitle = try std.fmt.allocPrint(arena, "HTTP {s}", .{status.category});
        try metadata.object.put(arena, "subtitle", .{ .string = subtitle });
        try metadata.object.put(arena, "payload", .{ .string = status.code });
        var candidate: fp.Value = .{ .object = .empty };
        const title = try std.fmt.allocPrint(arena, "{s} {s}", .{ status.code, status.reason });
        try candidate.object.put(arena, "title", .{ .string = title });
        const url = try std.fmt.allocPrint(
            arena,
            "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/{s}",
            .{status.code},
        );
        try candidate.object.put(arena, "url", .{ .string = url });
        try candidate.object.put(arena, "metadata", metadata);
        try candidates.append(candidate);
    }
    var result: fp.Value = .{ .object = .empty };
    try result.object.put(arena, "candidates", .{ .array = candidates });
    return result;
}

pub fn main() void {
    parseStatuses();
    var fba = std.heap.FixedBufferAllocator.init(&arena_storage);
    fp.sendLog(fba.allocator(), "info", "[httpstatus] status table loaded");

    while (fp.readLine()) |line| {
        fba.reset();
        const arena = fba.allocator();
        const msg = fp.parseFrame(arena, line) orelse continue;
        const id = fp.asInteger(fp.field(msg, "id"));
        const method = fp.asString(fp.field(msg, "method")) orelse {
            // id-only frame: a response to one of our host RPCs (none today).
            if (id) |n| _ = fp.takePending(n);
            continue;
        };
        // Notifications ("event", ...) carry no id and are ignored silently;
        // id'd requests must never be dropped without a reply.
        const request_id = id orelse continue;
        const params = fp.field(msg, "params");

        if (std.mem.eql(u8, method, "initialize")) {
            const version = fp.asInteger(fp.field(params, "protocol_version")) orelse 0;
            if (version != fp.protocol_version) {
                fp.sendError(arena, request_id, "protocol version mismatch");
                return;
            }
            // The status table was parsed before the serve loop, so the
            // "warm catalog exists before initialize replies" contract
            // holds by construction.
            var result: fp.Value = .{ .object = .empty };
            result.object.put(arena, "ok", .{ .bool = true }) catch continue;
            result.object.put(arena, "protocol_version", .{ .integer = fp.protocol_version }) catch continue;
            fp.sendResult(arena, request_id, result);
        } else if (std.mem.eql(u8, method, "heartbeat")) {
            fp.sendOk(arena, request_id);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            fp.sendOk(arena, request_id);
            return;
        } else if (std.mem.eql(u8, method, "sources.snapshot")) {
            if (buildCatalog(arena)) |result| {
                fp.sendResult(arena, request_id, result);
            } else |_| {
                fp.sendError(arena, request_id, "catalog build failed");
            }
        } else {
            const message = std.fmt.allocPrint(arena, "unsupported method {s}", .{method}) catch
                "unsupported method";
            fp.sendError(arena, request_id, message);
        }
    }
}
