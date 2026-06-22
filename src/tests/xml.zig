const std = @import("std");
const testing = std.testing;
const ArenaAllocator = std.heap.ArenaAllocator;

const xml = @import("../xml.zig");
const Value = xml.Value;

// --- Tokenizer Tests ---

test "xml tokenizer: simple element" {
    const input = "<root></root>";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.open_tag, t1.tag);
    try testing.expectEqualStrings("root", t1.slice);

    const t2 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.tag_end, t2.tag);

    const t3 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.close_tag, t3.tag);
    try testing.expectEqualStrings("root", t3.slice);
}

test "xml tokenizer: self-closing element" {
    const input = "<br/>";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.open_tag, t1.tag);
    try testing.expectEqualStrings("br", t1.slice);

    const t2 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.self_close, t2.tag);
}

test "xml tokenizer: element with attributes" {
    const input = "<div class=\"foo\" id=\"bar\">";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.open_tag, t1.tag);
    try testing.expectEqualStrings("div", t1.slice);

    const t2 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.attr_name, t2.tag);
    try testing.expectEqualStrings("class", t2.slice);

    const t3 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.equals, t3.tag);

    const t4 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.attr_value, t4.tag);
    try testing.expectEqualStrings("foo", t4.slice);

    const t5 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.attr_name, t5.tag);
    try testing.expectEqualStrings("id", t5.slice);

    const t6 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.equals, t6.tag);

    const t7 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.attr_value, t7.tag);
    try testing.expectEqualStrings("bar", t7.slice);

    const t8 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.tag_end, t8.tag);
}

test "xml tokenizer: text content" {
    const input = "hello world";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.text, t1.tag);
    try testing.expectEqualStrings("hello world", t1.slice);
}

test "xml tokenizer: comment" {
    const input = "<!-- this is a comment -->";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.comment, t1.tag);
    try testing.expectEqualStrings("<!-- this is a comment -->", t1.slice);
}

test "xml tokenizer: CDATA" {
    const input = "<![CDATA[hello <world>]]>";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.cdata, t1.tag);
    try testing.expectEqualStrings("hello <world>", t1.slice);
}

test "xml tokenizer: processing instruction" {
    const input = "<?xml version=\"1.0\"?>";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.pi, t1.tag);
}

test "xml tokenizer: self-closing with space" {
    const input = "<br />";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.open_tag, t1.tag);
    try testing.expectEqualStrings("br", t1.slice);

    const t2 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.self_close, t2.tag);
}

test "xml tokenizer: namespace in name" {
    const input = "<ns:tag>";
    var tok = try xml.Tokenizer.init(input);

    const t1 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.open_tag, t1.tag);
    try testing.expectEqualStrings("ns:tag", t1.slice);

    const t2 = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    try testing.expectEqual(.tag_end, t2.tag);
}

// --- Parser Tests ---

test "xml parser: simple element" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root></root>");

    const name = v.object.get("name") orelse return error.TestFailed;
    try testing.expectEqualStrings("root", name.string);
}

test "xml parser: element with text" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root>hello</root>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 1), children.items.len);
    try testing.expectEqualStrings("hello", children.items[0].string);
}

test "xml parser: element with attributes" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<div class=\"foo\" id=\"bar\">text</div>");

    const attrs = (v.object.get("attrs") orelse return error.TestFailed).object;
    try testing.expectEqualStrings("foo", (attrs.get("class") orelse return error.TestFailed).string);
    try testing.expectEqualStrings("bar", (attrs.get("id") orelse return error.TestFailed).string);
}

test "xml parser: self-closing element" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<br/>");

    const name = v.object.get("name") orelse return error.TestFailed;
    try testing.expectEqualStrings("br", name.string);

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 0), children.items.len);
}

test "xml parser: nested elements" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<parent><child1>a</child1><child2>b</child2></parent>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 2), children.items.len);

    const c1 = children.items[0].object;
    try testing.expectEqualStrings("child1", (c1.get("name") orelse return error.TestFailed).string);
    try testing.expectEqualStrings("a", ((c1.get("children") orelse return error.TestFailed).array.items[0].string));

    const c2 = children.items[1].object;
    try testing.expectEqualStrings("child2", (c2.get("name") orelse return error.TestFailed).string);
    try testing.expectEqualStrings("b", ((c2.get("children") orelse return error.TestFailed).array.items[0].string));
}

