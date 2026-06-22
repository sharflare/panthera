const std = @import("std");
const assert = std.debug.assert;

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");

const Error = types.Error;
const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

const SpaceScanner = simd.SpaceScanner;
const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const numberEndSimd = simd.numberEndSimd;

pub const TokenTag = enum {
    key,
    equals,
    string,
    literal_string,
    multiline_string,
    multiline_literal_string,
    integer,
    float,
    true_lit,
    false_lit,
    offset_datetime,
    local_datetime,
    local_date,
    local_time,
    array_begin,
    array_end,
    inline_table_begin,
    inline_table_end,
    table_header,
    table_array_header,
    newline,
    dot,
};

pub const Token = struct {
    tag: TokenTag,
    slice: []const u8,
};

pub const TomlTokenizer = struct {
    input: []const u8,
    pos: usize,
    scanner: SpaceScanner,

    pub fn init(input: []const u8) Error!TomlTokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{
            .input = input,
            .pos = 0,
            .scanner = SpaceScanner.init(),
        };
    }

    pub fn peek(self: *TomlTokenizer) ?u8 {
        self.skipSpaceAndComments();
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    pub fn next(self: *TomlTokenizer) Error!?Token {
        self.skipSpaceAndComments();
        if (self.pos >= self.input.len) return null;
        if (self.input[self.pos] == '\n') {
            self.pos += 1;
            return .{ .tag = .newline, .slice = "\n" };
        }
        return switch (self.input[self.pos]) {
            '=' => blk: {
                self.pos += 1;
                break :blk .{ .tag = .equals, .slice = "=" };
            },
            '.' => blk: {
                self.pos += 1;
                break :blk .{ .tag = .dot, .slice = "." };
            },
            '[' => if (self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[')
                try self.scanTableArrayHeader()
            else blk: {
                self.pos += 1;
                break :blk .{ .tag = .array_begin, .slice = "[" };
            },
            ']' => blk: {
                self.pos += 1;
                break :blk .{ .tag = .array_end, .slice = "]" };
            },
            '{' => blk: {
                self.pos += 1;
                break :blk .{ .tag = .inline_table_begin, .slice = "{" };
            },
            '}' => blk: {
                self.pos += 1;
                break :blk .{ .tag = .inline_table_end, .slice = "}" };
            },
            '#' => {
                return error.UnexpectedToken;
            },
            '"' => try self.scanBasicString(),
            '\'' => try self.scanLiteralString(),
            't' => try self.matchBoolOrKey("true", .true_lit),
            'f' => try self.matchBoolOrKey("false", .false_lit),
            '+', '-', '0'...'9' => try self.scanNumberOrDate(),
            else => try self.scanBareKey(),
        };
    }

    fn skipSpaceAndComments(self: *TomlTokenizer) void {
        while (true) {
            self.pos = self.scanner.nextNonSpace(self.input, self.pos);
            if (self.pos >= self.input.len) return;
            if (self.input[self.pos] == '#') {
                self.pos += 1;
                while (self.pos < self.input.len and self.input[self.pos] != '\n') {
                    self.pos += 1;
                }
            } else if (self.input[self.pos] == '\r') {
                self.pos += 1;
            } else break;
        }
    }

    fn skipInlineSpace(self: *TomlTokenizer) void {
        self.pos = simd.scanWhileInSet(self.input, self.pos, " \t");
    }

    pub fn scanTableArrayHeader(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos] == '[' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '[');
        self.pos += 2;
        self.skipInlineSpace();
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        const slice = self.input[start..self.pos];
        if (self.pos + 1 >= self.input.len or self.input[self.pos + 1] != ']') return error.UnexpectedToken;
        self.pos += 2;
        return .{ .tag = .table_array_header, .slice = slice };
    }

    pub fn scanTableHeader(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos] == '[');
        self.pos += 1;
        self.skipInlineSpace();
        const start = self.pos;
        while (self.pos < self.input.len and self.input[self.pos] != ']') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        const slice = self.input[start..self.pos];
        self.pos += 1;
        return .{ .tag = .table_header, .slice = slice };
    }

    fn scanBasicString(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos] == '"');
        if (self.pos + 2 < self.input.len and
            self.input[self.pos + 1] == '"' and
            self.input[self.pos + 2] == '"')
        {
            return self.scanMultilineBasicString();
        }
        const start = self.pos;
        self.pos += 1;
        const qt: LaneVec() = @splat('"');
        const bs_vec: LaneVec() = @splat('\\');
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const N = comptime laneN();
            const iters = 64 / N;
            var m: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == qt) | (chunk == bs_vec);
                const lm = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                m |= @as(u64, lm) << (lane * N);
            }

            if (m == 0) {
                self.pos += 64;
                continue;
            }
            self.pos += @ctz(m);
            break;
        }

        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '"') {
                self.pos += 1;
                const sl = self.input[start..self.pos];
                return .{ .tag = .string, .slice = sl };
            }
            if (c == '\\') {
                self.pos += 1;
                if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
                if (self.input[self.pos] == '\n') {
                    self.pos += 1;
                    continue;
                }
                self.pos += 1;
            } else if (c == '\n') {
                return error.InvalidCharacter;
            } else {
                self.pos += 1;
            }
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanMultilineBasicString(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos..].len >= 3 and std.mem.eql(u8, self.input[self.pos..][0..3], "\"\"\""));
        self.pos += 3;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
        const start = self.pos;
        const dq: simd.LaneVec() = @splat(@as(u8, '"'));
        const bs: simd.LaneVec() = @splat(@as(u8, '\\'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / simd.laneN();
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const N = comptime simd.laneN();
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == dq) | (chunk == bs);
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                if (self.input[self.pos] == '"') {
                    if (self.pos + 2 < self.input.len and
                        self.input[self.pos + 1] == '"' and
                        self.input[self.pos + 2] == '"')
                    {
                        const slice = self.input[start..self.pos];
                        self.pos += 3;
                        return .{ .tag = .multiline_string, .slice = slice };
                    }
                    self.pos += 1;
                } else if (self.input[self.pos] == '\\') {
                    self.pos += 1;
                    if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
                    if (self.input[self.pos] == '\n') {
                        self.pos += 1;
                    } else if (self.input[self.pos] == '\r' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') {
                        self.pos += 2;
                    } else {
                        self.pos += 1;
                    }
                }
            } else {
                self.pos += 64;
            }
        }
        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '"' and self.input[self.pos + 1] == '"' and self.input[self.pos + 2] == '"') {
                const slice = self.input[start..self.pos];
                self.pos += 3;
                return .{ .tag = .multiline_string, .slice = slice };
            }
            if (self.input[self.pos] == '\\' and self.pos + 1 < self.input.len) {
                self.pos += 1;
                if (self.input[self.pos] == '\n') {
                    self.pos += 1;
                    continue;
                }
                if (self.input[self.pos] == '\r' and self.pos + 1 < self.input.len and self.input[self.pos + 1] == '\n') {
                    self.pos += 2;
                    continue;
                }
                self.pos += 1;
            } else {
                self.pos += 1;
            }
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanLiteralString(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos] == '\'');
        if (self.pos + 2 < self.input.len and
            self.input[self.pos + 1] == '\'' and
            self.input[self.pos + 2] == '\'')
        {
            return self.scanMultilineLiteralString();
        }
        const start = self.pos;
        self.pos += 1;
        const sq: simd.LaneVec() = @splat(@as(u8, '\''));
        const nl: simd.LaneVec() = @splat(@as(u8, '\n'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / simd.laneN();
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const N = comptime simd.laneN();
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == sq) | (chunk == nl);
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                if (self.input[self.pos] == '\n') return error.InvalidCharacter;
                self.pos += 1;
                return .{ .tag = .literal_string, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            if (c == '\'') {
                self.pos += 1;
                return .{ .tag = .literal_string, .slice = self.input[start..self.pos] };
            }
            if (c == '\n') return error.InvalidCharacter;
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanMultilineLiteralString(self: *TomlTokenizer) Error!Token {
        assert(self.input[self.pos..].len >= 3 and std.mem.eql(u8, self.input[self.pos..][0..3], "'''"));
        self.pos += 3;
        if (self.pos < self.input.len and self.input[self.pos] == '\n') self.pos += 1;
        const start = self.pos;
        const sq: simd.LaneVec() = @splat(@as(u8, '\''));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / simd.laneN();
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const N = comptime simd.laneN();
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const hit = chunk == sq;
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                if (self.pos + 2 < self.input.len and
                    self.input[self.pos + 1] == '\'' and
                    self.input[self.pos + 2] == '\'')
                {
                    const slice = self.input[start..self.pos];
                    self.pos += 3;
                    return .{ .tag = .multiline_literal_string, .slice = slice };
                }
                self.pos += 1;
            } else {
                self.pos += 64;
            }
        }
        while (self.pos + 2 < self.input.len) {
            if (self.input[self.pos] == '\'' and self.input[self.pos + 1] == '\'' and self.input[self.pos + 2] == '\'') {
                const slice = self.input[start..self.pos];
                self.pos += 3;
                return .{ .tag = .multiline_literal_string, .slice = slice };
            }
            self.pos += 1;
        }
        return error.UnexpectedEndOfInput;
    }

    fn scanNumberOrDate(self: *TomlTokenizer) Error!Token {
        const start = self.pos;
        if (self.input[self.pos] == '+' or self.input[self.pos] == '-') {
            self.pos += 1;
        }
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;

        if (self.input[self.pos] == '0' and self.pos + 1 < self.input.len and
            (self.input[self.pos + 1] == 'x' or self.input[self.pos + 1] == 'X'))
        {
            return self.scanHexInt(start);
        }
        if (self.input[self.pos] == '0' and self.pos + 1 < self.input.len and
            (self.input[self.pos + 1] == 'o' or self.input[self.pos + 1] == 'O'))
        {
            return self.scanOctInt(start);
        }
        if (self.input[self.pos] == '0' and self.pos + 1 < self.input.len and
            (self.input[self.pos + 1] == 'b' or self.input[self.pos + 1] == 'B'))
        {
            return self.scanBinInt(start);
        }

        self.pos = numberEndSimd(self.input, self.pos);
        if (self.pos >= self.input.len) {
            return .{ .tag = .integer, .slice = self.input[start..self.pos] };
        }

        const c = self.input[self.pos];
        if (c == '.' or c == 'e' or c == 'E') {
            if (c == '.') {
                if (self.pos + 1 >= self.input.len) return error.InvalidNumber;
                const next_char = self.input[self.pos + 1];
                if (next_char < '0' or next_char > '9') {
                    return .{ .tag = .integer, .slice = self.input[start..self.pos] };
                }
                self.pos += 1;
                self.pos = numberEndSimd(self.input, self.pos);
            }
            if (self.pos < self.input.len and (self.input[self.pos] == 'e' or self.input[self.pos] == 'E')) {
                self.pos += 1;
                if (self.pos < self.input.len and (self.input[self.pos] == '+' or self.input[self.pos] == '-'))
                    self.pos += 1;
                const before = self.pos;
                self.pos = numberEndSimd(self.input, self.pos);
                if (self.pos == before) return error.InvalidNumber;
            }
            if (self.pos < self.input.len and self.input[self.pos] == '.') return error.InvalidNumber;
            return .{ .tag = .float, .slice = self.input[start..self.pos] };
        }

        if (c == 'T' or c == 't') {
            return self.scanDatetime(start);
        }
        if (c == ':') {
            return self.scanLocalTime(start);
        }
        if (c == '-') {
            // Could be date: 2024-01-15 or negative number that ended
            if (self.pos - start == 1) {
                return .{ .tag = .integer, .slice = self.input[start..self.pos] };
            }
            // Check if next is a digit => local date
            if (self.pos + 1 < self.input.len and self.input[self.pos + 1] >= '0' and self.input[self.pos + 1] <= '9') {
                self.pos += 1;
                self.pos = numberEndSimd(self.input, self.pos);
                // Handle day part: YYYY-MM-DD
                if (self.pos < self.input.len and self.input[self.pos] == '-') {
                    if (self.pos + 1 >= self.input.len or self.input[self.pos + 1] < '0' or self.input[self.pos + 1] > '9')
                        return error.InvalidNumber;
                    self.pos += 1;
                    self.pos = numberEndSimd(self.input, self.pos);
                }
                if (self.pos < self.input.len and (self.input[self.pos] == 'T' or self.input[self.pos] == 't')) {
                    return self.scanDatetime(start);
                }
                if (self.pos < self.input.len and self.input[self.pos] == ':') {
                    return self.scanLocalTime(start);
                }
                return .{ .tag = .local_date, .slice = self.input[start..self.pos] };
            }
            return .{ .tag = .integer, .slice = self.input[start..self.pos] };
        }

        return .{ .tag = .integer, .slice = self.input[start..self.pos] };
    }

    fn scanHexInt(self: *TomlTokenizer, start: usize) Error!Token {
        self.pos += 2;
        if (self.pos >= self.input.len) return error.InvalidNumber;
        const N = comptime simd.laneN();
        const lo_d: simd.LaneVec() = @splat(@as(u8, '0'));
        const hi_d: simd.LaneVec() = @splat(@as(u8, '9'));
        const lo_lc: simd.LaneVec() = @splat(@as(u8, 'a'));
        const hi_lc: simd.LaneVec() = @splat(@as(u8, 'f'));
        const lo_uc: simd.LaneVec() = @splat(@as(u8, 'A'));
        const hi_uc: simd.LaneVec() = @splat(@as(u8, 'F'));
        const us: simd.LaneVec() = @splat(@as(u8, '_'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const valid = ((chunk >= lo_d) & (chunk <= hi_d)) |
                    ((chunk >= lo_lc) & (chunk <= hi_lc)) |
                    ((chunk >= lo_uc) & (chunk <= hi_uc)) |
                    (chunk == us);
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(~valid)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                return .{ .tag = .integer, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', 'a'...'f', 'A'...'F', '_' => self.pos += 1,
                else => break,
            }
        }
        return .{ .tag = .integer, .slice = self.input[start..self.pos] };
    }

    fn scanOctInt(self: *TomlTokenizer, start: usize) Error!Token {
        self.pos += 2;
        if (self.pos >= self.input.len) return error.InvalidNumber;
        const N = comptime simd.laneN();
        const lo: simd.LaneVec() = @splat(@as(u8, '0'));
        const hi: simd.LaneVec() = @splat(@as(u8, '7'));
        const us: simd.LaneVec() = @splat(@as(u8, '_'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const valid = ((chunk >= lo) & (chunk <= hi)) | (chunk == us);
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(~valid)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                return .{ .tag = .integer, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'7', '_' => self.pos += 1,
                else => break,
            }
        }
        return .{ .tag = .integer, .slice = self.input[start..self.pos] };
    }

    fn scanBinInt(self: *TomlTokenizer, start: usize) Error!Token {
        self.pos += 2;
        if (self.pos >= self.input.len) return error.InvalidNumber;
        const N = comptime simd.laneN();
        const zero: simd.LaneVec() = @splat(@as(u8, '0'));
        const one: simd.LaneVec() = @splat(@as(u8, '1'));
        const us: simd.LaneVec() = @splat(@as(u8, '_'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const valid = (chunk == zero) | (chunk == one) | (chunk == us);
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(~valid)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                return .{ .tag = .integer, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0', '1', '_' => self.pos += 1,
                else => break,
            }
        }
        return .{ .tag = .integer, .slice = self.input[start..self.pos] };
    }

    fn scanDatetime(self: *TomlTokenizer, start: usize) Error!Token {
        // Already consumed digits-dash-digits-dash-digits 'T' or 't'
        // time: HH:MM:SS[.frac]
        self.pos += 1; // skip T
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', ':' => self.pos += 1,
                '.' => {
                    self.pos += 1;
                    const before = self.pos;
                    self.pos = numberEndSimd(self.input, self.pos);
                    if (self.pos == before) return error.InvalidNumber;
                },
                '+', '-' => {
                    // timezone offset
                    self.pos += 1;
                    while (self.pos < self.input.len) {
                        const d = self.input[self.pos];
                        switch (d) {
                            '0'...'9', ':' => self.pos += 1,
                            else => break,
                        }
                    }
                    return .{ .tag = .offset_datetime, .slice = self.input[start..self.pos] };
                },
                'Z', 'z' => {
                    self.pos += 1;
                    return .{ .tag = .offset_datetime, .slice = self.input[start..self.pos] };
                },
                else => break,
            }
        }
        return .{ .tag = .local_datetime, .slice = self.input[start..self.pos] };
    }

    fn scanLocalTime(self: *TomlTokenizer, start: usize) Error!Token {
        // Already consumed digits:digits
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                '0'...'9', ':' => self.pos += 1,
                '.' => {
                    self.pos += 1;
                    const before = self.pos;
                    self.pos = numberEndSimd(self.input, self.pos);
                    if (self.pos == before) return error.InvalidNumber;
                },
                else => break,
            }
        }
        return .{ .tag = .local_time, .slice = self.input[start..self.pos] };
    }

    fn matchBoolOrKey(self: *TomlTokenizer, comptime word: []const u8, tag: TokenTag) Error!Token {
        if (self.pos + word.len <= self.input.len and
            std.mem.eql(u8, self.input[self.pos..][0..word.len], word))
        {
            const after = self.pos + word.len;
            if (after >= self.input.len or self.input[after] == ' ' or
                self.input[after] == '\t' or self.input[after] == '\n' or
                self.input[after] == '\r' or self.input[after] == '#' or
                self.input[after] == ']' or self.input[after] == '}' or
                self.input[after] == ',' or self.input[after] == '=')
            {
                self.pos = after;
                return .{ .tag = tag, .slice = word };
            }
        }
        return self.scanBareKey();
    }

    fn scanBareKey(self: *TomlTokenizer) Error!Token {
        const start = self.pos;
        const N = comptime simd.laneN();
        const lo_az: simd.LaneVec() = @splat(@as(u8, 'A'));
        const hi_az: simd.LaneVec() = @splat(@as(u8, 'Z'));
        const lo_az_lc: simd.LaneVec() = @splat(@as(u8, 'a'));
        const hi_az_lc: simd.LaneVec() = @splat(@as(u8, 'z'));
        const lo_d: simd.LaneVec() = @splat(@as(u8, '0'));
        const hi_d: simd.LaneVec() = @splat(@as(u8, '9'));
        const da: simd.LaneVec() = @splat(@as(u8, '-'));
        const us: simd.LaneVec() = @splat(@as(u8, '_'));
        while (self.pos + 64 <= self.input.len) {
            const block: *const [64]u8 = self.input[self.pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const valid = ((chunk >= lo_az) & (chunk <= hi_az)) |
                    ((chunk >= lo_az_lc) & (chunk <= hi_az_lc)) |
                    ((chunk >= lo_d) & (chunk <= hi_d)) |
                    (chunk == da) | (chunk == us);
                const invalid = ~valid;
                const lm: u64 = @as(simd.LaneMask(), @bitCast(@intFromBool(invalid)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) {
                self.pos += @ctz(mask);
                if (self.pos == start) return error.InvalidCharacter;
                return .{ .tag = .key, .slice = self.input[start..self.pos] };
            }
            self.pos += 64;
        }
        while (self.pos < self.input.len) {
            const c = self.input[self.pos];
            switch (c) {
                'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => self.pos += 1,
                else => break,
            }
        }
        if (self.pos == start) return error.InvalidCharacter;
        return .{ .tag = .key, .slice = self.input[start..self.pos] };
    }
};
