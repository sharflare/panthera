const std = @import("std");

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");

const Error = types.Error;
const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const SpaceScanner = simd.SpaceScanner;

pub const TokenTag = enum {
    open_tag,
    close_tag,
    tag_end,
    self_close,
    attr_name,
    attr_value,
    equals,
    text,
    comment,
    cdata,
    pi,
};

pub const Token = struct {
    tag: TokenTag,
    slice: []const u8,
};

pub const XmlTokenizer = struct {
    input: []const u8,
    pos: usize,
    line: usize,
    in_tag: bool,

    pub fn init(input: []const u8) Error!XmlTokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{ .input = input, .pos = 0, .line = 1, .in_tag = false };
    }

    pub fn atEnd(self: *const XmlTokenizer) bool {
        return self.pos >= self.input.len;
    }

    pub fn peek(self: *const XmlTokenizer) u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else 0;
    }

    pub fn peekN(self: *const XmlTokenizer, n: usize) u8 {
        return if (self.pos + n < self.input.len) self.input[self.pos + n] else 0;
    }

    pub fn skipWhitespace(self: *XmlTokenizer) void {
        while (self.pos < self.input.len) {
            if (self.pos + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[self.pos..][0..64];
                const bits = SpaceScanner.nonSpaceBits(block);
                if (bits == 0) {
                    self.pos += 64;
                    continue;
                }
                self.pos += @ctz(bits);
                return;
            }
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r' => {
                    if (self.input[self.pos] == '\n') self.line += 1;
                    if (self.input[self.pos] == '\r' and self.peekN(1) == '\n') self.pos += 1;
                    self.pos += 1;
                },
                else => return,
            }
        }
    }

    pub fn next(self: *XmlTokenizer) Error!?Token {
        if (self.atEnd()) return null;

        if (self.in_tag) return self.nextInTag();

        return self.nextInContent();
    }

    fn nextInContent(self: *XmlTokenizer) Error!?Token {
        if (self.input[self.pos] == '<') {
            if (self.pos + 1 >= self.input.len) return error.UnexpectedEndOfInput;
            switch (self.input[self.pos + 1]) {
                '/' => return @as(?Token, try self.scanCloseTag()),
                '?' => return @as(?Token, try self.scanPi()),
                '!' => {
                    if (self.pos + 3 >= self.input.len) return error.UnexpectedEndOfInput;
                    if (self.input[self.pos + 2] == '-' and self.input[self.pos + 3] == '-')
                        return @as(?Token, try self.scanComment());
                    if (self.pos + 9 <= self.input.len and
                        std.mem.eql(u8, self.input[self.pos + 2 ..][0..7], "[CDATA["))
                        return @as(?Token, try self.scanCdata());
                    return error.UnexpectedToken;
                },
                else => return @as(?Token, try self.scanOpenTag()),
            }
        }

        return @as(?Token, try self.scanText());
    }

    fn nextInTag(self: *XmlTokenizer) Error!?Token {
        self.skipWhitespace();
        if (self.atEnd()) return error.UnexpectedEndOfInput;

        const c = self.input[self.pos];
        if (c == '=') {
            self.pos += 1;
            return Token{ .tag = .equals, .slice = self.input[self.pos - 1 ..][0..1] };
        }
        if (c == '>') {
            self.in_tag = false;
            self.pos += 1;
            return Token{ .tag = .tag_end, .slice = self.input[self.pos - 1 ..][0..1] };
        }
        if (c == '/' and self.peekN(1) == '>') {
            self.in_tag = false;
            const tok = Token{ .tag = .self_close, .slice = self.input[self.pos..][0..2] };
            self.pos += 2;
            return tok;
        }
        if (c == '"' or c == '\'') return @as(?Token, try self.scanAttrValue());

        return @as(?Token, try self.scanAttrName());
    }

    fn scanOpenTag(self: *XmlTokenizer) Error!Token {
        self.pos += 1;
        self.in_tag = true;
        const name = self.scanName(">/\t\n\r ");
        if (name.len == 0) return error.UnexpectedToken;
        return Token{ .tag = .open_tag, .slice = name };
    }

    fn scanCloseTag(self: *XmlTokenizer) Error!Token {
        self.pos += 2;
        const name = self.scanName(">");
        if (name.len == 0) return error.UnexpectedToken;
        if (self.atEnd() or self.input[self.pos] != '>') return error.UnexpectedToken;
        self.pos += 1;
        return Token{ .tag = .close_tag, .slice = name };
    }

    fn scanName(self: *XmlTokenizer, delimiters: []const u8) []const u8 {
        const start = self.pos;
        const N = comptime laneN();
        var masks: [256]bool = [_]bool{false} ** 256;
        for (delimiters) |d| masks[d] = true;

        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                var hit: @Vector(N, bool) = @splat(false);
                for (delimiters) |d| {
                    hit = hit | (chunk == @as(LaneVec(), @splat(d)));
                }
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << (lane * N);
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                return self.input[start..self.pos];
            }
            self.pos += 64;
        }

        while (self.pos < self.input.len) {
            if (masks[self.input[self.pos]]) break;
            self.pos += 1;
        }
        return self.input[start..self.pos];
    }

    fn scanAttrName(self: *XmlTokenizer) Error!Token {
        const name = self.scanName("=/>\t\n\r ");
        if (name.len == 0) return error.UnexpectedToken;
        return Token{ .tag = .attr_name, .slice = name };
    }

    fn scanAttrValue(self: *XmlTokenizer) Error!Token {
        const quote = self.input[self.pos];
        self.pos += 1;
        const val_start = self.pos;
        const qv: LaneVec() = @splat(quote);
        const N = comptime laneN();

        while (self.pos + N <= self.input.len) {
            const chunk: LaneVec() = self.input[self.pos..][0..N].*;
            const hit = chunk == qv;
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask != 0) {
                self.pos += @ctz(mask);
                const val = self.input[val_start..self.pos];
                self.pos += 1;
                return Token{ .tag = .attr_value, .slice = val };
            }
            self.pos += N;
        }

        while (self.pos < self.input.len and self.input[self.pos] != quote) {
            self.pos += 1;
        }
        if (self.atEnd()) return error.UnexpectedEndOfInput;
        const val = self.input[val_start..self.pos];
        self.pos += 1;
        return Token{ .tag = .attr_value, .slice = val };
    }

    fn scanText(self: *XmlTokenizer) Error!Token {
        const start = self.pos;
        const lt: LaneVec() = @splat(@as(u8, '<'));
        const N = comptime laneN();

        while (self.pos + N <= self.input.len) {
            const chunk: LaneVec() = self.input[self.pos..][0..N].*;
            const hit = chunk == lt;
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask != 0) {
                self.pos += @ctz(mask);
                return Token{ .tag = .text, .slice = self.input[start..self.pos] };
            }
            self.pos += N;
        }

        while (self.pos < self.input.len and self.input[self.pos] != '<') {
            self.pos += 1;
        }
        return Token{ .tag = .text, .slice = self.input[start..self.pos] };
    }

    fn scanComment(self: *XmlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 4;
        const dash: LaneVec() = @splat(@as(u8, '-'));
        const N = comptime laneN();

        while (self.pos + N <= self.input.len) {
            const chunk: LaneVec() = self.input[self.pos..][0..N].*;
            const hit = chunk == dash;
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask != 0) {
                var bits = mask;
                while (bits != 0) {
                    const bit = @ctz(bits);
                    const p = self.pos + bit;
                    if (p + 2 <= self.input.len and self.input[p + 1] == '-' and self.input[p + 2] == '>') {
                        const content = self.input[start .. p + 3];
                        self.pos = p + 3;
                        return Token{ .tag = .comment, .slice = content };
                    }
                    bits &= bits - 1;
                }
                self.pos += N;
            } else {
                self.pos += N;
            }
        }

        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '-' and self.input[self.pos + 1] == '-' and self.input[self.pos + 2] == '>') {
                const content = self.input[start .. self.pos + 3];
                self.pos += 3;
                return Token{ .tag = .comment, .slice = content };
            }
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanCdata(self: *XmlTokenizer) Error!Token {
        self.pos += 9;
        const start = self.pos;
        const rb: LaneVec() = @splat(@as(u8, ']'));
        const N = comptime laneN();

        while (self.pos + N <= self.input.len) {
            const chunk: LaneVec() = self.input[self.pos..][0..N].*;
            const hit = chunk == rb;
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask != 0) {
                var bits = mask;
                while (bits != 0) {
                    const bit = @ctz(bits);
                    const p = self.pos + bit;
                    if (p + 2 <= self.input.len and self.input[p + 1] == ']' and self.input[p + 2] == '>') {
                        const content = self.input[start..p];
                        self.pos = p + 3;
                        return Token{ .tag = .cdata, .slice = content };
                    }
                    bits &= bits - 1;
                }
                self.pos += N;
            } else {
                self.pos += N;
            }
        }

        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == ']' and self.input[self.pos + 1] == ']' and self.input[self.pos + 2] == '>') {
                const content = self.input[start..self.pos];
                self.pos += 3;
                return Token{ .tag = .cdata, .slice = content };
            }
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanPi(self: *XmlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 2;
        const qm: LaneVec() = @splat(@as(u8, '?'));
        const N = comptime laneN();

        while (self.pos + N <= self.input.len) {
            const chunk: LaneVec() = self.input[self.pos..][0..N].*;
            const hit = chunk == qm;
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask != 0) {
                var bits = mask;
                while (bits != 0) {
                    const bit = @ctz(bits);
                    const p = self.pos + bit;
                    if (p + 1 < self.input.len and self.input[p + 1] == '>') {
                        const content = self.input[start..p];
                        self.pos = p + 2;
                        return Token{ .tag = .pi, .slice = content };
                    }
                    bits &= bits - 1;
                }
                self.pos += N;
            } else {
                self.pos += N;
            }
        }

        while (self.pos + 1 < self.input.len) {
            if (self.input[self.pos] == '?' and self.input[self.pos + 1] == '>') {
                const content = self.input[start..self.pos];
                self.pos += 2;
                return Token{ .tag = .pi, .slice = content };
            }
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }
};
