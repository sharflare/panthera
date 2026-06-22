const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const yaml = @import("../spec/yaml/root.zig");

test "yaml: parseValue simple scalar" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "hello");
    try testing.expectEqualStrings("hello", v.string);
}

test "yaml: parseValue integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "42");
    try testing.expectEqual(@as(i64, 42), v.integer);
}

test "yaml: parseValue boolean" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "true");
    try testing.expectEqual(true, v.bool);
}

test "yaml: parseValue null" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "null");
    try testing.expectEqual(.null, v);
}

test "yaml: parseValue flow mapping" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "{a: 1, b: 2}");
    try testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
}

test "yaml: parseValue flow sequence" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "[1, 2, 3]");
    try testing.expectEqual(@as(i64, 1), v.array.items[0].integer);
}

test "yaml: parseValue block mapping" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\a: 1
        \\b: hello
    );
    try testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try testing.expectEqualStrings("hello", (v.object.get("b") orelse return error.TestFailed).string);
}

test "yaml: parseValue block sequence" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\- 1
        \\- 2
        \\- 3
    );
    try testing.expectEqual(@as(i64, 1), v.array.items[0].integer);
    try testing.expectEqual(@as(i64, 2), v.array.items[1].integer);
}

test "yaml: parseValue nested block" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\name: test
        \\items:
        \\  - 1
        \\  - 2
    );
    try testing.expectEqualStrings("test", (v.object.get("name") orelse return error.TestFailed).string);
    const items = (v.object.get("items") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(i64, 1), items.items[0].integer);
    try testing.expectEqual(@as(i64, 2), items.items[1].integer);
}

test "yaml: parseValue quoted strings" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "'single quoted'");
    try testing.expectEqualStrings("single quoted", v.string);
}

test "yaml: parseFromSlice struct" {
    const S = struct { name: []const u8, count: u32 };
    const r = try yaml.parseFromSlice(S, testing.allocator,
        \\name: test
        \\count: 7
    , .{});
    defer yaml.parseFree(S, testing.allocator, r);
    try testing.expectEqualStrings("test", r.name);
    try testing.expectEqual(@as(u32, 7), r.count);
}

test "yaml: stringify roundtrip" {
    const S = struct { x: i32, y: f64 };
    const val = S{ .x = -3, .y = 1.5 };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try yaml.stringify(val, .{}, &w);
    const back = try yaml.parseFromSlice(S, testing.allocator, w.buffered(), .{});
    defer yaml.parseFree(S, testing.allocator, back);
    try testing.expectEqual(val.x, back.x);
}

test "yaml: stringify Value" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(), "hello: world");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try yaml.stringify(v, .{}, &w);
    const back = try yaml.parseValue(arena.allocator(), w.buffered());
    try testing.expectEqualStrings("world", (back.object.get("hello") orelse return error.TestFailed).string);
}

test "yaml: comments" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try yaml.parseValue(arena.allocator(),
        \\# this is a comment
        \\key: value
        \\# another comment
    );
    try testing.expectEqualStrings("value", (v.object.get("key") orelse return error.TestFailed).string);
}
