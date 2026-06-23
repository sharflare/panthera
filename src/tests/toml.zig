const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const toml = @import("../spec/toml/root.zig");

test "toml: parseValue simple key-value" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "key = \"value\"\n");
    try testing.expectEqualStrings("value", v.object.get("key").?.string);
}

test "toml: parseValue integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "count = 42\n");
    try testing.expectEqual(@as(i64, 42), v.object.get("count").?.integer);
}

test "toml: parseValue float" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "pi = 3.14\n");
    try testing.expectApproxEqRel(@as(f64, 3.14), v.object.get("pi").?.float, 1e-9);
}

test "toml: parseValue boolean" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "flag = true\n");
    try testing.expectEqual(true, v.object.get("flag").?.bool);
}

test "toml: parseValue table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\[owner]
        \\name = "Alice"
        \\age = 30
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    const owner = v.object.get("owner").?.object;
    try testing.expectEqualStrings("Alice", owner.get("name").?.string);
    try testing.expectEqual(@as(i64, 30), owner.get("age").?.integer);
}

test "toml: parseValue array" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "nums = [1, 2, 3]\n");
    const arr = v.object.get("nums").?.array;
    try testing.expectEqual(@as(usize, 3), arr.items.len);
    try testing.expectEqual(@as(i64, 1), arr.items[0].integer);
    try testing.expectEqual(@as(i64, 2), arr.items[1].integer);
    try testing.expectEqual(@as(i64, 3), arr.items[2].integer);
}

test "toml: parseValue array of tables" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\[[products]]
        \\name = "Hammer"
        \\sku = 738594937
        \\
        \\[[products]]
        \\name = "Nail"
        \\sku = 284758393
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    const products = v.object.get("products").?.array;
    try testing.expectEqual(@as(usize, 2), products.items.len);
    try testing.expectEqualStrings("Hammer", products.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("Nail", products.items[1].object.get("name").?.string);
}

test "toml: parseValue dotted key" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "a.b.c = 1\n");
    const a = v.object.get("a").?.object;
    const b = a.get("b").?.object;
    try testing.expectEqual(@as(i64, 1), b.get("c").?.integer);
}

test "toml: parseValue negative integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = -42\n");
    try testing.expectEqual(@as(i64, -42), v.object.get("x").?.integer);
}

test "toml: parseValue hex integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 0xDEADBEEF\n");
    try testing.expectEqual(@as(i64, 0xDEADBEEF), v.object.get("x").?.integer);
}

test "toml: parseValue literal string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 'hello\\nworld'\n");
    try testing.expectEqualStrings("hello\\nworld", v.object.get("x").?.string);
}

test "toml: parseValue escaped string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = \"hello\\nworld\"\n");
    try testing.expectEqualStrings("hello\nworld", v.object.get("x").?.string);
}

test "toml: parseValue inline table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "point = {x = 1, y = 2}\n");
    const point = v.object.get("point").?.object;
    try testing.expectEqual(@as(i64, 1), point.get("x").?.integer);
    try testing.expectEqual(@as(i64, 2), point.get("y").?.integer);
}

test "toml: stringify simple struct" {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try toml.stringify(.{ .x = 1, .y = 2.5, .z = true }, .{}, &w);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "x = 1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "y = 2.5") != null);
    try testing.expect(std.mem.indexOf(u8, s, "z = true") != null);
}

test "toml: parseFromSlice typed struct" {
    const Config = struct {
        title: []const u8,
        count: i64,
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try toml.parseFromSlice(Config, arena.allocator(),
        "title = \"hello\"\ncount = 42\n", .{});
    defer toml.parseFree(Config, arena.allocator(), result);
    try testing.expectEqualStrings("hello", result.title);
    try testing.expectEqual(@as(i64, 42), result.count);
}

test "toml: parseValue datetime" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "d = 2024-01-15T12:30:00Z\n");
    try testing.expectEqualStrings("2024-01-15T12:30:00Z", v.object.get("d").?.string);
}

test "toml: parseValue local date" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "d = 2024-01-15\n");
    try testing.expectEqualStrings("2024-01-15", v.object.get("d").?.string);
}

test "toml: parseValue local time" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "t = 12:30:00\n");
    try testing.expectEqualStrings("12:30:00", v.object.get("t").?.string);
}

test "toml: parseValue with comments" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\# This is a comment
        \\key = "value" # inline comment
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    try testing.expectEqualStrings("value", v.object.get("key").?.string);
}

test "toml: parseValue quoted key" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "\"key with spaces\" = \"value\"\n");
    try testing.expectEqualStrings("value", v.object.get("key with spaces").?.string);
}

test "toml: parseValue nested table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\[a.b]
        \\c = 1
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    const a = v.object.get("a").?.object;
    const b = a.get("b").?.object;
    try testing.expectEqual(@as(i64, 1), b.get("c").?.integer);
}

