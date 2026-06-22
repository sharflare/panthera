//! Parse and serialize XML.
//!
//! Supports: elements, attributes, text content, CDATA, comments,
//! processing instructions, entity decoding (`&amp;`, `&lt;`, `&gt;`,
//! `&quot;`, `&apos;`, numeric character references).
//!
//! In typed structs, only fields wrapped in `xml.Attr(T)` map to XML
//! attributes; bare `[]const u8` fields map to child elements. Use
//! `xml.Attr(i64)`, `xml.Attr(bool)`, `xml.Attr(f64)` for non-string
//! attribute types.
//!
//! Hyphenated XML names (`allow-null`) map to underscored Zig field
//! names (`allow_null`) in typed struct parsing.
//!
//! # Usage
//!
//! ## Dynamic value tree (parseValue)
//! Best for complex or schema-unknown XML. Returns `Value.object`
//! with keys `"name"`, `"attrs"`, `"children"`.
//!
//! ```zig
//! const std = @import("std");
//! const xml = @import("panthera").xml;
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\<?xml version="1.0"?>
//!         \\<person name="Alice" age="30">
//!         \\  <role>admin</role>
//!         \\  <role>user</role>
//!         \\</person>
//!     ;
//!
//!     const v = try xml.parseValue(arena.allocator(), input);
//!
//!     const root = v.object;
//!     std.debug.print("name: {s}\n", .{root.get("name").?.string});
//!     std.debug.print("age: {s}\n", .{root.get("attrs").?.object.get("age").?.string});
//!
//!     for (root.get("children").?.array.items) |child| {
//!         if (child == .object) {
//!             std.debug.print("role: {s}\n", .{child.object.get("children").?.array.items[0].string});
//!         }
//!     }
//! }
//! ```
//!
//! ## Typed struct deserialization (parseFromSlice)
//! Maps XML attributes and child elements to struct fields by name.
//! Only fields wrapped in `xml.Attr(T)` are parsed from XML attributes;
//! bare `[]const u8` fields are parsed from child elements. Hyphenated
//! XML names map to underscored Zig names.
//!
//! ```zig
//! const std = @import("std");
//! const xml = @import("panthera").xml;
//!
//! const Person = struct {
//!     name: xml.Attr([]const u8),
//!     age:  xml.Attr([]const u8),
//!     role: [][]const u8,
//! };
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\<?xml version="1.0"?>
//!         \\<person name="Alice" age="30">
//!         \\  <role>admin</role>
//!         \\  <role>user</role>
//!         \\</person>
//!     ;
//!
//!     const p = try xml.parseFromSlice(Person, arena.allocator(), input, .{});
//!     defer xml.parseFree(Person, arena.allocator(), p);
//!
//!     std.debug.print("{s} is {s} years old\n", .{ p.name.value, p.age.value });
//!     for (p.role) |r| std.debug.print("  role: {s}\n", .{r});
//! }
//! ```
//!
//! For protocol-description XML (Wayland, GLX, etc.):
//!
//! ```zig
//! const std = @import("std");
//! const xml = @import("panthera").xml;
//!
//! const Arg = struct {
//!     name:      xml.Attr([]const u8),
//!     type:      xml.Attr([]const u8),
//!     interface: xml.Attr([]const u8),
//!     allow_null: xml.Attr([]const u8),
//! };
//! const Request = struct { name: xml.Attr([]const u8), arg: []Arg };
//! const Interface = struct { name: xml.Attr([]const u8), version: xml.Attr([]const u8), request: []Request };
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!     const input =
//!         \\<?xml version="1.0"?>
//!         \\<interface name="swc_panel_manager" version="1">
//!         \\  <request name="create_panel">
//!         \\    <arg name="id" type="new_id" interface="swc_panel"/>
//!         \\    <arg name="surface" type="object" interface="wl_surface" allow-null="true"/>
//!         \\  </request>
//!         \\</interface>
//!     ;
//!     const iface = try xml.parseFromSlice(Interface, arena.allocator(), input, .{});
//!     defer xml.parseFree(Interface, arena.allocator(), iface);
//!     std.debug.print("{s} v{s}\n", .{ iface.name.value, iface.version.value });
//! }
//! ```
//!
//! ## Stringify back to XML
//! Only fields wrapped in `xml.Attr(T)` become XML attributes. Bare
//! `[]const u8` fields and nested structs become child elements. Use
//! `xml.Attr(i64)`, `xml.Attr(bool)`, `xml.Attr(f64)` for non-string
//! attribute types.
//!
//! ```zig
//! const std = @import("std");
//! const xml = @import("panthera").xml;
//!
//! const Address = struct { city: xml.Attr([]const u8), zip: xml.Attr([]const u8) };
//! const Person = struct {
//!     name: xml.Attr([]const u8),
//!     age:  xml.Attr([]const u8),
//!     role: [][]const u8,
//!     address: Address,
//! };
//!
//! pub fn main() !void {
//!     var buf: [512]u8 = undefined;
//!     var w: std.Io.Writer = .fixed(&buf);
//!     try xml.stringify(Person{
//!         .name = .{ .value = "Alice" },
//!         .age = .{ .value = "30" },
//!         .role = &.{ "admin", "user" },
//!         .address = .{ .city = .{ .value = "NYC" }, .zip = .{ .value = "10001" } },
//!     }, .{}, &w);
//!     std.debug.print("{s}\n", .{w.buffered()});
//!     // <Person name="Alice" age="30"><role>admin</role><role>user</role><address city="NYC" zip="10001"/></Person>
//! }
//! ```
//!
//! For non-string attribute types:
//!
//! ```zig
//! const Person = struct {
//!     name:   xml.Attr([]const u8),
//!     age:    xml.Attr(i64),
//!     active: xml.Attr(bool),
//! };
//!
//! // Stringify -> <Person name="Alice" age="30" active="true"/>
//! // parseFromSlice reads age="30" and active="true" from attributes
//! ```
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");
pub const stringify_mod = @import("stringify.zig");

pub fn Attr(comptime T: type) type {
    return struct {
        value: T,
        pub const is_xml_attr = true;
    };
}

const types = @import("../../types.zig");

pub const Value = types.Value;
pub const Error = types.Error;
pub const ParseOptions = types.ParseOptions;
pub const StringifyOptions = types.StringifyOptions;
pub const ObjectMap = types.ObjectMap;
pub const Array = types.Array;
pub const MAX_DEPTH = types.MAX_DEPTH;
pub const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

pub const parseValue = parser.parseValue;
pub const parseFromSlice = parser.parseFromSlice;
pub const parseFree = parser.parseFree;
pub const parse = parser.parseFromSlice;
pub const stringify = stringify_mod.stringify;

pub const Stringifier = stringify_mod.Stringifier;

pub const Tokenizer = tokenizer.XmlTokenizer;
pub const TokenTag = tokenizer.TokenTag;
pub const Token = tokenizer.Token;

test {
    _ = tokenizer;
    _ = parser;
    _ = stringify_mod;
}
