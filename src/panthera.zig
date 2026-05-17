//! Panthera - Performant SIMD-accelerated JSON serializer/deserializer in the vein of bytedance/sonic.
//!
//! ## Typed parsing
//!
//! Parse directly into a struct; Panthera allocates only for heap-backed fields
//! (strings, slices). Free with `parseFree` when done.
//!
//! ```zig
//! const panthera = @import("panthera");
//!
//! const Config = struct {
//!     host: []const u8,
//!     port: u16,
//!     debug: bool = false,
//!     tags: [][]const u8,
//! };
//!
//! const json =
//!     \\{"host":"localhost","port":8080,"tags":["web","api"]}
//! ;
//!
//! const cfg = try panthera.parseFromSlice(Config, allocator, json, .{});
//! defer panthera.parseFree(Config, allocator, cfg);
//!
//! std.debug.print("{s}:{d}\n", .{ cfg.host, cfg.port });
//! ```
//!
//! ## Untyped parsing
//!
//! When the shape isn't known at comptime, parse into a `Value` tree.
//! An `ArenaAllocator` makes cleanup a single `arena.deinit()`.
//!
//! ```zig
//! var arena = std.heap.ArenaAllocator.init(allocator);
//! defer arena.deinit();
//!
//! const v = try panthera.parseValue(arena.allocator(), json);
//!
//! const port = v.object.get("port") orelse return error.MissingField;
//! std.debug.print("port: {d}\n", .{port.integer});
//! ```
//!
//! ## Serialization
//!
//! `stringify` writes to any `std.Io.Writer`. Pass a non-null `whitespace`
//! indent width for pretty output.
//!
//! ```zig
//! var buf: [4096]u8 = undefined;
//! var w: std.Io.Writer = .fixed(&buf);
//!
//! try panthera.stringify(cfg, .{}, &w);               // compact
//! try panthera.stringify(cfg, .{ .whitespace = 2 }, &w); // pretty, 2-space indent
//!
//! std.debug.print("{s}\n", .{w.buffered()});
//! ```
//!
//! ## Parse options
//!
//! ```zig
//! const strict = panthera.ParseOptions{
//!     .reject_unknown_fields = true,  // error.UnknownField on unrecognised keys
//!     .require_all_fields    = true,  // error.MissingField if any field absent
//!     .duplicate_field_behavior = .reject, // error.DuplicateField on repeated keys
//! };
//!
//! const cfg2 = try panthera.parseFromSlice(Config, allocator, json, strict);
//! defer panthera.parseFree(Config, allocator, cfg2);
//! ```

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const types = @import("types.zig");
const parser = @import("parser.zig");
const stringify_mod = @import("stringify.zig");
const simd = @import("simd.zig");
const tokenizer_mod = @import("tokenizer.zig");

pub const MAX_DEPTH = types.MAX_DEPTH;
pub const MAX_TOKEN_LEN = types.MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

pub const Error = types.Error;
pub const StringifyOptions = types.StringifyOptions;
pub const ParseOptions = types.ParseOptions;
pub const ObjectMap = types.ObjectMap;
pub const Array = types.Array;
pub const Value = types.Value;

pub const parseValue = parser.parseValue;
pub const parseFromSlice = parser.parseFromSlice;
pub const parseFree = parser.parseFree;

/// Alias for `parseFromSlice`.
pub const parse = parseFromSlice;

pub const stringify = stringify_mod.stringify;

const Tokenizer = tokenizer_mod.Tokenizer;
const TokenTag = tokenizer_mod.TokenTag;
const decodeString = parser.decodeString;
const simdParseU64Decimal = simd.simdParseU64Decimal;
const SpaceScanner = simd.SpaceScanner;

test "skipWhitespace: all" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 6), sc.nextNonSpace("   \t\n\r", 0));
}

test "skipWhitespace: mixed" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 2), sc.nextNonSpace("  hello", 0));
}

test "tokenizer: literals" {
    var tok = try Tokenizer.init("true false null");
    try std.testing.expectEqual(TokenTag.true_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.false_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.null_lit, ((try tok.next()).?).tag);
    try std.testing.expect((try tok.next()) == null);
}

test "tokenizer: string escape" {
    var tok = try Tokenizer.init("\"hello\\nworld\"");
    const t = (try tok.next()).?;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello\nworld", try decodeString(t.slice, &buf));
}

test "tokenizer: numbers" {
    var tok = try Tokenizer.init("-42 3.14e2");
    try std.testing.expectEqualStrings("-42", ((try tok.next()).?).slice);
    try std.testing.expectEqualStrings("3.14e2", ((try tok.next()).?).slice);
}

test "parseValue: object" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"a\":1,\"b\":true,\"c\":null}");
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try std.testing.expect((v.object.get("b") orelse return error.TestFailed).bool);
    try std.testing.expect((v.object.get("c") orelse return error.TestFailed) == .null);
}

test "parseValue: nested array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "[[1,2],[3,4]]");
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].array.items[0].integer);
}

test "parseFromSlice: struct" {
    const S = struct { name: []const u8, count: u32, ratio: f32, active: bool };
    const r = try parseFromSlice(S, std.testing.allocator,
        \\{"name":"test","count":7,"ratio":0.5,"active":true}
    , .{});
    defer parseFree(S, std.testing.allocator, r);
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(u32, 7), r.count);
    try std.testing.expect(r.active);
}

test "stringify: roundtrip" {
    const S = struct { x: i32, y: f64, z: bool };
    const val = S{ .x = -3, .y = 1.5, .z = false };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(val, .{}, &w);
    const back = try parseFromSlice(S, std.testing.allocator, w.buffered(), .{});
    defer parseFree(S, std.testing.allocator, back);
    try std.testing.expectEqual(val.x, back.x);
    try std.testing.expectEqual(val.z, back.z);
}

test "stringify: escaping" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify("hello\nworld\t\"!", .{}, &w);
    try std.testing.expectEqualStrings("\"hello\\nworld\\t\\\"!\"", w.buffered());
}

test "stringify: Value roundtrip" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"foo\":[1,false,null]}");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(v, .{}, &w);
    try std.testing.expect((try parseValue(arena.allocator(), w.buffered())) == .object);
}

test "error: max depth" {
    var buf: [MAX_DEPTH * 2 + 8]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_DEPTH + 2) : (i += 1) buf[i] = '[';
    buf[i] = '1';
    i += 1;
    var j: usize = 0;
    while (j < MAX_DEPTH + 2) : (j += 1) {
        buf[i] = ']';
        i += 1;
    }
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MaxDepthExceeded, parseValue(arena.allocator(), buf[0..i]));
}

test "error: invalid escape" {
    var tok = try Tokenizer.init("\"\\q\"");
    try std.testing.expectError(error.InvalidEscape, tok.next());
}

test "error: trailing content" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedToken, parseValue(arena.allocator(), "{}garbage"));
}

test "simd: integer parse" {
    try std.testing.expectEqual(@as(?u64, 12345), simdParseU64Decimal("12345"));
    try std.testing.expectEqual(@as(?u64, 0), simdParseU64Decimal("0"));
    try std.testing.expectEqual(@as(?u64, null), simdParseU64Decimal("123x5"));
    try std.testing.expectEqual(@as(?u64, 9999999999999999), simdParseU64Decimal("9999999999999999"));
}
