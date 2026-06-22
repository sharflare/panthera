const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const kdl = @import("../kdl.zig");
const Value = kdl.Value;

test "kdl: parseValue simple node" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 1 2 3");
    try testing.expectEqual(@as(usize, 1), v.array.items.len);
    const node = v.array.items[0].object;
    try testing.expectEqualStrings("foo", (node.get("name") orelse return error.TestFailed).string);
}

test "kdl: parseValue node with props" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo key=1 val=\"hello\"");
    const node = v.array.items[0].object;
    const props = (node.get("props") orelse return error.TestFailed).object;
    try testing.expectEqual(@as(i64, 1), (props.get("key") orelse return error.TestFailed).integer);
    try testing.expectEqualStrings("hello", (props.get("val") orelse return error.TestFailed).string);
}

test "kdl: parseValue node with children" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(),
        \\parent {
        \\  child1
        \\  child2
        \\}
    );
    const node = v.array.items[0].object;
    const children = (node.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 2), children.items.len);
}

test "kdl: parseValue booleans and null" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #true #false #null");
    const node = v.array.items[0].object;
    const args = (node.get("args") orelse return error.TestFailed).array;
    try testing.expectEqual(true, args.items[0].bool);
    try testing.expectEqual(false, args.items[1].bool);
    try testing.expectEqual(.null, args.items[2]);
}

test "kdl: parseValue quoted strings" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"hello world\"");
    const node = v.array.items[0].object;
    const args = (node.get("args") orelse return error.TestFailed).array;
    try testing.expectEqualStrings("hello world", args.items[0].string);
}

test "kdl: empty document" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "");
    try testing.expectEqual(@as(usize, 0), v.array.items.len);
}

test "kdl: multiple nodes" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(),
        \\node1
        \\node2
        \\node3
    );
    try testing.expectEqual(@as(usize, 3), v.array.items.len);
    try testing.expectEqualStrings("node1", v.array.items[0].object.get("name").?.string);
    try testing.expectEqualStrings("node2", v.array.items[1].object.get("name").?.string);
    try testing.expectEqualStrings("node3", v.array.items[2].object.get("name").?.string);
}

test "kdl: nodes separated by semicolons" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "a; b; c");
    try testing.expectEqual(@as(usize, 3), v.array.items.len);
}

test "kdl: line comment //" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(),
        \\foo // this is a comment
        \\bar
    );
    try testing.expectEqual(@as(usize, 2), v.array.items.len);
}

test "kdl: block comment /* */ between args" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 1 /* comment */ 2");
    try testing.expectEqual(@as(usize, 1), v.array.items.len);
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(usize, 2), args.items.len);
    try testing.expectEqual(@as(i64, 1), args.items[0].integer);
    try testing.expectEqual(@as(i64, 2), args.items[1].integer);
}

test "kdl: nested block comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo /* outer /* inner */ end */");
    try testing.expectEqual(@as(usize, 1), v.array.items.len);
}

test "kdl: slashdash comment /-" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(),
        \\foo /- this is a slashdash comment
        \\bar
    );
    try testing.expectEqual(@as(usize, 2), v.array.items.len);
}

test "kdl: type annotation on node" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "(person)employee name=\"Alice\"");
    const node = v.array.items[0].object;
    try testing.expectEqualStrings("person", (node.get("type") orelse return error.TestFailed).string);
    try testing.expectEqualStrings("employee", (node.get("name") orelse return error.TestFailed).string);
}

test "kdl: type annotation on argument" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo (i32)42");
    const node = v.array.items[0].object;
    const args = (node.get("args") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(i64, 42), args.items[0].integer);
}

test "kdl: string escape \\n" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"hello\\nworld\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("hello\nworld", args.items[0].string);
}

test "kdl: string escape \\t" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"hello\\tworld\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("hello\tworld", args.items[0].string);
}

test "kdl: string escape \\r" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"hello\\rworld\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("hello\rworld", args.items[0].string);
}

test "kdl: string escape \\\\" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"hello\\\\world\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("hello\\world", args.items[0].string);
}

test "kdl: string escape \\/ and \\\"" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"a\\/b\\\"c\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("a/b\"c", args.items[0].string);
}

