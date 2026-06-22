//! #Panthera
//! ### Lightning fast SIMD-accelerated serializer/deserializer framework.
//!
//! Like serde, panthera exposes a unified frontend for multiple format backends.
//! Each backend (json, yaml, ...) implements the same API:
//! `parseValue`, `parseFromSlice`, `parseFree`, and `stringify`.
//!
//! ## Format-specific API
//!
//! ```zig
//! const cfg  = try panthera.json.parseFromSlice(Config, allocator, json_str, .{});
//! const cfg2 = try panthera.yaml.parseFromSlice(Config, allocator, yaml_str, .{});
//! ```
//!
//! ## Backwards-compatible JSON shortcut
//!
//! The root module also re-exports the JSON backend directly:
//!
//! ```zig
//! const cfg = try panthera.parseFromSlice(Config, allocator, json_str, .{});
//! ```

const std = @import("std");

const types = @import("types.zig");
const simd = @import("simd.zig");
const format_mod = @import("format.zig");

// --- Format backends ---

pub const json = @import("json.zig");
pub const yaml = @import("yaml.zig");
pub const kdl = @import("kdl.zig");
pub const xml = @import("xml.zig");
pub const format = format_mod;

// --- Shared types ---

pub const MAX_DEPTH = types.MAX_DEPTH;
pub const MAX_TOKEN_LEN = types.MAX_TOKEN_LEN;
pub const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

pub const Error = types.Error;
pub const StringifyOptions = types.StringifyOptions;
pub const ParseOptions = types.ParseOptions;
pub const ObjectMap = types.ObjectMap;
pub const Array = types.Array;
pub const Value = types.Value;

pub const simdParseU64Decimal = simd.simdParseU64Decimal;
pub const SpaceScanner = simd.SpaceScanner;

// --- Back Compat ---

pub const parseValue = json.parseValue;
pub const parseFromSlice = json.parseFromSlice;
pub const parseFree = json.parseFree;
pub const parse = json.parse;
pub const stringify = json.stringify;
pub const decodeString = json.decodeString;

pub const Tokenizer = json.Tokenizer;
pub const TokenTag = json.TokenTag;
pub const Token = json.Token;

// --- Tests ---

test {
    _ = @import("tests/json.zig");
}
test {
    _ = @import("tests/yaml.zig");
}
test {
    _ = @import("tests/kdl.zig");
}
test {
    _ = @import("tests/xml.zig");
}

test "skipWhitespace: all" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 6), sc.nextNonSpace("   \t\n\r", 0));
}

test "skipWhitespace: mixed" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 2), sc.nextNonSpace("  hello", 0));
}

test "format: json backend verification" {
    _ = json;
}

test "format: yaml backend verification" {
    _ = yaml;
}

test "format: kdl backend verification" {
    _ = kdl;
}

test "format: xml backend verification" {
    _ = xml;
}
