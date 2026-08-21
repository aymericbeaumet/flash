//! HTTP status code reference, in Zig (one of the deliberately non-Rust
//! official plugins exercising the language-agnostic wire protocol — v1
//! JSON lines, see docs/plugin-protocol.md and AGENTS.md — Rust stays the
//! default).
//!
//! Like the searchengines plugin, `@embedFile` bakes the vendored
//! statuses.tsv in at compile time; it is parsed once at startup and
//! published as the catalog right after `initialize` is answered — it
//! never changes at runtime. Rows carry the MDN reference page as their
//! openable URL; the host owns opening it on selection, so this plugin
//! needs no capabilities and no host RPCs at all.

const std = @import("std");
const fp = @import("flashplugin");

const statuses_tsv = @embedFile("statuses.tsv");
const max_statuses = 128;

const Status = struct { code: []const u8, reason: []const u8, category: []const u8 };

var statuses_storage: [max_statuses]Status = undefined;
var statuses: []Status = &.{};

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

/// Catalog rows for `publish`: the first-class `source` names the
/// manifest's sources[].name, and `url` is the canonical openable
/// destination (the MDN reference page).
fn buildRows(arena: std.mem.Allocator) !fp.Value {
    var rows = std.json.Array.init(arena);
    for (statuses) |status| {
        var metadata: fp.Value = .{ .object = .empty };
        try metadata.object.put(arena, "kind", .{ .string = "http_status" });
        const subtitle = try std.fmt.allocPrint(arena, "HTTP {s}", .{status.category});
        try metadata.object.put(arena, "subtitle", .{ .string = subtitle });
        try metadata.object.put(arena, "payload", .{ .string = status.code });
        var row: fp.Value = .{ .object = .empty };
        try row.object.put(arena, "source", .{ .string = "httpstatus.codes" });
        const title = try std.fmt.allocPrint(arena, "{s} {s}", .{ status.code, status.reason });
        try row.object.put(arena, "title", .{ .string = title });
        const url = try std.fmt.allocPrint(
            arena,
            "https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Status/{s}",
            .{status.code},
        );
        try row.object.put(arena, "url", .{ .string = url });
        try row.object.put(arena, "metadata", metadata);
        try rows.append(row);
    }
    return .{ .array = rows };
}

fn onStart(rt: *fp.Runtime, arena: std.mem.Allocator) void {
    const rows = buildRows(arena) catch {
        rt.log(arena, "warn", "[httpstatus] catalog build failed", null);
        return; // no publish on failure: the host keeps the last-good catalog
    };
    rt.publish(arena, rows);
    rt.log(arena, "info", "[httpstatus] status table published", null);
}

pub fn main() void {
    parseStatuses();
    fp.serve(.{ .on_start = onStart });
}
