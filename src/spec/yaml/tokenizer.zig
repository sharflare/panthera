const std = @import("std");
const eql = std.mem.eql;

const simd = @import("../../simd.zig");

const Error = @import("../../types.zig").Error;
const MAX_INPUT_BYTES = @import("../../types.zig").MAX_INPUT_BYTES;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const SpaceScanner = simd.SpaceScanner;

pub const YamlTokenizer = struct {
    input: []const u8,
    pos: usize,
    flow_depth: u32,

    pub fn init(input: []const u8) Error!YamlTokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{ .input = input, .pos = 0, .flow_depth = 0 };
    }

    pub fn atEnd(self: *const YamlTokenizer) bool {
        return self.pos >= self.input.len;
    }

    pub fn peek(self: *const YamlTokenizer) u8 {
        return if (self.pos < self.input.len) self.input[self.pos] else 0;
    }

    pub fn peekLine(self: *YamlTokenizer) []const u8 {
        const end = std.mem.indexOfScalarPos(u8, self.input, self.pos, '\n') orelse self.input.len;
        return self.input[self.pos..end];
    }

    pub fn skipWhitespace(self: *YamlTokenizer) void {
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
                ' ', '\t' => self.pos += 1,
                else => return,
            }
        }
    }

    pub fn skipLine(self: *YamlTokenizer) void {
        while (self.pos < self.input.len and self.input[self.pos] != '\n') {
            self.pos += 1;
        }
        if (self.pos < self.input.len and self.input[self.pos] == '\n') {
            self.pos += 1;
        }
    }

    pub fn measureIndent(self: *YamlTokenizer) usize {
        var i = self.pos;
        while (i < self.input.len) {
            if (i + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[i..][0..64];
                const bits = SpaceScanner.nonSpaceBits(block);
                if (bits == 0) {
                    i += 64;
                    continue;
                }
                i += @ctz(bits);
                return i - self.pos;
            }
            switch (self.input[i]) {
                ' ', '\t' => i += 1,
                else => return i - self.pos,
            }
        }
        return i - self.pos;
    }

    pub fn blankLine(self: *YamlTokenizer) bool {
        var i = self.pos;
        while (i < self.input.len and self.input[i] != '\n') {
            if (i + 64 <= self.input.len) {
                const block: *const [64]u8 = self.input[i..][0..64];
                const bits = SpaceScanner.nonSpaceBits(block);
                if (bits == 0) {
                    i += 64;
                    continue;
                }
                const ns = @ctz(bits);
                if (block[ns] == '#' or block[ns] == '\n') return true;
                return false;
            }
            switch (self.input[i]) {
                ' ', '\t' => i += 1,
                '#' => return true,
                else => return false,
            }
        }
        return true;
    }

    pub fn skipEmpty(self: *YamlTokenizer) void {
        while (self.pos < self.input.len) {
            self.skipWhitespace();
            if (self.atEnd()) return;
            if (self.peek() == '#') {
                self.skipLine();
                continue;
            }
            if (self.peek() == '\n') {
                self.pos += 1;
                continue;
            }
            break;
        }
    }

    pub fn scanPlain(self: *YamlTokenizer) ?[]const u8 {
        const line = self.peekLine();
        if (line.len == 0) return null;

        var end: usize = 0;
        while (end < line.len) {
            if (end + 64 <= line.len) {
                const block: *const [64]u8 = line[end..][0..64];
                const sp: LaneVec() = @splat(' ');
                const tab: LaneVec() = @splat('\t');
                const hash: LaneVec() = @splat('#');
                const colon: LaneVec() = @splat(':');
                const comma: LaneVec() = @splat(',');
                const rbrace: LaneVec() = @splat('}');
                const rbrack: LaneVec() = @splat(']');
                var term_mask: u64 = 0;
                var colon_mask: u64 = 0;
                const iters = 64 / laneN();
                comptime var lane: usize = 0;
                inline while (lane < iters) : (lane += 1) {
                    const chunk: LaneVec() = block[lane * laneN() ..][0..laneN()].*;
                    const is_term = (chunk == sp) | (chunk == tab) | (chunk == hash) |
                        (chunk == comma) | (chunk == rbrace) | (chunk == rbrack);
                    const is_colon = chunk == colon;
                    const tm: LaneMask() = @bitCast(@intFromBool(is_term));
                    const cm: LaneMask() = @bitCast(@intFromBool(is_colon));
                    term_mask |= @as(u64, tm) << (lane * laneN());
                    colon_mask |= @as(u64, cm) << (lane * laneN());
                }
                var first_term = term_mask;
                while (colon_mask != 0) {
                    const co = @ctz(colon_mask);
                    if (end + co + 1 < line.len and line[end + co + 1] == ' ') {
                        if (first_term == 0 or co < @ctz(first_term)) {
                            first_term = @as(u64, 1) << @truncate(co);
                        }
                        break;
                    }
                    colon_mask &= colon_mask - 1;
                }
                if (first_term != 0) {
                    end += @ctz(first_term);
                    break;
                }
                end += 64;
                continue;
            }
            switch (line[end]) {
                ' ', '\t' => break,
                '#', '\n', '\r' => break,
                ':' => if (end + 1 < line.len and line[end + 1] == ' ') break,
                ',', '}', ']' => break,
                else => end += 1,
            }
        }
        while (end > 0 and (line[end - 1] == ' ' or line[end - 1] == '\t')) : (end -= 1) {}

        if (end == 0) return null;
        const raw = self.input[self.pos..][0..end];
        self.pos += end;
        return raw;
    }

    pub fn tryConsumeNull(self: *YamlTokenizer) bool {
        const line = self.peekLine();
        if (line.len >= 4) {
            const is_null = eql(u8, line[0..4], "null") or
                eql(u8, line[0..4], "Null") or
                eql(u8, line[0..4], "NULL");
            if (is_null and (line.len == 4 or isNullDelimiter(line[4]))) {
                self.pos += 4;
                return true;
            }
        }
        if (line.len >= 1 and line[0] == '~' and (line.len == 1 or isNullDelimiter(line[1]))) {
            self.pos += 1;
            return true;
        }
        return false;
    }
};

pub fn isNullDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', ',', ']', '}', ':', '#' => true,
        else => false,
    };
}

pub fn fnv1aHash(s: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (s) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

pub fn fieldHash(comptime name: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (name) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

pub fn fieldIdx(comptime fields: []const std.builtin.Type.StructField, key: []const u8) ?usize {
    const h = fnv1aHash(key);
    inline for (fields, 0..) |field, i| {
        if (fieldHash(field.name) == h and eql(u8, key, field.name)) return i;
    }
    return null;
}
