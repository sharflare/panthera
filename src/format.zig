//! Format backend interface for panthera.
//!
//! Each format backend module must export these symbols:
//!
//! Required types:
//!   - `Value`         — shared tagged union (re-export from types.zig)
//!   - `Error`         — shared error set (re-export from types.zig)
//!   - `ParseOptions`    — per-format parse options
//!   - `StringifyOptions` — per-format stringify options
//!
//! Required functions:
//!   - `parseValue(allocator, input)        Error!Value`
//!   - `parseFromSlice(comptime T, allocator, input, opts) Error!T`
//!   - `parseFree(comptime T, allocator, value)    void`
//!   - `stringify(value, opts, writer)       Error!void`
//!
//! The root `panthera.zig` module exposes all formats as sub-modules
//! plus backwards-compatible re-exports of the JSON functions.
//!
//! ```zig
//! const panthera = @import("panthera");
//!
//! // Explicit format usage (new API):
//! const v = try panthera.json.parseValue(allocator, json_input);
//! const v = try panthera.yaml.parseValue(allocator, yaml_input);
//!
//! // Shortcut (defaults to JSON, backwards-compatible):
//! const v = try panthera.parseValue(allocator, json_input);
//! ```

const std = @import("std");
const types = @import("types.zig");
const ryu = @import("dragonbox.zig");

pub const Value = types.Value;
pub const Error = types.Error;

pub const DIGIT_TABLE: [200]u8 = blk: {
    var t: [200]u8 = undefined;
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        t[i * 2] = @as(u8, @intCast(i / 10)) + '0';
        t[i * 2 + 1] = @as(u8, @intCast(i % 10)) + '0';
    }
    break :blk t;
};

pub fn writeInt(self: anytype, v: i64) !void {
    var buf: [32]u8 = undefined;
    var i: usize = 32;
    const neg = v < 0;
    var n: u64 = @bitCast(if (neg) -v else v);
    while (n >= 100) {
        i -= 2;
        const pair = (n % 100) * 2;
        n /= 100;
        buf[i] = DIGIT_TABLE[pair];
        buf[i + 1] = DIGIT_TABLE[pair + 1];
    }
    if (n >= 10) {
        i -= 2;
        const pair = n * 2;
        buf[i] = DIGIT_TABLE[pair];
        buf[i + 1] = DIGIT_TABLE[pair + 1];
    } else {
        i -= 1;
        buf[i] = @as(u8, @intCast(n)) + '0';
    }
    if (neg) {
        i -= 1;
        buf[i] = '-';
    }
    try self.writeAll(buf[i..32]);
}

pub fn writeFloat(self: anytype, v: f64) !void {
    const Bw = struct {
        s: @TypeOf(self),
        pub fn writeAll(bw: @This(), data: []const u8) !void {
            try bw.s.writeAll(data);
        }
        pub fn writeByte(bw: @This(), b: u8) !void {
            try bw.s.writeByte(b);
        }
    };
    try ryu.writeFloat(Bw{ .s = self }, v);
}
