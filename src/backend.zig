//! # Writing a custom backend
//!
//! A panthera format backend is any Zig module that exports 4 functions,
//! 6 types, and 2 constants from the shared infrastructure:
//!
//! ```zig
//! const std = @import("std");
//! const panthera = @import("panthera");
//!
//! // Re-export shared types and constants
//! pub const Value = panthera.Value;
//! pub const Error = panthera.Error;
//! pub const ParseOptions = panthera.ParseOptions;
//! pub const StringifyOptions = panthera.StringifyOptions;
//! pub const ObjectMap = panthera.ObjectMap;
//! pub const Array = panthera.Array;
//! pub const MAX_DEPTH = panthera.MAX_DEPTH;
//! pub const MAX_INPUT_BYTES = panthera.MAX_INPUT_BYTES;
//!
//! // Implement the core protocol
//! pub fn parseValue(allocator: std.mem.Allocator, input: []const u8) Error!Value { ... }
//! pub fn parseFromSlice(comptime T: type, allocator: std.mem.Allocator, input: []const u8, opts: ParseOptions) Error!T { ... }
//! pub fn parseFree(comptime T: type, allocator: std.mem.Allocator, value: T) void { ... }
//! pub fn stringify(value: anytype, opts: StringifyOptions, writer: anytype) !void { ... }
//!
//! // Verify conformance at compile time
//! comptime { panthera.backend.verify(@This()); }
//! ```
//!
//! Users consume it by importing your module directly:
//!
//! ```zig
//! const myfmt = @import("my-format");
//! const cfg = try myfmt.parseFromSlice(Config, allocator, input, .{});
//! ```
//!
//! You can use `panthera.format` (Dragonbox float formatting, integer formatting),
//! `panthera.simd` (SIMD scan helpers), and `panthera.types` (shared types) in
//! your implementation.
//!
//! # Runtime format detection (built-in formats only)
//!
//! For format-agnostic code that picks between built-in backends at runtime:
//!
//! ```zig
//! const fmt = panthera.backend.detectFormat(path) orelse return error.UnknownFormat;
//! return panthera.backend.parseFromSlice(T, fmt, allocator, input, .{});
//! ```
//!
//! # Required exports
//!
//! | Export | Kind | Description |
//! |--------|------|-------------|
//! | `Value` | type | Dynamic value tree from `panthera.Value` |
//! | `Error` | type | Error set from `panthera.Error` |
//! | `ParseOptions` | type | Parse options from `panthera.ParseOptions` |
//! | `StringifyOptions` | type | Stringify options from `panthera.StringifyOptions` |
//! | `ObjectMap` | type | Object map from `panthera.ObjectMap` |
//! | `Array` | type | Array type from `panthera.Array` |
//! | `MAX_DEPTH` | u32 | Max nesting depth from `panthera.MAX_DEPTH` |
//! | `MAX_INPUT_BYTES` | usize | Max input size from `panthera.MAX_INPUT_BYTES` |
//! | `parseValue` | fn | Parse input string into a `Value` tree |
//! | `parseFromSlice` | fn | Parse input string into a typed struct |
//! | `parseFree` | fn | Free a typed struct returned by `parseFromSlice` |
//! | `stringify` | fn | Serialize a value to the format |
//!
//! ## Function signatures
//!
//! ```zig
//! pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value
//! pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T
//! pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void
//! pub fn stringify(value: anytype, opts: StringifyOptions, writer: anytype) !void
//! ```
//!
//! ## Optional exports
//!
//! `Tokenizer`, `TokenTag`, `Token`, `Stringifier`, `parse` (alias for `parseFromSlice`),
//! `MAX_TOKEN_LEN`, format-specific helpers (e.g. `Attr` for XML), and submodules
//! (`tokenizer`, `parser`, `stringify_mod`).

const std = @import("std");
const types = @import("types.zig");

/// Identifier for each built-in format. Used with `detectFormat` and the
/// dispatch functions for runtime format selection.
///
/// For custom backends, import the backend module directly instead.
pub const Format = enum {
    json,
    yaml,
    kdl,
    xml,
    toml,

    /// Return the format name as a string (e.g. `"json"`).
    pub fn name(f: Format) []const u8 {
        return @tagName(f);
    }
};

/// Map a filename extension to a built-in `Format`.
/// Returns `null` if the extension is not recognized.
///
/// Recognized extensions:
/// - `.json` -> `.json`
/// - `.yaml`, `.yml` -> `.yaml`
/// - `.kdl` -> `.kdl`
/// - `.xml` -> `.xml`
/// - `.toml` -> `.toml`
pub fn detectFormat(filename: []const u8) ?Format {
    const ext = std.fs.path.extension(filename);
    if (std.mem.eql(u8, ext, ".json")) return .json;
    if (std.mem.eql(u8, ext, ".yaml") or std.mem.eql(u8, ext, ".yml")) return .yaml;
    if (std.mem.eql(u8, ext, ".kdl")) return .kdl;
    if (std.mem.eql(u8, ext, ".xml")) return .xml;
    if (std.mem.eql(u8, ext, ".toml")) return .toml;
    return null;
}