test "toml: parseValue multiline basic string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\x = """
        \\hello
        \\world"""
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    try testing.expectEqualStrings("hello\nworld", v.object.get("x").?.string);
}

test "toml: parseValue multiline literal string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\x = '''
        \\hello
        \\world'''
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    try testing.expectEqualStrings("hello\nworld", v.object.get("x").?.string);
}

test "toml: parseValue binary integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 0b11010110\n");
    try testing.expectEqual(@as(i64, 0xD6), v.object.get("x").?.integer);
}

test "toml: parseValue octal integer" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 0o755\n");
    try testing.expectEqual(@as(i64, 0o755), v.object.get("x").?.integer);
}

test "toml: parseValue dotted keys with quoted parts" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "\"a\".\"b b\".c = 1\n");
    const a = v.object.get("a").?.object;
    const bb = a.get("b b").?.object;
    try testing.expectEqual(@as(i64, 1), bb.get("c").?.integer);
}

test "toml: parseValue special float inf" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = inf\n");
    try testing.expect(std.math.isInf(v.object.get("x").?.float));
}

test "toml: parseValue special float nan" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = nan\n");
    try testing.expect(std.math.isNan(v.object.get("x").?.float));
}

test "toml: parseValue special float positive inf" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = +inf\n");
    try testing.expect(std.math.isInf(v.object.get("x").?.float));
}

test "toml: parseValue special float negative inf" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = -inf\n");
    try testing.expectEqual(true, std.math.isInf(v.object.get("x").?.float) and v.object.get("x").?.float < 0);
}

test "toml: parseValue special float negative nan" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = -nan\n");
    try testing.expect(std.math.isNan(v.object.get("x").?.float));
}

test "toml: parseValue empty table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "[empty]\n");
    const empty = v.object.get("empty").?.object;
    try testing.expectEqual(@as(usize, 0), empty.keys().len);
}

test "toml: parseValue empty array" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = []\n");
    try testing.expectEqual(@as(usize, 0), v.object.get("x").?.array.items.len);
}

test "toml: stringify with special characters" {
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try toml.stringify(.{ .msg = "hello\nworld\t\"quoted\"" }, .{}, &w);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "msg = ") != null);
    try testing.expect(std.mem.indexOf(u8, s, "hello\\nworld\\t") != null);
    try testing.expect(std.mem.indexOf(u8, s, "\\\"quoted\\\"") != null);
}

test "toml: parseFromSlice typed struct with nested dotted key" {
    const Config = struct {
        a: struct { b: struct { c: i64 } },
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try toml.parseFromSlice(Config, arena.allocator(),
        "a.b.c = 42\n", .{});
    defer toml.parseFree(Config, arena.allocator(), result);
    try testing.expectEqual(@as(i64, 42), result.a.b.c);
}

test "toml: parseValue table array with inline table" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input =
        \\[[items]]
        \\name = "first"
        \\meta = {x = 1, y = 2}
        \\
        \\[[items]]
        \\name = "second"
    ;
    const v = try toml.parseValue(arena.allocator(), input);
    const items = v.object.get("items").?.array;
    try testing.expectEqual(@as(usize, 2), items.items.len);
    try testing.expectEqualStrings("first", items.items[0].object.get("name").?.string);
    try testing.expectEqual(@as(i64, 1), items.items[0].object.get("meta").?.object.get("x").?.integer);
    try testing.expectEqualStrings("second", items.items[1].object.get("name").?.string);
}

test "toml: parseValue integer with underscores" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 1_000_000\n");
    try testing.expectEqual(@as(i64, 1000000), v.object.get("x").?.integer);
}

test "toml: parseValue float with underscores" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try toml.parseValue(arena.allocator(), "x = 3.141_592\n");
    try testing.expectApproxEqRel(@as(f64, 3.141592), v.object.get("x").?.float, 1e-9);
}

test "toml: stringify nested struct as inline table" {
    const Config = struct {
        name: []const u8,
        point: struct { x: i64, y: i64 },
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try toml.stringify(Config{ .name = "origin", .point = .{ .x = 0, .y = 0 } }, .{}, &w);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "point = {") != null);
    try testing.expect(std.mem.indexOf(u8, s, "x = 0") != null);
    try testing.expect(std.mem.indexOf(u8, s, "y = 0") != null);
}

test "toml: stringify array of structs as table array" {
    const Config = struct {
        items: []const struct { name: []const u8, id: i64 },
    };
    const data = Config{ .items = &.{
        .{ .name = "first", .id = 1 },
        .{ .name = "second", .id = 2 },
    } };
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try toml.stringify(data, .{}, &w);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "[[items]]") != null);
    try testing.expect(std.mem.indexOf(u8, s, "first") != null);
    try testing.expect(std.mem.indexOf(u8, s, "second") != null);
    try testing.expect(std.mem.indexOf(u8, s, "id = 2") != null);
}

test "toml: stringify with whitespace indentation" {
    const Config = struct {
        x: i64,
        y: i64,
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try toml.stringify(Config{ .x = 1, .y = 2 }, .{ .whitespace = ' ' }, &w);
    const s = w.buffered();
    try testing.expect(std.mem.indexOf(u8, s, "x = 1") != null);
    try testing.expect(std.mem.indexOf(u8, s, "y = 2") != null);
}
