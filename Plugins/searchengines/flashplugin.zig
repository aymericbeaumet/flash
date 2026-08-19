//! Minimal Flash plugin protocol shim for Zig (stdlib only).
//!
//! Speaks the wire contract from docs/plugin-protocol.md: length-prefixed
//! MessagePack over stdio (4-byte big-endian length + one value) and the
//! protocol v3 lifecycle, including the warm-catalog side (publish before
//! ready, answer `sources.snapshot` from memory). Uses raw POSIX
//! read/write on fds 0/1 and fixed buffers, so it stays insulated from
//! std.Io churn across Zig releases. Decoded strings are zero-copy slices
//! into the frame buffer, valid until the next frame.

const std = @import("std");

pub const protocol_version: i64 = 3;

pub const KV = struct { key: []const u8, value: Value };

pub const nil_value: Value = .nil;

pub const Value = union(enum) {
    nil,
    boolean: bool,
    integer: i64,
    string: []const u8,
    array: []Value,
    map: []KV,

    /// Map lookup that folds a miss to nil — chainable:
    /// `msg.field("params").field("subcommand").asString()`.
    pub fn field(self: Value, key: []const u8) Value {
        return self.get(key) orelse nil_value;
    }

    pub fn get(self: Value, key: []const u8) ?Value {
        switch (self) {
            .map => |entries| {
                for (entries) |entry| {
                    if (std.mem.eql(u8, entry.key, key)) return entry.value;
                }
                return null;
            },
            else => return null,
        }
    }

    pub fn asString(self: Value) ?[]const u8 {
        return switch (self) {
            .string => |s| s,
            else => null,
        };
    }

    pub fn asInteger(self: Value) ?i64 {
        return switch (self) {
            .integer => |n| n,
            else => null,
        };
    }
};

pub const DecodeError = error{ Malformed, OutOfMemory };

pub const Decoder = struct {
    buf: []const u8,
    pos: usize = 0,
    arena: std.mem.Allocator,

    fn byte(self: *Decoder) DecodeError!u8 {
        if (self.pos >= self.buf.len) return error.Malformed;
        const b = self.buf[self.pos];
        self.pos += 1;
        return b;
    }

    fn take(self: *Decoder, n: usize) DecodeError![]const u8 {
        if (self.pos + n > self.buf.len) return error.Malformed;
        const out = self.buf[self.pos .. self.pos + n];
        self.pos += n;
        return out;
    }

    fn beInt(self: *Decoder, comptime T: type) DecodeError!T {
        const raw = try self.take(@sizeOf(T));
        return std.mem.readInt(T, raw[0..@sizeOf(T)], .big);
    }

    pub fn decode(self: *Decoder) DecodeError!Value {
        const b = try self.byte();
        if (b == 0xc0) return .nil;
        if (b == 0xc2) return .{ .boolean = false };
        if (b == 0xc3) return .{ .boolean = true };
        if (b <= 0x7f) return .{ .integer = b };
        if (b >= 0xe0) return .{ .integer = @as(i64, @as(i8, @bitCast(b))) };
        if (b >= 0xa0 and b <= 0xbf) return .{ .string = try self.take(b & 0x1f) };
        switch (b) {
            0xd9 => return .{ .string = try self.take(try self.byte()) },
            0xda => return .{ .string = try self.take(try self.beInt(u16)) },
            0xdb => return .{ .string = try self.take(try self.beInt(u32)) },
            0xcc => return .{ .integer = try self.byte() },
            0xcd => return .{ .integer = try self.beInt(u16) },
            0xce => return .{ .integer = try self.beInt(u32) },
            0xcf => return .{ .integer = @bitCast(try self.beInt(u64)) },
            0xd0 => return .{ .integer = @as(i8, @bitCast(try self.byte())) },
            0xd1 => return .{ .integer = @as(i16, @bitCast(try self.beInt(u16))) },
            0xd2 => return .{ .integer = @as(i32, @bitCast(try self.beInt(u32))) },
            0xd3 => return .{ .integer = @bitCast(try self.beInt(u64)) },
            else => {},
        }
        var count: usize = 0;
        var is_map = false;
        if (b >= 0x80 and b <= 0x8f) {
            count = b & 0x0f;
            is_map = true;
        } else if (b == 0xde) {
            count = try self.beInt(u16);
            is_map = true;
        } else if (b == 0xdf) {
            count = try self.beInt(u32);
            is_map = true;
        } else if (b >= 0x90 and b <= 0x9f) {
            count = b & 0x0f;
        } else if (b == 0xdc) {
            count = try self.beInt(u16);
        } else if (b == 0xdd) {
            count = try self.beInt(u32);
        } else {
            return error.Malformed;
        }
        if (is_map) {
            const entries = try self.arena.alloc(KV, count);
            for (entries) |*entry| {
                const key = try self.decode();
                entry.key = key.asString() orelse return error.Malformed;
                entry.value = try self.decode();
            }
            return .{ .map = entries };
        }
        const items = try self.arena.alloc(Value, count);
        for (items) |*item| item.* = try self.decode();
        return .{ .array = items };
    }
};

