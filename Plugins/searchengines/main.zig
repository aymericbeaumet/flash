//! DuckDuckGo-style search bangs, in Zig (one of the six deliberately
//! non-Rust official plugins exercising the language-agnostic wire
//! protocol — v1 JSON lines, see docs/plugin-protocol.md and AGENTS.md —
//! Rust stays the default).
//!
//! `@embedFile` replaces the Rust implementation's build.rs codegen: the
//! vendored bangs.tsv is embedded at compile time and parsed once at
//! startup, so the warm catalog exists before `initialize` is answered.
//! Every bang publishes as a kind="bang" candidate in the warm catalog (so
//! a typed `!goo` prefix-matches `!google`), and the catch-all shebang
//! routes `!<bang> <query>` to /usr/bin/open with the query
//! percent-encoded into the URL template.

const std = @import("std");
const fp = @import("flashplugin.zig");

const bangs_tsv = @embedFile("bangs.tsv");
const max_bangs = 4096;

const Bang = struct { trigger: []const u8, template: []const u8 };

var bangs_storage: [max_bangs]Bang = undefined;
var bangs: []Bang = &.{};

// Per-frame arena: inbound requests are small; the catalog snapshot reply
// (bang count × a few hundred bytes of Value tree) dominates, far under
// this bound.
var arena_storage: [1 << 20]u8 = undefined;

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

/// The `sources.snapshot` result: `{"candidates": [...]}`. Rows carry no
/// source_id — routing ids are host-stamped; `metadata.source` matches the
/// manifest's `sources[].name`.
fn buildCatalog(arena: std.mem.Allocator) !fp.Value {
    var candidates = std.json.Array.init(arena);
    for (bangs) |entry| {
        var metadata: fp.Value = .{ .object = .empty };
        try metadata.object.put(arena, "source", .{ .string = "searchengines.bangs" });
        try metadata.object.put(arena, "kind", .{ .string = "bang" });
        try metadata.object.put(arena, "subtitle", .{ .string = "search engine bang" });
        try metadata.object.put(arena, "payload", .{ .string = entry.trigger });
        var candidate: fp.Value = .{ .object = .empty };
        const title = try std.fmt.allocPrint(arena, "!{s}", .{entry.trigger});
        try candidate.object.put(arena, "title", .{ .string = title });
        try candidate.object.put(arena, "metadata", metadata);
        try candidates.append(candidate);
    }
    var result: fp.Value = .{ .object = .empty };
    try result.object.put(arena, "candidates", .{ .array = candidates });
    return result;
}

fn invoke(arena: std.mem.Allocator, id: i64, params: fp.Value) void {
    const subcommand = fp.asString(fp.field(params, "subcommand")) orelse "";
    var lower_buf: [64]u8 = undefined;
    if (subcommand.len > lower_buf.len) {
        return fp.sendError(arena, id, "bang token too long");
    }
    const bang = std.ascii.lowerString(&lower_buf, subcommand);
    const template = lookup(bang) orelse {
        return fp.sendError(arena, id, "unknown bang");
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

    var url_buf: [16384:0]u8 = undefined;
    const url: [:0]const u8 = if (std.mem.indexOf(u8, template, "{{{s}}}")) |at|
        std.fmt.bufPrintZ(&url_buf, "{s}{s}{s}", .{
            template[0..at], encoded, template[at + 7 ..],
        }) catch return fp.sendError(arena, id, "url too long")
    else
        std.fmt.bufPrintZ(&url_buf, "{s}", .{template}) catch
            return fp.sendError(arena, id, "url too long");

    if (openUrl(url)) {
        fp.sendOk(arena, id);
    } else {
        fp.sendError(arena, id, "open failed");
    }
}

/// fork + execve of /usr/bin/open — Zig 0.16's std.process.Child needs the
/// new std.Io plumbing, which is far more machinery than one blocking
/// subprocess deserves.
fn openUrl(url: [:0]const u8) bool {
    const pid = std.c.fork();
    if (pid < 0) return false;
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ "/usr/bin/open", url.ptr };
        _ = std.c.execve("/usr/bin/open", &argv, std.c.environ);
        std.c._exit(127);
    }
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    return status == 0;
}

pub fn main() void {
    parseBangs();
    var fba = std.heap.FixedBufferAllocator.init(&arena_storage);
    fp.sendLog(fba.allocator(), "info", "[searchengines] bang table loaded");

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
            // The bang catalog was parsed before the serve loop, so the
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
        } else if (std.mem.eql(u8, method, "command.invoke")) {
            invoke(arena, request_id, params);
        } else {
            const message = std.fmt.allocPrint(arena, "unsupported method {s}", .{method}) catch
                "unsupported method";
            fp.sendError(arena, request_id, message);
        }
    }
}
