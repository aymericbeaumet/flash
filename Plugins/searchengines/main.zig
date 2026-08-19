//! DuckDuckGo-style search bangs, in Zig (one of the six deliberately
//! non-Rust official plugins exercising the language-agnostic wire
//! protocol; see docs/plugin-protocol.md and AGENTS.md — Rust stays the
//! default).
//!
//! `@embedFile` replaces the Rust implementation's build.rs codegen: the
//! vendored bangs.tsv is embedded at compile time and parsed once at
//! startup. Every bang publishes as a kind="bang" candidate in the
//! `plugin:searchengines` warm catalog (so a typed `!goo` prefix-matches
//! `!google`), and the catch-all shebang routes `!<bang> <query>` to
//! /usr/bin/open with the query percent-encoded into the URL template.

const std = @import("std");
const fp = @import("flashplugin.zig");

const bangs_tsv = @embedFile("bangs.tsv");
const source_id = "plugin:searchengines";
const max_bangs = 4096;

const Bang = struct { trigger: []const u8, template: []const u8 };

var bangs_storage: [max_bangs]Bang = undefined;
var bangs: []Bang = &.{};

// Frame storage: inbound requests are small; outbound is dominated by the
// catalog snapshot (bang count × ~64 bytes), far under these bounds.
var in_storage: [1 << 20]u8 = undefined;
var out_storage: [1 << 20]u8 = undefined;
var arena_storage: [1 << 20]u8 = undefined;
var scratch_storage: [1 << 16]u8 = undefined;

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

fn sendCatalog(encoder: *fp.Encoder, id: fp.Value) void {
    encoder.len = 0;
    fp.beginResponse(encoder, id);
    encoder.mapHead(1);
    encoder.string("candidates");
    encoder.arrayHead(bangs.len);
    var title_buf: [128]u8 = undefined;
    for (bangs) |entry| {
        const title = std.fmt.bufPrint(&title_buf, "!{s}", .{entry.trigger}) catch continue;
        encoder.mapHead(2);
        encoder.string("title");
        encoder.string(title);
        encoder.string("metadata");
        encoder.mapHead(5);
        encoder.string("source");
        encoder.string("searchengines.bangs");
        encoder.string("source_id");
        encoder.string(source_id);
        encoder.string("kind");
        encoder.string("bang");
        encoder.string("subtitle");
        encoder.string("search engine bang");
        encoder.string("payload");
        encoder.string(entry.trigger);
    }
    fp.sendFrame(encoder);
}

fn invoke(encoder: *fp.Encoder, id: fp.Value, params: fp.Value) void {
    const subcommand = params.field("subcommand").asString() orelse "";
    var lower_buf: [64]u8 = undefined;
    if (subcommand.len > lower_buf.len) {
        return fp.sendError(encoder, id, "bang token too long");
    }
    const bang = std.ascii.lowerString(&lower_buf, subcommand);
    const template = lookup(bang) orelse {
        return fp.sendError(encoder, id, "unknown bang");
    };

    // Join args into the query, percent-encode, substitute {{{s}}}.
    var query_buf: [4096]u8 = undefined;
    var query_len: usize = 0;
    if (params.get("args")) |args| {
        switch (args) {
            .array => |items| for (items, 0..) |item, i| {
                const arg = item.asString() orelse continue;
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
    }
    const query = std.mem.trim(u8, query_buf[0..query_len], " ");
    var encoded_buf: [8192]u8 = undefined;
    const encoded = percentEncode(query, &encoded_buf);

    var url_buf: [16384:0]u8 = undefined;
    const url: [:0]const u8 = if (std.mem.indexOf(u8, template, "{{{s}}}")) |at|
        std.fmt.bufPrintZ(&url_buf, "{s}{s}{s}", .{
            template[0..at], encoded, template[at + 7 ..],
        }) catch return fp.sendError(encoder, id, "url too long")
    else
        std.fmt.bufPrintZ(&url_buf, "{s}", .{template}) catch
            return fp.sendError(encoder, id, "url too long");

    if (openUrl(url)) {
        fp.sendOk(encoder, id);
    } else {
        fp.sendError(encoder, id, "open failed");
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
    var encoder = fp.Encoder{ .buf = &out_storage };
    var scratch = fp.Encoder{ .buf = &scratch_storage };
    fp.sendLog(&scratch, "info", "[searchengines] bang table loaded");

    while (fp.readFrame(&in_storage)) |payload| {
        var fba = std.heap.FixedBufferAllocator.init(&arena_storage);
        var decoder = fp.Decoder{ .buf = payload, .arena = fba.allocator() };
        const msg = decoder.decode() catch continue;
        const method = msg.field("method").asString() orelse continue;
        const id = msg.field("id");
        const params = msg.field("params");

        if (std.mem.eql(u8, method, "initialize")) {
            const version = params.field("protocol_version").asInteger() orelse 0;
            if (version != fp.protocol_version) {
                fp.sendError(&encoder, id, "protocol version mismatch");
                return;
            }
            encoder.len = 0;
            fp.beginResponse(&encoder, id);
            encoder.mapHead(3);
            encoder.string("ok");
            encoder.boolean(true);
            encoder.string("protocol_version");
            encoder.integer(fp.protocol_version);
            encoder.string("published_sources");
            encoder.arrayHead(1);
            encoder.string(source_id);
            fp.sendFrame(&encoder);
        } else if (std.mem.eql(u8, method, "heartbeat")) {
            fp.sendOk(&encoder, id);
        } else if (std.mem.eql(u8, method, "shutdown")) {
            fp.sendOk(&encoder, id);
            return;
        } else if (std.mem.eql(u8, method, "sources.snapshot")) {
            sendCatalog(&encoder, id);
        } else if (std.mem.eql(u8, method, "command.invoke")) {
            invoke(&encoder, id, params);
        } else {
            switch (id) {
                .nil => {},
                else => fp.sendError(&encoder, id, "unsupported method"),
            }
        }
    }
}