/// Growable encode buffer over a fixed allocator-free window: the caller
/// supplies storage sized for the largest frame it will ever emit.
pub const Encoder = struct {
    buf: []u8,
    len: usize = 0,

    fn push(self: *Encoder, bytes: []const u8) void {
        std.debug.assert(self.len + bytes.len <= self.buf.len);
        @memcpy(self.buf[self.len .. self.len + bytes.len], bytes);
        self.len += bytes.len;
    }

    fn pushByte(self: *Encoder, b: u8) void {
        self.push(&[_]u8{b});
    }

    fn pushBe(self: *Encoder, comptime T: type, value: T) void {
        var raw: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &raw, value, .big);
        self.push(&raw);
    }

    pub fn nil(self: *Encoder) void {
        self.pushByte(0xc0);
    }

    pub fn boolean(self: *Encoder, value: bool) void {
        self.pushByte(if (value) 0xc3 else 0xc2);
    }

    pub fn integer(self: *Encoder, value: i64) void {
        if (value >= 0 and value <= 127) {
            self.pushByte(@intCast(value));
        } else if (value < 0 and value >= -32) {
            self.pushByte(@bitCast(@as(i8, @intCast(value))));
        } else {
            self.pushByte(0xd3);
            self.pushBe(u64, @bitCast(value));
        }
    }

    pub fn string(self: *Encoder, value: []const u8) void {
        if (value.len < 32) {
            self.pushByte(0xa0 | @as(u8, @intCast(value.len)));
        } else {
            self.pushByte(0xdb);
            self.pushBe(u32, @intCast(value.len));
        }
        self.push(value);
    }

    pub fn mapHead(self: *Encoder, count: usize) void {
        if (count < 16) {
            self.pushByte(0x80 | @as(u8, @intCast(count)));
        } else {
            self.pushByte(0xde);
            self.pushBe(u16, @intCast(count));
        }
    }

    pub fn arrayHead(self: *Encoder, count: usize) void {
        if (count < 16) {
            self.pushByte(0x90 | @as(u8, @intCast(count)));
        } else {
            self.pushByte(0xdc);
            self.pushBe(u16, @intCast(count));
        }
    }
};

fn writeAll(bytes: []const u8) void {
    var written: usize = 0;
    while (written < bytes.len) {
        const n = std.c.write(1, bytes.ptr + written, bytes.len - written);
        if (n <= 0) return;
        written += @intCast(n);
    }
}

pub fn sendFrame(encoder: *const Encoder) void {
    var header: [4]u8 = undefined;
    std.mem.writeInt(u32, &header, @intCast(encoder.len), .big);
    writeAll(&header);
    writeAll(encoder.buf[0..encoder.len]);
}

/// Read one length-prefixed frame into `storage`; null on EOF (host gone).
pub fn readFrame(storage: []u8) ?[]const u8 {
    var header: [4]u8 = undefined;
    if (!readExact(&header)) return null;
    const n = std.mem.readInt(u32, &header, .big);
    if (n > storage.len) return null;
    const payload = storage[0..n];
    if (!readExact(payload)) return null;
    return payload;
}

fn readExact(out: []u8) bool {
    var got: usize = 0;
    while (got < out.len) {
        const n = std.c.read(0, out.ptr + got, out.len - got);
        if (n <= 0) return false;
        got += @intCast(n);
    }
    return true;
}

/// Envelope helpers shared by every response the plugin sends.
pub fn beginResponse(encoder: *Encoder, id: Value) void {
    encoder.mapHead(3);
    encoder.string("jsonrpc");
    encoder.string("2.0");
    encoder.string("id");
    switch (id) {
        .integer => |n| encoder.integer(n),
        .string => |s| encoder.string(s),
        else => encoder.nil(),
    }
    encoder.string("result");
}

pub fn sendOk(encoder: *Encoder, id: Value) void {
    encoder.len = 0;
    beginResponse(encoder, id);
    encoder.mapHead(1);
    encoder.string("ok");
    encoder.boolean(true);
    sendFrame(encoder);
}

pub fn sendError(encoder: *Encoder, id: Value, message: []const u8) void {
    encoder.len = 0;
    beginResponse(encoder, id);
    encoder.mapHead(2);
    encoder.string("ok");
    encoder.boolean(false);
    encoder.string("error");
    encoder.string(message);
    sendFrame(encoder);
}

pub fn sendLog(encoder: *Encoder, level: []const u8, message: []const u8) void {
    encoder.len = 0;
    encoder.mapHead(3);
    encoder.string("jsonrpc");
    encoder.string("2.0");
    encoder.string("method");
    encoder.string("flash.log");
    encoder.string("params");
    encoder.mapHead(3);
    encoder.string("level");
    encoder.string(level);
    encoder.string("message");
    encoder.string(message);
    encoder.string("fields");
    encoder.mapHead(0);
    sendFrame(encoder);
}
