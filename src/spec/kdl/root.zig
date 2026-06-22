//! Parse and serialize KDL (KDL Document Language).
//!
//! KDL is a document language with a syntax similar to XML but lighter.
//! See https://kdl.dev for the specification.
//!
//! # Usage
//!
//! ## Dynamic value tree
//! ```zig
//! const std = @import("std");
//! const kdl = @import("panthera").kdl;
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\person "Alice" age=30 roles=["admin" "user"]
//!     ;
//!
//!     const v = try kdl.parseValue(arena.allocator(), input);
//!     const node = v.array.items[0].object;
//!     std.debug.print("name: {s}\n", .{node.get("name").?.string});
//!     std.debug.print("age: {}\n", .{node.get("props").?.object.get("age").?.integer});
//!     const roles = node.get("args").?.array.items[2].array; // ["admin", "user"]
//!     for (roles.items) |r| std.debug.print("  role: {s}\n", .{r.string});
//! }
//! ```
//!
//! ## Typed struct deserialization
//! ```zig
//! const std = @import("std");
//! const kdl = @import("panthera").kdl;
//!
//! const Person = struct {
//!     name: []const u8,
//!     age: i64,
//!     roles: [][]const u8,
//! };
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const result = try kdl.parseFromSlice(Person, arena.allocator(),
//!         "person \"Alice\" age=30 roles=[\"admin\" \"user\"]", .{});
//!     defer kdl.parseFree(Person, arena.allocator(), result);
//!
//!     std.debug.print("{s} is {} years old\n", .{ result.name, result.age });
//!     for (result.roles) |r| std.debug.print("  role: {s}\n", .{r});
//! }
//! ```
//!
//! ## Stringify back to KDL
//! ```zig
//! const std = @import("std");
//! const kdl = @import("panthera").kdl;
//!
//! pub fn main() !void {
//!     var buf: [512]u8 = undefined;
//!     var w: std.Io.Writer = .fixed(&buf);
//!
//!     try kdl.stringify(.{ .name = "Alice", .age = 30, .roles = &.{} }, .{}, &w);
//!     std.debug.print("{s}\n", .{w.buffered()});
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
pub const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

pub const parseValue = parser.parseValue;
pub const parseFromSlice = parser.parseFromSlice;
pub const parseFree = parser.parseFree;
pub const parse = parser.parseFromSlice;
pub const stringify = stringify_mod.stringify;

pub const Stringifier = stringify_mod.Stringifier;

pub const Tokenizer = tokenizer.KdlTokenizer;
pub const TokenTag = tokenizer.TokenTag;
pub const Token = tokenizer.Token;

test {
    _ = tokenizer;
    _ = parser;
    _ = stringify_mod;
}
