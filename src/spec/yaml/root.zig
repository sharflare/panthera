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

pub const Value = @import("../../types.zig").Value;
pub const Error = @import("../../types.zig").Error;
pub const ParseOptions = @import("../../types.zig").ParseOptions;
pub const StringifyOptions = @import("../../types.zig").StringifyOptions;
pub const ObjectMap = @import("../../types.zig").ObjectMap;
pub const Array = @import("../../types.zig").Array;
pub const MAX_DEPTH = @import("../../types.zig").MAX_DEPTH;
pub const MAX_TOKEN_LEN = @import("../../types.zig").MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES = @import("../../types.zig").MAX_INPUT_BYTES;

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
