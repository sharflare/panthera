//! Parse and serialize YAML.
//!
//! # Usage
//!
//! ## Dynamic value tree
//! ```zig
//! const std = @import("std");
//! const yaml = @import("panthera").yaml;
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\name: Alice
//!         \\age: 30
//!         \\tags:
//!         \\  - admin
//!         \\  - user
//!     ;
//!
//!     const v = try yaml.parseValue(arena.allocator(), input);
//!     std.debug.print("name: {s}\n", .{v.object.get("name").?.string});
//! }
//! ```
//!
//! ## Typed struct deserialization
//! ```zig
//! const std = @import("std");
//! const yaml = @import("panthera").yaml;
//!
//! const Person = struct {
//!     name: []const u8,
//!     age: i64,
//!     tags: [][]const u8,
//! };
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\name: Alice
//!         \\age: 30
//!         \\tags:
//!         \\  - admin
//!         \\  - user
//!     ;
//!
//!     const p = try yaml.parseFromSlice(Person, arena.allocator(), input, .{});
//!     defer yaml.parseFree(Person, arena.allocator(), p);
//!
//!     std.debug.print("{s} is {} years old\n", .{ p.name, p.age });
//! }
//! ```
//!
//! ## Stringify back to YAML
//! ```zig
//! const std = @import("std");
//! const yaml = @import("panthera").yaml;
//!
//! pub fn main() !void {
//!     var buf: [512]u8 = undefined;
//!     var w: std.Io.Writer = .fixed(&buf);
//!
//!     try yaml.stringify(.{ .x = 1, .y = 2.5 }, .{}, &w);
//!     std.debug.print("{s}\n", .{w.buffered()});
//!     // prints: {x:1,y:2.5}
//! }
//! ```
pub const tokenizer = @import("tokenizer.zig");
pub const parser = @import("parser.zig");
pub const stringify_mod = @import("stringify.zig");

const types = @import("../../types.zig");

pub const Value = types.Value;
pub const Error = types.Error;
pub const ParseOptions = types.ParseOptions;
pub const StringifyOptions = types.StringifyOptions;
pub const ObjectMap = types.ObjectMap;
pub const Array = types.Array;
pub const MAX_DEPTH = types.MAX_DEPTH;
pub const MAX_TOKEN_LEN = types.MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

pub const parseValue = parser.parseValue;
pub const parseFromSlice = parser.parseFromSlice;
pub const parseFree = parser.parseFree;
pub const parse = parser.parseFromSlice;
pub const stringify = stringify_mod.stringify;

pub const Stringifier = stringify_mod.Stringifier;

test {
    _ = tokenizer;
    _ = parser;
    _ = stringify_mod;
}
