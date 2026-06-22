const std = @import("std");
const eql = std.mem.eql;

const simd = @import("../../simd.zig");

const Error = @import("../../types.zig").Error;
const MAX_INPUT_BYTES = @import("../../types.zig").MAX_INPUT_BYTES;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const SpaceScanner = simd.SpaceScanner;
const numberEndSimd = simd.numberEndSimd;

pub const TokenTag = enum {
    node_name,
    string,
    number,
    boolean,
    null_lit,
    keyword_number,
    type_annotation,
    open_brace,
    close_brace,
    equals,
    semicolon,
};

pub const Token = struct {
    tag: TokenTag,
    slice: []const u8,
    is_float: bool = false,
};

pub const KdlTokenizer = struct {
    input: []const u8,
    pos: usize,
    line: usize,

    pub fn init(input: []const u8) Error!KdlTokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{ .input = input, .pos = 0, .line = 1 };
    }

    pub fn atEnd(self: *const KdlTokenizer) bool {
        return self.pos >= self.input.len;
    }

    pub fn peek(self: *const KdlTokenizer) u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else 0;
    }

    pub fn peekN(self: *const KdlTokenizer, n: usize) u8 {
        return if (self.pos + n < self.input.len) self.input[self.pos + n] else 0;
    }

    pub fn next(self: *KdlTokenizer) Error!?Token {
        self.skipWhitespaceAndComments() catch |e| return e;
        if (self.atEnd()) return null;

        switch (self.input[self.pos]) {
            ';' => return @as(?Token, self.single(.semicolon)),
            '{' => return @as(?Token, self.single(.open_brace)),
            '}' => return @as(?Token, self.single(.close_brace)),
            '=' => return @as(?Token, self.single(.equals)),
            '(' => return @as(?Token, try self.scanTypeAnnotation()),
            '\\' => {
                self.skipLineContinuation();
                return try self.next();
            },
            '"' => {
                if (self.pos + 2 < self.input.len and
                    self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"')
                {
                    return @as(?Token, try self.scanMultilineString());
                }
                return @as(?Token, try self.scanQuotedString());
            },
            '#' => {
                var h: usize = 1;
                while (self.peekN(h) == '#') h += 1;
                if (self.peekN(h) == '"') return @as(?Token, try self.scanRawString());
                return @as(?Token, try self.scanKeywordOrHashIdent());
            },
            '+', '-', '0'...'9', '.' => return @as(?Token, try self.scanNumber()),
            'n' => {
                if (self.pos + 3 < self.input.len and eql(u8, self.input[self.pos..][0..4], "null") and
                    (self.pos + 4 >= self.input.len or isNullDelimiter(self.input[self.pos + 4])))
                {
                    const tok = self.single(.null_lit);
                    self.pos += 3;
                    return @as(?Token, tok);
                }
                return @as(?Token, try self.scanIdentifier());
            },
            else => return @as(?Token, try self.scanIdentifier()),
        }
    }

    fn single(self: *KdlTokenizer, tag: TokenTag) Token {
        defer self.pos += 1;
        return .{ .tag = tag, .slice = self.input[self.pos..][0..1] };
    }

    pub fn skipNewline(self: *KdlTokenizer) void {
        if (self.pos >= self.input.len) return;
        if (self.input[self.pos] == '\r' and self.peekN(1) == '\n') {
            self.pos += 2;
        } else if (self.input[self.pos] == '\n') {
            self.pos += 1;
        } else if (self.input[self.pos] == '\r') {
            self.pos += 1;
        }
        self.line += 1;
    }

    fn nonSpaceBits(block: *const [64]u8) u64 {
        return SpaceScanner.nonSpaceBits(block);
    }

    fn nonInlineBits(block: *const [64]u8) u64 {
        const N = comptime laneN();
        const iters = 64 / N;
        const sp: LaneVec() = @splat(@as(u8, ' '));
        const tb: LaneVec() = @splat(@as(u8, '\t'));
        var ws: u64 = 0;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const is_ws = (chunk == sp) | (chunk == tb);
            const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(is_ws)));
            ws |= lm << (lane * N);
        }
        return ~ws;
    }

    fn countNewlines(block: *const [64]u8, len: usize) u32 {
        const N = comptime laneN();
        const nl: LaneVec() = @splat(@as(u8, '\n'));
        var nlc: u32 = 0;
        const iters = 64 / N;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            if (lane * N >= len) break;
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const is_nl = chunk == nl;
            nlc += @popCount(@as(u32, @as(LaneMask(), @bitCast(@intFromBool(is_nl)))));
        }
        var i = (len / N) * N;
        while (i < len) : (i += 1) {
            if (block[i] == '\n') nlc += 1;
        }
        return nlc;
    }

    pub fn skipWhitespaceAndComments(self: *KdlTokenizer) Error!void {
        while (self.pos < self.input.len) {
            if (self.pos + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[self.pos..][0..64];
                const bits = nonSpaceBits(block);
                if (bits == 0) {
                    self.line += countNewlines(block, 64);
                    self.pos += 64;
                    continue;
                }
                const first = @ctz(bits);
                if (first > 0) {
                    self.line += countNewlines(block, first);
                    self.pos += first;
                }
            }

            switch (self.input[self.pos]) {
                ' ', '\t' => self.pos += 1,
                '\n', '\r' => {
                    if (self.input[self.pos] == '\r' and self.peekN(1) == '\n') self.pos += 1;
                    self.pos += 1;
                    self.line += 1;
                },
                '/' => {
                    const c2 = self.peekN(1);
                    if (c2 == '/') {
                        self.pos += 2;
                        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                    } else if (c2 == '*') {
                        try self.skipBlockComment();
                    } else if (c2 == '-') {
                        self.pos += 2;
                        while (self.pos < self.input.len) {
                            switch (self.input[self.pos]) {
                                '\n', '\r' => break,
                                '/' => {
                                    if (self.peekN(1) == '/') {
                                        self.pos += 2;
                                        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                                        continue;
                                    }
                                    if (self.peekN(1) == '*') {
                                        try self.skipBlockComment();
                                        continue;
                                    }
                                    self.pos += 1;
                                },
                                '\\' => {
                                    self.skipLineContinuation();
                                },
                                else => self.pos += 1,
                            }
                        }
                    } else {
                        return;
                    }
                },
                '\\' => {
                    self.skipLineContinuation();
                },
                else => return,
            }
        }
    }

    pub fn skipInline(self: *KdlTokenizer) Error!void {
        while (self.pos < self.input.len) {
            if (self.pos + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[self.pos..][0..64];
                const bits = nonInlineBits(block);
                if (bits == 0) {
                    self.pos += 64;
                    continue;
                }
                const first = @ctz(bits);
                self.pos += first;
            }

            switch (self.input[self.pos]) {
                ' ', '\t' => self.pos += 1,
                '/' => {
                    const c2 = self.peekN(1);
                    if (c2 == '/') {
                        self.pos += 2;
                        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                    } else if (c2 == '*') {
                        try self.skipBlockComment();
                    } else if (c2 == '-') {
                        self.pos += 2;
                        while (self.pos < self.input.len) {
                            switch (self.input[self.pos]) {
                                '\n', '\r' => return,
                                else => self.pos += 1,
                            }
                        }
                    } else {
                        return;
                    }
                },
                else => return,
            }
        }
    }

    fn skipBlockComment(self: *KdlTokenizer) Error!void {
        var depth: u32 = 1;
        self.pos += 2;
        while (self.pos < self.input.len and depth > 0) {
            if (self.input[self.pos] == '/' and self.peekN(1) == '*') {
                depth += 1;
                self.pos += 2;
            } else if (self.input[self.pos] == '*' and self.peekN(1) == '/') {
                depth -= 1;
                self.pos += 2;
            } else {
                if (self.input[self.pos] == '\n') self.line += 1;
                self.pos += 1;
            }
        }
        if (depth > 0) return error.UnexpectedEndOfInput;
    }

    pub fn skipLineContinuation(self: *KdlTokenizer) void {
        self.pos += 1;
        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t' => self.pos += 1,
                '\n', '\r' => {
                    if (self.input[self.pos] == '\r' and self.peekN(1) == '\n') self.pos += 1;
                    self.pos += 1;
                    self.line += 1;
                    return;
                },
                '/' => {
                    if (self.peekN(1) == '/') {
                        self.pos += 2;
                        while (self.pos < self.input.len and self.input[self.pos] != '\n') self.pos += 1;
                        continue;
                    }
                    if (self.peekN(1) == '*') {
                        self.skipBlockComment() catch return;
                        continue;
                    }
                    return;
                },
                else => return,
            }
        }
    }

    fn scanQuotedString(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 1;
        const dq: LaneVec() = @splat('"');
        const bs: LaneVec() = @splat('\\');

        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const N = comptime laneN();
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == dq) | (chunk == bs);
                const lm = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= @as(u64, lm) << (lane * N);
            }
            if (mask == 0) {
                self.pos += 64;
                continue;
            }
            self.pos += @ctz(mask);
            break;
        }

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1;
                return .{ .tag = .string, .slice = self.input[start..self.pos] };
            }
            if (c != '\\') {
                self.pos += 1;
                continue;
            }
            self.pos += 1;
            if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
            switch (self.input[self.pos]) {
                '\n' => {
                    self.pos += 1;
                    self.line += 1;
                },
                '\r' => {
                    self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
                    self.line += 1;
                },
                'u' => {
                    self.pos += 1;
                    if (self.pos < self.input.len and self.input[self.pos] == '{') {
                        self.pos += 1;
                        while (self.pos < self.input.len and self.input[self.pos] != '}') self.pos += 1;
                        if (self.pos < self.input.len) self.pos += 1;
                    } else {
                        if (self.pos + 4 > self.input.len) return error.UnexpectedEndOfInput;
                        self.pos += 4;
                    }
                },
                else => self.pos += 1,
            }
            if (self.pos + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[self.pos..][0..64];
                const N = comptime laneN();
                const iters = 64 / N;
                var mask: u64 = 0;
                comptime var lane: usize = 0;
                inline while (lane < iters) : (lane += 1) {
                    const chunk: LaneVec() = block[lane * N ..][0..N].*;
                    const hit = (chunk == dq) | (chunk == bs);
                    const lm = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                    mask |= @as(u64, lm) << (lane * N);
                }
                if (mask == 0) {
                    self.pos += 64;
                    continue;
                }
                self.pos += @ctz(mask);
            }
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanRawString(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        var hash_count: usize = 0;
        while (self.pos < self.input.len and self.input[self.pos] == '#') {
            hash_count += 1;
            self.pos += 1;
        }
        if (self.pos >= self.input.len or self.input[self.pos] != '"') return error.UnexpectedToken;
        self.pos += 1;

        const dq: LaneVec() = @splat('"');

        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const N = comptime laneN();
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = chunk == dq;
                const lm = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= @as(u64, lm) << (lane * N);
            }
            if (mask == 0) {
                self.pos += 64;
                continue;
            }
            var bits = mask;
            while (bits != 0) {
                const bit = @ctz(bits);
                const dq_pos = self.pos + bit;
                var i: usize = 0;
                while (i < hash_count) : (i += 1) {
                    if (dq_pos + 1 + i >= self.input.len or self.input[dq_pos + 1 + i] != '#') break;
                }
                if (i == hash_count) {
                    self.pos = dq_pos + 1 + hash_count;
                    return .{ .tag = .string, .slice = self.input[start..self.pos] };
                }
                bits &= bits - 1;
            }
            self.pos += 64;
        }

        while (self.pos < self.input.len) {
            if (self.input[self.pos] == '"') {
                var i: usize = 0;
                while (i < hash_count) : (i += 1) {
                    if (self.pos + 1 + i >= self.input.len or self.input[self.pos + 1 + i] != '#') break;
                }
                if (i == hash_count) {
                    self.pos += 1 + hash_count;
                    return .{ .tag = .string, .slice = self.input[start..self.pos] };
                }
            }
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanMultilineString(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 3;
        if (self.pos < self.input.len and self.input[self.pos] == '\r') self.pos += 1;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
            self.line += 1;
        }
        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                self.pos += 3;
                return .{ .tag = .string, .slice = self.input[start..self.pos] };
            }
            if (self.input[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanKeywordOrHashIdent(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 1;
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        const rem = self.input.len - self.pos;

        if (rem >= 4 and eql(u8, self.input[self.pos..][0..4], "true") and
            (rem == 4 or isKdlDelimiter(self.input[self.pos + 4])))
        {
            self.pos += 4;
            return .{ .tag = .boolean, .slice = self.input[start..self.pos] };
        }
        if (rem >= 5 and eql(u8, self.input[self.pos..][0..5], "false") and
            (rem == 5 or isKdlDelimiter(self.input[self.pos + 5])))
        {
            self.pos += 5;
            return .{ .tag = .boolean, .slice = self.input[start..self.pos] };
        }
        if (rem >= 4 and eql(u8, self.input[self.pos..][0..4], "null") and
            (rem == 4 or isKdlDelimiter(self.input[self.pos + 4])))
        {
            self.pos += 4;
            return .{ .tag = .null_lit, .slice = self.input[start..self.pos] };
        }
        if (rem >= 3 and eql(u8, self.input[self.pos..][0..3], "inf") and
            (rem == 3 or isKdlDelimiter(self.input[self.pos + 3])))
        {
            self.pos += 3;
            return .{ .tag = .number, .slice = self.input[start..self.pos], .is_float = true };
        }
        if (rem >= 4 and eql(u8, self.input[self.pos..][0..4], "-inf") and
            (rem == 4 or isKdlDelimiter(self.input[self.pos + 4])))
        {
            self.pos += 4;
            return .{ .tag = .number, .slice = self.input[start..self.pos], .is_float = true };
        }
        if (rem >= 3 and eql(u8, self.input[self.pos..][0..3], "nan") and
            (rem == 3 or isKdlDelimiter(self.input[self.pos + 3])))
        {
            self.pos += 3;
            return .{ .tag = .number, .slice = self.input[start..self.pos], .is_float = true };
        }

        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r', '(', ')', '{', '}', '/', '\\', '"', ';', '=' => break,
                else => self.pos += 1,
            }
        }
        return .{ .tag = .node_name, .slice = self.input[start..self.pos] };
    }

    fn scanNumber(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        if (self.input[self.pos] == '+' or self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;

        if (self.input[self.pos] == '0' and self.pos + 1 < self.input.len) {
            switch (self.input[self.pos + 1]) {
                'x', 'X' => {
                    self.pos += 2;
                    while (self.pos < self.input.len) {
                        switch (self.input[self.pos]) {
                            '0'...'9', 'a'...'f', 'A'...'F', '_' => self.pos += 1,
                            else => break,
                        }
                    }
                    return .{ .tag = .number, .slice = self.input[start..self.pos] };
                },
                'o', 'O' => {
                    self.pos += 2;
                    while (self.pos < self.input.len) {
                        switch (self.input[self.pos]) {
                            '0'...'7', '_' => self.pos += 1,
                            else => break,
                        }
                    }
                    return .{ .tag = .number, .slice = self.input[start..self.pos] };
                },
                'b', 'B' => {
                    self.pos += 2;
                    while (self.pos < self.input.len) {
                        switch (self.input[self.pos]) {
                            '0', '1', '_' => self.pos += 1,
                            else => break,
                        }
                    }
                    return .{ .tag = .number, .slice = self.input[start..self.pos] };
                },
                else => {},
            }
        }

        var is_float = false;

        if (self.input[self.pos] == '0') {
            self.pos += 1;
            if (self.pos < self.input.len and self.input[self.pos] == '_') {
                self.pos += 1;
                self.scanDigitsWithUnderscores();
            }
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            self.scanDigitsWithUnderscores();
        } else if (self.input[self.pos] == '.') {
            is_float = true;
            self.pos += 1;
            if (self.pos >= self.input.len or self.input[self.pos] < '0' or self.input[self.pos] > '9')
                return error.InvalidNumber;
            self.scanDigitsWithUnderscores();
        } else {
            return error.InvalidNumber;
        }

        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            if (is_float) return error.InvalidNumber;
            is_float = true;
            self.pos += 1;
            const before = self.pos;
            self.scanDigitsWithUnderscores();
            if (self.pos == before) return error.InvalidNumber;
        }

        if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
            is_float = true;
            self.pos += 1;
            if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-'))
                self.pos += 1;
            const before = self.pos;
            self.scanDigitsWithUnderscores();
            if (self.pos == before) return error.InvalidNumber;
        }

        return .{ .tag = .number, .slice = self.input[start..self.pos], .is_float = is_float };
    }

    fn scanDigitsWithUnderscores(self: *KdlTokenizer) void {
        while (true) {
            self.pos = numberEndSimd(self.input, self.pos);
            if (self.pos < self.input.len and self.input[self.pos] == '_') {
                self.pos += 1;
            } else break;
        }
    }

    fn scanTypeAnnotation(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        self.pos += 1;
        try self.skipWhitespaceAndComments();
        while (self.pos < self.input.len and self.input[self.pos] != ')') {
            if (self.input[self.pos] == '\n') self.line += 1;
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        self.pos += 1;
        return .{ .tag = .type_annotation, .slice = self.input[start..self.pos] };
    }

    pub fn scanIdentifier(self: *KdlTokenizer) Error!Token {
        const start = self.pos;
        const N = comptime laneN();
        const sp: LaneVec() = @splat(@as(u8, ' '));
        const tb: LaneVec() = @splat(@as(u8, '\t'));
        const nl: LaneVec() = @splat(@as(u8, '\n'));
        const cr: LaneVec() = @splat(@as(u8, '\r'));
        const lp: LaneVec() = @splat(@as(u8, '('));
        const rp: LaneVec() = @splat(@as(u8, ')'));
        const lb: LaneVec() = @splat(@as(u8, '{'));
        const rb: LaneVec() = @splat(@as(u8, '}'));
        const sl: LaneVec() = @splat(@as(u8, '/'));
        const bs: LaneVec() = @splat(@as(u8, '\\'));
        const dq: LaneVec() = @splat(@as(u8, '"'));
        const hh: LaneVec() = @splat(@as(u8, '#'));
        const sc: LaneVec() = @splat(@as(u8, ';'));
        const eq: LaneVec() = @splat(@as(u8, '='));

        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == sp) | (chunk == tb) | (chunk == nl) | (chunk == cr) |
                    (chunk == lp) | (chunk == rp) | (chunk == lb) | (chunk == rb) |
                    (chunk == sl) | (chunk == bs) | (chunk == dq) | (chunk == hh) |
                    (chunk == sc) | (chunk == eq);
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << (lane * N);
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                return .{ .tag = .node_name, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }

        while (self.pos < self.input.len) {
            switch (self.input[self.pos]) {
                ' ', '\t', '\n', '\r', '(', ')', '{', '}', '/', '\\', '"', '#', ';', '=' => break,
                else => self.pos += 1,
            }
        }
        return .{ .tag = .node_name, .slice = self.input[start..self.pos] };
    }
};

fn isNullDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ')', '}', ';', '=', '/' => true,
        else => false,
    };
}

fn isKdlDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '(', ')', '{', '}', '/', '\\', '"', ';', '=' => true,
        else => false,
    };
}
