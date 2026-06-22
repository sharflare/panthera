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
