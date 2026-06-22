const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const json = @import("../spec/json/root.zig");
const types = @import("../types.zig");

const Tokenizer = json.Tokenizer;
const TokenTag = json.TokenTag;
const Error = types.Error;
const MAX_DEPTH = types.MAX_DEPTH;
const simdParseU64Decimal = @import("../simd.zig").simdParseU64Decimal;
const decodeString = json.decodeString;
const parseValue = json.parseValue;
const parseFromSlice = json.parseFromSlice;
const parseFree = json.parseFree;
const stringify = json.stringify;

test "json: tokenizer literals" {
    var tok = try Tokenizer.init("true false null");
    try testing.expectEqual(TokenTag.true_lit, ((try tok.next()).?).tag);
    try testing.expectEqual(TokenTag.false_lit, ((try tok.next()).?).tag);
    try testing.expectEqual(TokenTag.null_lit, ((try tok.next()).?).tag);
    try testing.expect((try tok.next()) == null);
}

test "json: tokenizer string escape" {
    var tok = try Tokenizer.init("\"hello\\nworld\"");
    const t = (try tok.next()).?;
    var buf: [32]u8 = undefined;
    try testing.expectEqualStrings("hello\nworld", try decodeString(t.slice, &buf));
}

test "json: tokenizer numbers" {
    var tok = try Tokenizer.init("-42 3.14e2");
    try testing.expectEqualStrings("-42", ((try tok.next()).?).slice);
    try testing.expectEqualStrings("3.14e2", ((try tok.next()).?).slice);
}

test "json: parseValue object" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "{\"a\":1,\"b\":true,\"c\":null}");
    try testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try testing.expect((v.object.get("b") orelse return error.TestFailed).bool);
    try testing.expect((v.object.get("c") orelse return error.TestFailed) == .null);
}

test "json: parseValue nested array" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "[[1,2],[3,4]]");
    try testing.expectEqual(@as(i64, 1), v.array.items[0].array.items[0].integer);
}

test "json: parseFromSlice struct" {
    const S = struct { name: []const u8, count: u32, ratio: f32, active: bool };
    const r = try json.parseFromSlice(S, testing.allocator,
        \\{"name":"test","count":7,"ratio":0.5,"active":true}
    , .{});
    defer json.parseFree(S, testing.allocator, r);
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(u32, 7), r.count);
    try testing.expect(r.active);
}

test "json: stringify roundtrip" {
    const S = struct { x: i32, y: f64, z: bool };
    const val = S{ .x = -3, .y = 1.5, .z = false };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify(val, .{}, &w);
    const back = try json.parseFromSlice(S, testing.allocator, w.buffered(), .{});
    defer json.parseFree(S, testing.allocator, back);
    try testing.expectEqual(val.x, back.x);
    try testing.expectEqual(val.z, back.z);
}

test "json: stringify escaping" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify("hello\nworld\t\"!", .{}, &w);
    try testing.expectEqualStrings("\"hello\\nworld\\t\\\"!\"", w.buffered());
}

test "json: stringify Value roundtrip" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try json.parseValue(arena.allocator(), "{\"foo\":[1,false,null]}");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try json.stringify(v, .{}, &w);
    try testing.expect((try json.parseValue(arena.allocator(), w.buffered())) == .object);
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
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.MaxDepthExceeded, json.parseValue(arena.allocator(), buf[0..i]));
}

test "json: error invalid escape" {
    var tok = try Tokenizer.init("\"\\q\"");
    try testing.expectError(error.InvalidEscape, tok.next());
}

test "json: error trailing content" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedToken, json.parseValue(arena.allocator(), "{}garbage"));
}

test "json: simd integer parse" {
    try testing.expectEqual(@as(?u64, 12345), simdParseU64Decimal("12345"));
    try testing.expectEqual(@as(?u64, 0), simdParseU64Decimal("0"));
    try testing.expectEqual(@as(?u64, null), simdParseU64Decimal("123x5"));
    try testing.expectEqual(@as(?u64, 9999999999999999), simdParseU64Decimal("9999999999999999"));
}

test "json backward compat: root parseValue" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"a\":1}");
    try testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
}

test "json backward compat: root parseFromSlice" {
    const S = struct { x: i32 };
    const r = try parseFromSlice(S, testing.allocator, "{\"x\":42}", .{});
    defer parseFree(S, testing.allocator, r);
    try testing.expectEqual(@as(i32, 42), r.x);
}

test "json backward compat: root stringify" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(true, .{}, &w);
    try testing.expectEqualStrings("true", w.buffered());
}