test "kdl: string escape \\s" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"a\\sb\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("a b", args.items[0].string);
}

test "kdl: string unicode escape \\uXXXX" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"\\u0048\\u0065\\u006C\\u006C\\u006F\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("Hello", args.items[0].string);
}

test "kdl: string unicode escape \\u{XXXX}" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"\\u{1F600}\"");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("\u{1F600}", args.items[0].string);
}

test "kdl: raw string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #\"raw \\n string\"#");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("raw \\n string", args.items[0].string);
}

test "kdl: raw string with multiple #" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo ##\"raw \"# string\"##");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("raw \"# string", args.items[0].string);
}

test "kdl: decimal number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 42");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 42), args.items[0].integer);
}

test "kdl: negative number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo -42");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, -42), args.items[0].integer);
}

test "kdl: hex number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 0xFF");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 255), args.items[0].integer);
}

test "kdl: octal number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 0o77");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 63), args.items[0].integer);
}

test "kdl: binary number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 0b1010");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 10), args.items[0].integer);
}

test "kdl: number with underscores" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 1_000_000");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 1000000), args.items[0].integer);
}

test "kdl: hex number with underscores" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 0xFF_FF");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqual(@as(i64, 65535), args.items[0].integer);
}

test "kdl: float number" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 3.14");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectApproxEqAbs(@as(f64, 3.14), args.items[0].float, 1e-10);
}

test "kdl: scientific notation" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 1.5e10");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectApproxEqAbs(@as(f64, 1.5e10), args.items[0].float, 1e10);
}

test "kdl: negative exponent" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo 2.5e-3");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectApproxEqAbs(@as(f64, 2.5e-3), args.items[0].float, 1e-10);
}

test "kdl: float starting with decimal point" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo .5");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectApproxEqAbs(@as(f64, 0.5), args.items[0].float, 1e-10);
}

test "kdl: #inf" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #inf");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expect(std.math.isInf(args.items[0].float));
    try testing.expect(args.items[0].float > 0);
}

test "kdl: #-inf" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #-inf");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expect(std.math.isInf(args.items[0].float));
    try testing.expect(args.items[0].float < 0);
}

test "kdl: #nan" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #nan");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expect(std.math.isNan(args.items[0].float));
}

test "kdl: hash identifier" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "#foo 1");
    const node = v.array.items[0].object;
    try testing.expectEqualStrings("#foo", (node.get("name") orelse return error.TestFailed).string);
}

test "kdl: empty children" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo {}");
    const node = v.array.items[0].object;
    const children = (node.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 0), children.items.len);
}

test "kdl: node with only props" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo a=1 b=2");
    const node = v.array.items[0].object;
    const args = (node.get("args") orelse return error.TestFailed).array;
    const props = (node.get("props") orelse return error.TestFailed).object;
    try testing.expectEqual(@as(usize, 0), args.items.len);
    try testing.expectEqual(@as(i64, 1), (props.get("a") orelse return error.TestFailed).integer);
    try testing.expectEqual(@as(i64, 2), (props.get("b") orelse return error.TestFailed).integer);
}

test "kdl: property with quoted key" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo \"my-key\"=42");
    const node = v.array.items[0].object;
    const props = (node.get("props") orelse return error.TestFailed).object;
    try testing.expectEqual(@as(i64, 42), (props.get("my-key") orelse return error.TestFailed).integer);
}

test "kdl: deeply nested children" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(),
        \\a {
        \\  b {
        \\    c
        \\  }
        \\}
    );
    const a = v.array.items[0].object;
    const b = (a.get("children") orelse return error.TestFailed).array.items[0].object;
    const c = (b.get("children") orelse return error.TestFailed).array.items[0].object;
    try testing.expectEqualStrings("c", (c.get("name") orelse return error.TestFailed).string);
}

test "kdl: quoted node name" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "\"node name\" 1");
    const node = v.array.items[0].object;
    const name = (node.get("name") orelse return error.TestFailed).string;
    try testing.expect(std.mem.indexOf(u8, name, "node name") != null);
}

