const std = @import("std");
const assert = std.debug.assert;

const types = @import("types.zig");
const simd = @import("simd.zig");

const Error = types.Error;
const MAX_TOKEN_LEN = types.MAX_TOKEN_LEN;
const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

const SpaceScanner = simd.SpaceScanner;
const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const numberEndSimd = simd.numberEndSimd;

pub const TokenTag = enum {
    object_begin,
    object_end,
    array_begin,
    array_end,
    colon,
    comma,
    string,
    number,
    true_lit,
    false_lit,
    null_lit,
};

pub const Token = struct {
    tag: TokenTag,
    slice: []const u8,
    is_float: bool = false,
    has_escape: bool = false,
};

/// Streaming JSON tokenizer. Wraps a byte slice and advances through it token by token.
/// Whitespace is skipped automatically between tokens.
pub const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    scanner: SpaceScanner,
    prev_escaped: u64,

    /// Initialize a tokenizer over `input`. Returns `error.InputTooLarge` if input exceeds `MAX_INPUT_BYTES`.
    pub fn init(input: []const u8) Error!Tokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{
            .input = input,
            .pos = 0,
            .scanner = SpaceScanner.init(),
            .prev_escaped = 0,
        };
    }

    /// Peek at the next non-whitespace byte without consuming it. Returns null at end of input.
    pub fn peek(self: *Tokenizer) ?u8 {
        self.pos = self.scanner.nextNonSpace(self.input, self.pos);
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    /// Consume and return the next token, skipping leading whitespace.
    /// Returns null at end of input.
    pub fn next(self: *Tokenizer) Error!?Token {
        self.pos = self.scanner.nextNonSpace(self.input, self.pos);
        if (self.pos >= self.input.len) return null;
        return switch (self.input[self.pos]) {
            '{' => self.single(.object_begin),
            '}' => self.single(.object_end),
            '[' => self.single(.array_begin),
            ']' => self.single(.array_end),
            ':' => self.single(.colon),
            ',' => self.single(.comma),
            '"' => try self.scanString(),
            '-', '0'...'9' => try self.scanNumber(),
            't' => try self.literal("true", .true_lit),
            'f' => try self.literal("false", .false_lit),
            'n' => try self.literal("null", .null_lit),
            else => error.InvalidCharacter,
        };
    }

    fn single(self: *Tokenizer, tag: TokenTag) Token {
        defer self.pos += 1;
        return .{ .tag = tag, .slice = self.input[self.pos .. self.pos + 1] };
    }

    pub fn scanString(self: *Tokenizer) Error!Token {
        assert(self.input[self.pos] == '"');
        const start = self.pos;
        self.pos += 1;
        var has_escape = false;

        const qt: LaneVec() = @splat('"');
        const bs_vec: LaneVec() = @splat('\\');
        const ct: LaneVec() = @splat(@as(u8, 0x20));

        while (self.pos < self.input.len) {
            if (self.pos + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[self.pos..][0..64];
                const mask = blk: {
                    const N = comptime laneN();
                    const iters = 64 / N;
                    var m: u64 = 0;
                    comptime var lane: usize = 0;
                    inline while (lane < iters) : (lane += 1) {
                        const chunk: LaneVec() = block[lane * N ..][0..N].*;
                        const hit = (chunk == qt) | (chunk == bs_vec) | (chunk < ct);
                        const lm = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                        m |= @as(u64, lm) << (lane * N);
                    }
                    break :blk m;
                };

                if (mask == 0) {
                    self.pos += 64;
                    if (self.pos - start > MAX_TOKEN_LEN) return error.TokenTooLong;
                    continue;
                }
                self.pos += @ctz(mask);
            }

            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1;
                return .{ .tag = .string, .slice = self.input[start..self.pos], .has_escape = has_escape };
            }
            if (c == '\\') {
                has_escape = true;
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
                const esc = self.input[self.pos];
                self.pos += 1;
                switch (esc) {
                    '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => {},
                    'u' => {
                        if (self.pos + 4 > self.input.len) return error.UnexpectedEndOfInput;
                        for (self.input[self.pos .. self.pos + 4]) |hc| {
                            switch (hc) {
                                '0'...'9', 'a'...'f', 'A'...'F' => {},
                                else => return error.InvalidEscape,
                            }
                        }
                        self.pos += 4;
                    },
                    else => return error.InvalidEscape,
                }
                continue;
            }
            if (c < 0x20) return error.InvalidCharacter;
            self.pos += 1;
            if (self.pos - start > MAX_TOKEN_LEN) return error.TokenTooLong;
        }
        return error.UnexpectedEndOfInput;
    }

    pub fn scanNumber(self: *Tokenizer) Error!Token {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            self.pos = numberEndSimd(self.input, self.pos);
        } else return error.InvalidNumber;
        var is_float = false;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            const before = self.pos;
            self.pos = numberEndSimd(self.input, self.pos);
            if (self.pos == before) return error.InvalidNumber;
        }
        if (self.pos < self.input.len and
            (self.input[self.pos] == 'e' or self.input[self.pos] == 'E'))
        {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.input.len and
                (self.input[self.pos] == '+' or self.input[self.pos] == '-'))
                self.pos += 1;
            const before = self.pos;
            self.pos = numberEndSimd(self.input, self.pos);
            if (self.pos == before) return error.InvalidNumber;
        }
        const sl = self.input[start..self.pos];
        if (sl.len > MAX_TOKEN_LEN) return error.TokenTooLong;
        return .{ .tag = .number, .slice = sl, .is_float = is_float };
    }

    fn literal(self: *Tokenizer, comptime word: []const u8, tag: TokenTag) Error!Token {
        if (self.pos + word.len > self.input.len) return error.UnexpectedEndOfInput;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + word.len], word))
            return error.UnexpectedToken;
        defer self.pos += word.len;
        return .{ .tag = tag, .slice = self.input[self.pos .. self.pos + word.len] };
    }
};

/// Consume the next non-whitespace byte and assert it is `:`. Used after parsing an object key.
pub fn expectColon(tok: *Tokenizer) Error!void {
    tok.pos = tok.scanner.nextNonSpace(tok.input, tok.pos);
    if (tok.pos >= tok.input.len or tok.input[tok.pos] != ':') return error.UnexpectedToken;
    tok.pos += 1;
}