test "xml parser: entity decoding" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root>&amp;&lt;&gt;&quot;&apos;</root>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 1), children.items.len);
    try testing.expectEqualStrings("&<>\"'", children.items[0].string);
}

test "xml parser: numeric entity" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root>&#65;&#x42;&#x43;</root>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqualStrings("ABC", children.items[0].string);
}

test "xml parser: attribute with entities" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root attr=\"a&amp;b\">x</root>");

    const attrs = (v.object.get("attrs") orelse return error.TestFailed).object;
    try testing.expectEqualStrings("a&b", (attrs.get("attr") orelse return error.TestFailed).string);
}

test "xml parser: CDATA" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root><![CDATA[hello <world>]]></root>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 1), children.items.len);
    try testing.expectEqualStrings("hello <world>", children.items[0].string);
}

test "xml parser: comment skipped" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<root><!-- comment -->text</root>");

    const children = (v.object.get("children") orelse return error.TestFailed).array;
    try testing.expectEqual(@as(usize, 1), children.items.len);
    try testing.expectEqualStrings("text", children.items[0].string);
}

test "xml parser: xml declaration skipped" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<?xml version=\"1.0\"?><root></root>");

    const name = v.object.get("name") orelse return error.TestFailed;
    try testing.expectEqualStrings("root", name.string);
}

test "xml parser: deep nesting" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const v = try xml.parseValue(arena.allocator(), "<a><b><c><d>deep</d></c></b></a>");

    const deep = ((v.object.get("children") orelse return error.TestFailed)
        .array.items[0].object.get("children") orelse return error.TestFailed)
        .array.items[0].object.get("children") orelse return error.TestFailed;
    const final_text = deep.array.items[0].object.get("children") orelse return error.TestFailed;
    try testing.expectEqualStrings("deep", final_text.array.items[0].string);
}

// --- Stringify Tests ---

test "xml stringify: simple roundtrip" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "<root><child>text</child></root>";
    const v = try xml.parseValue(arena.allocator(), input);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const opts = xml.StringifyOptions{};
    try xml.stringify(v, opts, &w);

    try testing.expectEqualStrings(input, w.buffered());
}

test "xml stringify: self-closing roundtrip" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "<br/>";
    const v = try xml.parseValue(arena.allocator(), input);

    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const opts = xml.StringifyOptions{};
    try xml.stringify(v, opts, &w);

    try testing.expectEqualStrings(input, w.buffered());
}

test "xml stringify: attributes roundtrip" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "<div class=\"foo\" id=\"bar\">text</div>";
    const v = try xml.parseValue(arena.allocator(), input);

    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const opts = xml.StringifyOptions{};
    try xml.stringify(v, opts, &w);

    try testing.expectEqualStrings(input, w.buffered());
}

test "xml stringify: escaped characters" {
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const input = "<root>&amp;&lt;&gt;</root>";
    const v = try xml.parseValue(arena.allocator(), input);

    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const opts = xml.StringifyOptions{};
    try xml.stringify(v, opts, &w);

    try testing.expectEqualStrings(input, w.buffered());
}

test "xml: typed struct parsing attributes" {
    const Person = struct {
        name: xml.Attr([]const u8),
        age: xml.Attr([]const u8),
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Person, arena.allocator(),
        "<person name=\"Alice\" age=\"30\"></person>", .{});
    defer xml.parseFree(Person, arena.allocator(), result);
    try testing.expectEqualStrings("Alice", result.name.value);
    try testing.expectEqualStrings("30", result.age.value);
}

test "xml: typed struct parsing child elements" {
    const Person = struct {
        name: []const u8,
        age: []const u8,
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Person, arena.allocator(),
        "<person><name>Alice</name><age>30</age></person>", .{});
    defer xml.parseFree(Person, arena.allocator(), result);
    try testing.expectEqualStrings("Alice", result.name);
    try testing.expectEqualStrings("30", result.age);
}