test "kdl: string with escapes in raw string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try kdl.parseValue(arena.allocator(), "foo #\"hello\\\\nworld\"#");
    const args = v.array.items[0].object.get("args").?.array;
    try testing.expectEqualStrings("hello\\\\nworld", args.items[0].string);
}

test "kdl: error unterminated string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, kdl.parseValue(arena.allocator(), "foo \"unterminated"));
}

test "kdl: error unclosed block comment" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    try testing.expectError(error.UnexpectedEndOfInput, kdl.parseValue(arena.allocator(), "foo /* unclosed"));
}

const SimpleStruct = struct {
    name: []const u8,
    age: i64,
};

test "kdl: parseFromSlice simple struct" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(SimpleStruct, arena.allocator(),
        \\name="Alice" age=30
    , .{});
    try testing.expectEqualStrings("Alice", result.name);
    try testing.expectEqual(@as(i64, 30), result.age);
    kdl.parseFree(SimpleStruct, arena.allocator(), result);
}

const AllFieldsStruct = struct {
    bool_val: bool,
    int_val: i64,
    float_val: f64,
    str_val: []const u8,
};

test "kdl: parseFromSlice all types" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(AllFieldsStruct, arena.allocator(),
        \\bool_val=#true int_val=42 float_val=3.14 str_val="hello"
    , .{});
    try testing.expect(result.bool_val);
    try testing.expectEqual(@as(i64, 42), result.int_val);
    try testing.expectApproxEqAbs(@as(f64, 3.14), result.float_val, 1e-10);
    try testing.expectEqualStrings("hello", result.str_val);
    kdl.parseFree(AllFieldsStruct, arena.allocator(), result);
}

const OptStruct = struct {
    required: i64,
    optional: ?i64 = null,
};

test "kdl: parseFromSlice optional field" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(OptStruct, arena.allocator(),
        \\required=42
    , .{});
    try testing.expectEqual(@as(i64, 42), result.required);
    try testing.expectEqual(@as(?i64, null), result.optional);
    kdl.parseFree(OptStruct, arena.allocator(), result);
}

test "kdl: parseFromSlice optional present" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(OptStruct, arena.allocator(),
        \\required=1 optional=99
    , .{});
    try testing.expectEqual(@as(i64, 99), result.optional.?);
    kdl.parseFree(OptStruct, arena.allocator(), result);
}

test "kdl: parseFromSlice optional null" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(OptStruct, arena.allocator(),
        \\required=1 optional=#null
    , .{});
    try testing.expect(result.optional == null);
    kdl.parseFree(OptStruct, arena.allocator(), result);
}

const TaggedUnion = union(enum) {
    a: i64,
    b: []const u8,
};

test "kdl: parseFromSlice tagged union" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(TaggedUnion, arena.allocator(),
        \\a 42
    , .{});
    try testing.expectEqual(@as(i64, 42), result.a);
    kdl.parseFree(TaggedUnion, arena.allocator(), result);
}

test "kdl: parseFromSlice tagged union string" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(TaggedUnion, arena.allocator(),
        \\b "hello"
    , .{});
    try testing.expectEqualStrings("hello", result.b);
    kdl.parseFree(TaggedUnion, arena.allocator(), result);
}

const MyEnum = enum { foo, bar, baz };

test "kdl: parseFromSlice enum" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice(MyEnum, arena.allocator(),
        \\foo
    , .{});
    try testing.expectEqual(MyEnum.foo, result);
}

test "kdl: parseFromSlice array" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice([3]i64, arena.allocator(),
        \\{ 1 2 3 }
    , .{});
    try testing.expectEqual(@as(i64, 1), result[0]);
    try testing.expectEqual(@as(i64, 2), result[1]);
    try testing.expectEqual(@as(i64, 3), result[2]);
}

test "kdl: parseFromSlice slice" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try kdl.parseFromSlice([]i64, arena.allocator(),
        \\{ 1 2 3 }
    , .{});
    try testing.expectEqual(@as(usize, 3), result.len);
    try testing.expectEqual(@as(i64, 1), result[0]);
    try testing.expectEqual(@as(i64, 2), result[1]);
    try testing.expectEqual(@as(i64, 3), result[2]);
    kdl.parseFree([]i64, arena.allocator(), result);
}
