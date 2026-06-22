//! Panthera - Performant SIMD-accelerated serializer/deserializer framework.
//!
//! Like serde, panthera provides a unified frontend for multiple format backends.
//! Each backend (json, yaml, …) implements the same API:
//! `parseValue`, `parseFromSlice`, `parseFree`, and `stringify`.
//!
//! ## Format-specific API
//!
//! ```zig
//! const cfg  = try panthera.json.parseFromSlice(Config, allocator, json_str, .{});
//! const cfg2 = try panthera.yaml.parseFromSlice(Config, allocator, yaml_str, .{});
//! ```
//!
//! ## Backwards-compatible JSON shortcut
//!
//! The root module also re-exports the JSON backend directly:
//!
//! ```zig
//! const cfg = try panthera.parseFromSlice(Config, allocator, json_str, .{});
//! ```
//!
//! ## Adding a new format
//!
//! 1. Create `src/<name>.zig` that exports the required symbols
//! 2. Create `src/<name>/parser.zig` and `src/<name>/stringify.zig`
//! 3. Re-export from `src/<name>.zig`
//! 4. Add `pub const <name> = @import("<name>.zig");` below

const std = @import("std");
const ArenaAllocator = std.heap.ArenaAllocator;

const types = @import("types.zig");
const simd = @import("simd.zig");
const format_mod = @import("format.zig");

// ── Format backends ────────────────────────────────────────────────────────

pub const json   = @import("json.zig");
pub const yaml   = @import("yaml.zig");
pub const format = format_mod;

// ── Shared types ───────────────────────────────────────────────────────────

pub const MAX_DEPTH        = types.MAX_DEPTH;
pub const MAX_TOKEN_LEN    = types.MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES  = types.MAX_INPUT_BYTES;

pub const Error            = types.Error;
pub const StringifyOptions = types.StringifyOptions;
pub const ParseOptions     = types.ParseOptions;
pub const ObjectMap        = types.ObjectMap;
pub const Array            = types.Array;
pub const Value            = types.Value;

pub const simdParseU64Decimal = simd.simdParseU64Decimal;
pub const SpaceScanner        = simd.SpaceScanner;

// ── Backwards-compatible JSON shortcuts ────────────────────────────────────

pub const parseValue     = json.parseValue;
pub const parseFromSlice = json.parseFromSlice;
pub const parseFree      = json.parseFree;
pub const parse          = json.parse;
pub const stringify      = json.stringify;
pub const decodeString   = json.decodeString;

pub const Tokenizer      = json.Tokenizer;
pub const TokenTag       = json.TokenTag;
pub const Token          = json.Token;

// ── Tests ──────────────────────────────────────────────────────────────────

test "format: json backend verification" {
    _ = json;
}

test "format: yaml backend verification" {
    _ = yaml;
}

test "skipWhitespace: all" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 6), sc.nextNonSpace("   \t\n\r", 0));
}

test "skipWhitespace: mixed" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 2), sc.nextNonSpace("  hello", 0));
}

test "json: tokenizer literals" {
    var tok = try Tokenizer.init("true false null");
    try std.testing.expectEqual(TokenTag.true_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.false_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.null_lit, ((try tok.next()).?).tag);
    try std.testing.expect((try tok.next()) == null);
}

test "json: tokenizer string escape" {
    var tok = try Tokenizer.init("\"hello\\nworld\"");
    const t = (try tok.next()).?;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello\nworld", try decodeString(t.slice, &buf));
}

test "json: tokenizer numbers" {
    var tok = try Tokenizer.init("-42 3.14e2");
    try std.testing.expectEqualStrings("-42", ((try tok.next()).?).slice);
    try std.testing.expectEqualStrings("3.14e2", ((try tok.next()).?).slice);
}

test "json: parseValue object" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "{\"a\":1,\"b\":true,\"c\":null}");
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try std.testing.expect((v.object.get("b") orelse return error.TestFailed).bool);
    try std.testing.expect((v.object.get("c") orelse return error.TestFailed) == .null);
}

test "json: parseValue nested array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "[[1,2],[3,4]]");
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].array.items[0].integer);
}

test "json: parseFromSlice struct" {
    const S = struct { name: []const u8, count: u32, ratio: f32, active: bool };
    const r = try json.parseFromSlice(S, std.testing.allocator,
        \\{"name":"test","count":7,"ratio":0.5,"active":true}
    , .{});
    defer json.parseFree(S, std.testing.allocator, r);
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(u32, 7), r.count);
    try std.testing.expect(r.active);
}

test "json: stringify roundtrip" {
    const S = struct { x: i32, y: f64, z: bool };
    const val = S{ .x = -3, .y = 1.5, .z = false };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify(val, .{}, &w);
    const back = try json.parseFromSlice(S, std.testing.allocator, w.buffered(), .{});
    defer json.parseFree(S, std.testing.allocator, back);
    try std.testing.expectEqual(val.x, back.x);
    try std.testing.expectEqual(val.z, back.z);
}