test "xml: typed struct parsing nested" {
    const Address = struct {
        city: []const u8,
    };
    const Person = struct {
        name: []const u8,
        address: Address,
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Person, arena.allocator(),
        "<person><name>Bob</name><address><city>NYC</city></address></person>", .{});
    defer xml.parseFree(Person, arena.allocator(), result);
    try testing.expectEqualStrings("Bob", result.name);
    try testing.expectEqualStrings("NYC", result.address.city);
}

test "xml: typed struct parsing self-closing" {
    const Empty = struct {
        attr: xml.Attr([]const u8),
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Empty, arena.allocator(),
        "<empty attr=\"val\"/>", .{});
    defer xml.parseFree(Empty, arena.allocator(), result);
    try testing.expectEqualStrings("val", result.attr.value);
}

test "xml: typed struct parsing hyphenated attribute" {
    const Elem = struct {
        allow_null: xml.Attr([]const u8),
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Elem, arena.allocator(),
        "<elem allow-null=\"true\"/>", .{});
    defer xml.parseFree(Elem, arena.allocator(), result);
    try testing.expectEqualStrings("true", result.allow_null.value);
}

test "xml: typed struct parsing hyphenated child element" {
    const Inner = struct {
        item: []const u8,
    };
    const Outer = struct {
        child_item: Inner,
    };
    var arena = ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const result = try xml.parseFromSlice(Outer, arena.allocator(),
        "<outer><child-item><item>hello</item></child-item></outer>", .{});
    defer xml.parseFree(Outer, arena.allocator(), result);
    try testing.expectEqualStrings("hello", result.child_item.item);
}

test "xml stringify: struct with attrs" {
    const Person = struct {
        name: xml.Attr([]const u8),
        age: xml.Attr([]const u8),
    };
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try xml.stringify(Person{ .name = .{ .value = "Alice" }, .age = .{ .value = "30" } }, .{}, &w);
    try testing.expectEqualStrings("<Person name=\"Alice\" age=\"30\"/>", w.buffered());
}

test "xml stringify: struct with children" {
    const Person = struct {
        name: xml.Attr([]const u8),
        role: [][]const u8,
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    var roles = [_][]const u8{ "admin", "user" };
    const role_slice: [][]const u8 = roles[0..];
    try xml.stringify(Person{ .name = .{ .value = "Alice" }, .role = role_slice }, .{}, &w);
    try testing.expectEqualStrings("<Person name=\"Alice\"><role>admin</role><role>user</role></Person>", w.buffered());
}

test "xml stringify: struct with nested struct" {
    const Address = struct {
        city: xml.Attr([]const u8),
    };
    const Person = struct {
        name: xml.Attr([]const u8),
        address: Address,
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try xml.stringify(Person{ .name = .{ .value = "Bob" }, .address = .{ .city = .{ .value = "NYC" } } }, .{}, &w);
    try testing.expectEqualStrings("<Person name=\"Bob\"><address city=\"NYC\"/></Person>", w.buffered());
}

test "xml stringify: Attr(i64) as attribute" {
    const Person = struct {
        name: xml.Attr([]const u8),
        age: xml.Attr(i64),
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try xml.stringify(Person{ .name = .{ .value = "Alice" }, .age = .{ .value = 30 } }, .{}, &w);
    try testing.expectEqualStrings("<Person name=\"Alice\" age=\"30\"/>", w.buffered());
}

test "xml stringify: Attr(bool) as attribute" {
    const Person = struct {
        name: xml.Attr([]const u8),
        active: xml.Attr(bool),
    };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try xml.stringify(Person{ .name = .{ .value = "Alice" }, .active = .{ .value = true } }, .{}, &w);
    try testing.expectEqualStrings("<Person name=\"Alice\" active=\"true\"/>", w.buffered());
}

test "xml: typed struct Attr(i64) parse and stringify roundtrip" {
    const Person = struct {
        name: xml.Attr([]const u8),
        age: xml.Attr(i64),
    };
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const p = try xml.parseFromSlice(Person, arena.allocator(),
        "<Person name=\"Alice\" age=\"30\"/>", .{});
    defer xml.parseFree(Person, arena.allocator(), p);
    try testing.expectEqualStrings("Alice", p.name.value);
    try testing.expectEqual(@as(i64, 30), p.age.value);
}
