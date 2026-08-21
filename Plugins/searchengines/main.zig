//! DuckDuckGo-style search bangs, in Zig (one of the six deliberately
//! non-Rust official plugins exercising the language-agnostic wire
//! protocol — v1 JSON lines, see docs/plugin-protocol.md and AGENTS.md —
//! Rust stays the default).
//!
//! `@embedFile` replaces the Rust implementation's build.rs codegen: the
//! vendored bangs.tsv is embedded at compile time, parsed once at startup,
//! and published as the catalog right after `initialize` is answered (so a
//! typed `!goo` prefix-matches `!google`). The catch-all bang routes
//! `!<bang> <query>` — arriving as perform {kind: "command"} with the bang
//! token as subcommand — to the host's `host.open` with the query
//! percent-encoded into the URL template. The callHost is awaited: ok is
//! reported only once the host's verdict for the open actually arrives,
//! never fire-and-forget.

const std = @import("std");
const fp = @import("flashplugin");

const bangs_tsv = @embedFile("bangs.tsv");
const max_bangs = 4096;

const Bang = struct { trigger: []const u8, template: []const u8 };

var bangs_storage: [max_bangs]Bang = undefined;
var bangs: []Bang = &.{};

fn parseBangs() void {
    var count: usize = 0;
    var lines = std.mem.splitScalar(u8, bangs_tsv, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const trigger = fields.next() orelse continue;
        const template = fields.next() orelse continue;
        if (count == max_bangs) break;
        // First trigger wins on a duplicate, matching the Rust build.rs.
        var duplicate = false;
        for (bangs_storage[0..count]) |existing| {
            if (std.mem.eql(u8, existing.trigger, trigger)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        bangs_storage[count] = .{ .trigger = trigger, .template = template };
        count += 1;
    }
    bangs = bangs_storage[0..count];
}

fn lookup(bang: []const u8) ?[]const u8 {
    for (bangs) |entry| {
        if (std.mem.eql(u8, entry.trigger, bang)) return entry.template;
    }
    return null;
}

/// Percent-encode `input` into `out` (RFC 3986 unreserved passthrough).
fn percentEncode(input: []const u8, out: []u8) []const u8 {
    var len: usize = 0;
    for (input) |byte| {
        const unreserved = switch (byte) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => true,
            else => false,
        };
        if (unreserved) {
            out[len] = byte;
            len += 1;
        } else {
            out[len] = '%';
            const hex = "0123456789ABCDEF";
            out[len + 1] = hex[byte >> 4];
            out[len + 2] = hex[byte & 0x0f];
            len += 3;
        }
        if (len + 4 > out.len) break;
    }
    return out[0..len];
}

/// Catalog rows for `publish`: every bang as a kind="bang" row, each
/// carrying the first-class `source` naming the manifest's sources[].name.
fn buildRows(arena: std.mem.Allocator) !fp.Value {
    var rows = std.json.Array.init(arena);
    for (bangs) |entry| {
        var metadata: fp.Value = .{ .object = .empty };
        try metadata.object.put(arena, "kind", .{ .string = "bang" });
        try metadata.object.put(arena, "subtitle", .{ .string = "search engine bang" });
        try metadata.object.put(arena, "payload", .{ .string = entry.trigger });
        var row: fp.Value = .{ .object = .empty };
        try row.object.put(arena, "source", .{ .string = "searchengines.bangs" });
        const title = try std.fmt.allocPrint(arena, "!{s}", .{entry.trigger});
        try row.object.put(arena, "title", .{ .string = title });
        try row.object.put(arena, "metadata", metadata);
        try rows.append(row);
    }
    return .{ .array = rows };
}

fn onStart(rt: *fp.Runtime, arena: std.mem.Allocator) void {
    const rows = buildRows(arena) catch {
        rt.log(arena, "warn", "[searchengines] catalog build failed", null);
        return; // no publish on failure: the host keeps the last-good catalog
    };
    rt.publish(arena, rows);
    rt.log(arena, "info", "[searchengines] bang table published", null);
}

fn onCommand(rt: *fp.Runtime, arena: std.mem.Allocator, params: fp.Value) fp.Value {
    const subcommand = fp.asString(fp.field(params, "subcommand")) orelse "";
    var lower_buf: [64]u8 = undefined;
    if (subcommand.len > lower_buf.len) {
        return fp.fail(arena, "bang token too long");
    }
    const bang = std.ascii.lowerString(&lower_buf, subcommand);
    const template = lookup(bang) orelse {
        return fp.fail(arena, "unknown bang");
    };

    // Join args into the query, percent-encode, substitute {{{s}}}.
    var query_buf: [4096]u8 = undefined;
    var query_len: usize = 0;
    switch (fp.field(params, "args")) {
        .array => |items| for (items.items, 0..) |item, i| {
            const arg = fp.asString(item) orelse continue;
            if (i > 0 and query_len + 1 < query_buf.len) {
                query_buf[query_len] = ' ';
                query_len += 1;
            }
            const take = @min(arg.len, query_buf.len - query_len);
            @memcpy(query_buf[query_len .. query_len + take], arg[0..take]);
            query_len += take;
        },
        else => {},
    }
    const query = std.mem.trim(u8, query_buf[0..query_len], " ");
    var encoded_buf: [8192]u8 = undefined;
    const encoded = percentEncode(query, &encoded_buf);

    var url_buf: [16384]u8 = undefined;
    const url: []const u8 = if (std.mem.indexOf(u8, template, "{{{s}}}")) |at|
        std.fmt.bufPrint(&url_buf, "{s}{s}{s}", .{
            template[0..at], encoded, template[at + 7 ..],
        }) catch return fp.fail(arena, "url too long")
    else
        template;

    // LaunchServices runs host-side (`host.open`), so this plugin needs no
    // fork/exec allowance. The callHost BLOCKS on the host's verdict — the
    // reply below is honest, sent only after the open actually settled.
    var open_params: fp.Value = .{ .object = .empty };
    fp.put(arena, &open_params, "url", .{ .string = url });
    const reply = rt.callHost(arena, "host.open", open_params, null);
    if (fp.asBool(fp.field(reply, "ok")) orelse false) {
        return fp.ok(arena);
    }
    return fp.fail(arena, fp.asString(fp.field(reply, "error")) orelse "host.open failed");
}

pub fn main() void {
    parseBangs();
    fp.serve(.{ .on_start = onStart, .on_command = onCommand });
}
