//! Parse and serialize JSON.
//!
//! # Usage
//!
//! ## Dynamic value tree
//! ```zig
//! const std = @import("std");
//! const json = @import("panthera").json;
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\{"name": "Alice", "age": 30, "tags": ["admin", "user"]}
//!     ;
//!
//!     const v = try json.parseValue(arena.allocator(), input);
//!
//!     std.debug.print("name: {s}\n", .{v.object.get("name").?.string});
//!     std.debug.print("age: {}\n", .{v.object.get("age").?.integer});
//! }
//! ```
//!
//! ## Typed struct deserialization
//! ```zig
//! const std = @import("std");
//! const json = @import("panthera").json;
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
//!         \\{"name": "Alice", "age": 30, "tags": ["admin", "user"]}
//!     ;
//!
//!     const p = try json.parseFromSlice(Person, arena.allocator(), input, .{});
//!     defer json.parseFree(Person, arena.allocator(), p);
//!
//!     std.debug.print("{s} is {} years old\n", .{ p.name, p.age });
//! }
//! ```
//!
//! ## Stringify back to JSON
//! ```zig
//! const std = @import("std");
//! const json = @import("panthera").json;
//!
//! pub fn main() !void {
//!     var buf: [512]u8 = undefined;
//!     var w: std.Io.Writer = .fixed(&buf);
//!
//!     try json.stringify(.{ .x = 1, .y = 2.5, .z = true }, .{}, &w);
//!     std.debug.print("{s}\n", .{w.buffered()});
//!     // prints: {"x":1,"y":2.5,"z":true}
//! }
//! ```
pub const parser = @import("json/parser.zig");
pub const tokenizer = @import("json/tokenizer.zig");
pub const stringify_mod = @import("json/stringify.zig");

pub const Value = @import("types.zig").Value;
pub const Error = @import("types.zig").Error;
pub const ParseOptions = @import("types.zig").ParseOptions;
pub const StringifyOptions = @import("types.zig").StringifyOptions;
pub const ObjectMap = @import("types.zig").ObjectMap;
pub const Array = @import("types.zig").Array;
pub const MAX_DEPTH = @import("types.zig").MAX_DEPTH;
pub const MAX_TOKEN_LEN = @import("types.zig").MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES = @import("types.zig").MAX_INPUT_BYTES;

pub const parseValue = parser.parseValue;
pub const parseFromSlice = parser.parseFromSlice;
pub const parseFree = parser.parseFree;
pub const parse = parser.parseFromSlice;
pub const stringify = stringify_mod.stringify;
pub const decodeString = parser.decodeString;
pub const allocDecodeStringHinted = parser.allocDecodeStringHinted;

pub const Tokenizer = tokenizer.Tokenizer;
pub const TokenTag = tokenizer.TokenTag;
pub const Token = tokenizer.Token;

pub const Stringifier = stringify_mod.Stringifier;

test {
    _ = parser;
    _ = tokenizer;
    _ = stringify_mod;
}