const json_mod = @import("spec/json/root.zig");
const yaml_mod = @import("spec/yaml/root.zig");
const kdl_mod = @import("spec/kdl/root.zig");
const xml_mod = @import("spec/xml/root.zig");
const toml_mod = @import("spec/toml/root.zig");

/// Dispatch `parseValue` based on `Format`.
pub fn parseValue(format: Format, allocator: std.mem.Allocator, input: []const u8) (types.Error || error{OutOfMemory})!types.Value {
    return switch (format) {
        .json => try json_mod.parseValue(allocator, input),
        .yaml => try yaml_mod.parseValue(allocator, input),
        .kdl => try kdl_mod.parseValue(allocator, input),
        .xml => try xml_mod.parseValue(allocator, input),
        .toml => try toml_mod.parseValue(allocator, input),
    };
}

/// Dispatch `parseFromSlice` based on `Format`.
pub fn parseFromSlice(comptime T: type, format: Format, allocator: std.mem.Allocator, input: []const u8, opts: types.ParseOptions) (types.Error || error{OutOfMemory})!T {
    return switch (format) {
        .json => try json_mod.parseFromSlice(T, allocator, input, opts),
        .yaml => try yaml_mod.parseFromSlice(T, allocator, input, opts),
        .kdl => try kdl_mod.parseFromSlice(T, allocator, input, opts),
        .xml => try xml_mod.parseFromSlice(T, allocator, input, opts),
        .toml => try toml_mod.parseFromSlice(T, allocator, input, opts),
    };
}

/// Dispatch `parseFree` based on `Format`.
pub fn parseFree(comptime T: type, format: Format, allocator: std.mem.Allocator, value: T) void {
    switch (format) {
        .json => json_mod.parseFree(T, allocator, value),
        .yaml => yaml_mod.parseFree(T, allocator, value),
        .kdl => kdl_mod.parseFree(T, allocator, value),
        .xml => xml_mod.parseFree(T, allocator, value),
        .toml => toml_mod.parseFree(T, allocator, value),
    }
}

/// Dispatch `stringify` based on `Format`.
pub fn stringify(format: Format, value: anytype, opts: types.StringifyOptions, writer: anytype) !void {
    switch (format) {
        .json => try json_mod.stringify(value, opts, writer),
        .yaml => try yaml_mod.stringify(value, opts, writer),
        .kdl => try kdl_mod.stringify(value, opts, writer),
        .xml => try xml_mod.stringify(value, opts, writer),
        .toml => try toml_mod.stringify(value, opts, writer),
    }
}

/// Verify that a module conforms to the panthera backend protocol.
/// Call this in a `comptime` block to validate a custom backend:
///
/// ```zig
/// comptime { panthera.backend.verify(MyBackend); }
/// ```
pub fn verify(comptime Backend: type) void {
    comptime {
        const required = .{
            "Value", "Error", "ParseOptions", "StringifyOptions",
            "ObjectMap", "Array",
            "MAX_DEPTH", "MAX_INPUT_BYTES",
            "parseValue", "parseFromSlice", "parseFree", "stringify",
        };

        for (required) |name| {
            if (!@hasDecl(Backend, name)) {
                @compileError("Backend '" ++ @typeName(Backend) ++ "' is missing required export '" ++ name ++ "'");
            }
        }
    }
}

test "verify built-in backends" {
    comptime {
        verify(json_mod);
        verify(yaml_mod);
        verify(kdl_mod);
        verify(xml_mod);
        verify(toml_mod);
    }
}

test "detectFormat: known extensions" {
    try std.testing.expectEqual(@as(?Format, .json), detectFormat("config.json"));
    try std.testing.expectEqual(@as(?Format, .yaml), detectFormat("config.yaml"));
    try std.testing.expectEqual(@as(?Format, .yaml), detectFormat("config.yml"));
    try std.testing.expectEqual(@as(?Format, .kdl), detectFormat("config.kdl"));
    try std.testing.expectEqual(@as(?Format, .xml), detectFormat("config.xml"));
    try std.testing.expectEqual(@as(?Format, .toml), detectFormat("config.toml"));
}

test "detectFormat: unknown extension" {
    try std.testing.expectEqual(@as(?Format, null), detectFormat("config.txt"));
    try std.testing.expectEqual(@as(?Format, null), detectFormat("config"));
    try std.testing.expectEqual(@as(?Format, null), detectFormat(""));
}

test "Format.name" {
    try std.testing.expectEqualStrings("json", Format.json.name());
    try std.testing.expectEqualStrings("yaml", Format.yaml.name());
    try std.testing.expectEqualStrings("kdl", Format.kdl.name());
    try std.testing.expectEqualStrings("xml", Format.xml.name());
    try std.testing.expectEqualStrings("toml", Format.toml.name());
}
