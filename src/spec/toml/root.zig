//! Parse and serialize TOML.
//!
//! # Usage
//!
//! ## Dynamic value tree
//! ```zig
//! const std = @import("std");
//! const toml = @import("panthera").toml;
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\title = "TOML Example"
//!         \\[owner]
//!         \\name = "Alice"
//!     ;
//!
//!     const v = try toml.parseValue(arena.allocator(), input);
//!     std.debug.print("title: {s}\n", .{v.object.get("title").?.string});
//! }
//! ```
//!
//! ## Struct deserialization
//! ```zig
//! const std = @import("std");
//! const toml = @import("panthera").toml;
//!
//! const Config = struct {
//!     title: []const u8,
//!     owner: Owner,
//!
//!     const Owner = struct {
//!         name: []const u8,
//!         age: u32,
//!     };
//! };
//!
//! pub fn main() !void {
//!     var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
//!     defer arena.deinit();
//!
//!     const input =
//!         \\title = "TOML Example"
//!         \\[owner]
//!         \\name = "Alice"
//!         \\age = 30
//!     ;
//!
//!     const cfg = try toml.parseFromSlice(Config, arena.allocator(), input, .{});
//!     std.debug.print("title: {s}, owner: {s}\n", .{ cfg.title, cfg.owner.name });
//! }
//! ```
//!
//! ## Stringify back to TOML
//! ```zig
//! const std = @import("std");
//! const toml = @import("panthera").toml;
//!
//! pub fn main() !void {
//!     var buf: [512]u8 = undefined;
//!     var w: std.Io.Writer = .fixed(&buf);
//!     try toml.stringify(.{ .x = 1, .y = 2.5, .z = true }, .{}, &w);
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

pub const Stringifier = stringify_mod.Writer;

pub const Tokenizer = tokenizer.TomlTokenizer;
pub const TokenTag = tokenizer.TokenTag;
pub const Token = tokenizer.Token;

test {
    _ = tokenizer;
    _ = parser;
    _ = stringify_mod;
}