test "json: stringify escaping" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify("hello\nworld\t\"!", .{}, &w);
    try std.testing.expectEqualStrings("\"hello\\nworld\\t\\\"!\"", w.buffered());
}

test "json: stringify Value roundtrip" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "{\"foo\":[1,false,null]}");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify(v, .{}, &w);
    try std.testing.expect((try json.parseValue(arena.allocator(), w.buffered())) == .object);
}

test "json: error max depth" {
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
    try std.testing.expectError(error.MaxDepthExceeded, json.parseValue(arena.allocator(), buf[0..i]));
}

test "json: error invalid escape" {
    var tok = try Tokenizer.init("\"\\q\"");
    try std.testing.expectError(error.InvalidEscape, tok.next());
}

test "json: error trailing content" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedToken, json.parseValue(arena.allocator(), "{}garbage"));
}

test "json: simd integer parse" {
    try std.testing.expectEqual(@as(?u64, 12345), simdParseU64Decimal("12345"));
    try std.testing.expectEqual(@as(?u64, 0), simdParseU64Decimal("0"));
    try std.testing.expectEqual(@as(?u64, null), simdParseU64Decimal("123x5"));
    try std.testing.expectEqual(@as(?u64, 9999999999999999), simdParseU64Decimal("9999999999999999"));
}

test "yaml: parseValue simple scalar" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "hello");
    try std.testing.expectEqualStrings("hello", v.string);
}

test "yaml: parseValue integer" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "42");
    try std.testing.expectEqual(@as(i64, 42), v.integer);
}

test "yaml: parseValue boolean" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "true");
    try std.testing.expectEqual(true, v.bool);
}

test "yaml: parseValue null" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "null");
    try std.testing.expectEqual(.null, v);
}

test "yaml: parseValue flow mapping" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "{a: 1, b: 2}");
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
}

test "yaml: parseValue flow sequence" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "[1, 2, 3]");
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].integer);
}

test "yaml: parseValue block mapping" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\a: 1
        \\b: hello
    );
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try std.testing.expectEqualStrings("hello", (v.object.get("b") orelse return error.TestFailed).string);
}

test "yaml: parseValue block sequence" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\- 1
        \\- 2
        \\- 3
    );
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), v.array.items[1].integer);
}

test "yaml: parseValue nested block" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\name: test
        \\items:
        \\  - 1
        \\  - 2
    );
    try std.testing.expectEqualStrings("test", (v.object.get("name") orelse return error.TestFailed).string);
    const items = (v.object.get("items") orelse return error.TestFailed).array;
    try std.testing.expectEqual(@as(i64, 1), items.items[0].integer);
    try std.testing.expectEqual(@as(i64, 2), items.items[1].integer);
}

test "yaml: parseValue quoted strings" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "'single quoted'");
    try std.testing.expectEqualStrings("single quoted", v.string);
}

test "yaml: parseFromSlice struct" {
    const S = struct { name: []const u8, count: u32 };
    const r = try yaml.parseFromSlice(S, std.testing.allocator,
        \\name: test
        \\count: 7
    , .{});
    defer yaml.parseFree(S, std.testing.allocator, r);
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(u32, 7), r.count);
}

test "yaml: stringify roundtrip" {
    const S = struct { x: i32, y: f64 };
    const val = S{ .x = -3, .y = 1.5 };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try yaml.stringify(val, .{}, &w);
    const back = try yaml.parseFromSlice(S, std.testing.allocator, w.buffered(), .{});
    defer yaml.parseFree(S, std.testing.allocator, back);
    try std.testing.expectEqual(val.x, back.x);
}

test "yaml: stringify Value" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "hello: world");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try yaml.stringify(v, .{}, &w);
    const back = try yaml.parseValue(arena.allocator(), w.buffered());
    try std.testing.expectEqualStrings("world", (back.object.get("hello") orelse return error.TestFailed).string);
}

test "yaml: comments" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\# this is a comment
        \\key: value
        \\# another comment
    );
    try std.testing.expectEqualStrings("value", (v.object.get("key") orelse return error.TestFailed).string);
}

test "json backward compat: root parseValue" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"a\":1}");
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
}

test "json backward compat: root parseFromSlice" {
    const S = struct { x: i32 };
    const r = try parseFromSlice(S, std.testing.allocator, "{\"x\":42}", .{});
    defer parseFree(S, std.testing.allocator, r);
    try std.testing.expectEqual(@as(i32, 42), r.x);
}

test "json backward compat: root stringify" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(true, .{}, &w);
    try std.testing.expectEqualStrings("true", w.buffered());
}
