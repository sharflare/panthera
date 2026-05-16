//! Panthera - Preformant SIMD accelerated json serializer/deserializer in the vein of bytedance/sonic.
//! The API quite closely models the API of std.json
const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

pub const MAX_DEPTH: u32 = 128;
pub const MAX_TOKEN_LEN: usize = 1 << 20;
pub const MAX_INPUT_BYTES: usize = 1 << 30;
const MAX_FIELD_NAME: usize = 4096;

pub const Error = error{
    UnexpectedToken,
    InvalidCharacter,
    InvalidEscape,
    InvalidUtf8,
    InvalidNumber,
    MaxDepthExceeded,
    TokenTooLong,
    InputTooLarge,
    UnexpectedEndOfInput,
    DuplicateField,
    UnknownField,
    MissingField,
    TypeMismatch,
    Overflow,
    OutOfMemory,
};

pub const StringifyOptions = struct {
    whitespace: ?u8 = null,
    emit_null_optional_fields: bool = true,
    escape_unicode: bool = false,
};

pub const ParseOptions = struct {
    reject_unknown_fields: bool = false,
    require_all_fields: bool = false,
    max_depth: u32 = MAX_DEPTH,
    duplicate_field_behavior: enum { use_last, reject } = .use_last,
};

pub const ObjectMap = std.StringArrayHashMapUnmanaged(Value);
pub const Array = std.ArrayListUnmanaged(Value);

pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: Array,
    object: ObjectMap,

    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .array => |*a| {
                for (a.items) |*item| item.deinit(allocator);
                a.deinit(allocator);
            },
            .object => |*o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                o.deinit(allocator);
            },
            .string => |s| allocator.free(s),
            .number_string => |s| allocator.free(s),
            else => {},
        }
    }
};

const SimdWidth = enum { scalar, sse2, avx2, neon };

fn detectSimd() SimdWidth {
    const arch = builtin.cpu.arch;
    if (arch == .x86_64) {
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) return .avx2;
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) return .sse2;
        return .scalar;
    }
    if (arch == .aarch64) return .neon;
    return .scalar;
}

const SIMD_WIDTH: SimdWidth = detectSimd();

fn laneN() comptime_int {
    return switch (SIMD_WIDTH) {
        .avx2 => 32,
        .sse2, .neon => 16,
        .scalar => 8,
    };
}

fn LaneMask() type {
    return switch (SIMD_WIDTH) {
        .avx2 => u32,
        .sse2, .neon => u16,
        .scalar => u8,
    };
}

fn LaneVec() type {
    return @Vector(laneN(), u8);
}

fn getStringBits(block: *const [64]u8, prev_escaped: *u64) u64 {
    const N = comptime laneN();
    const iters = 64 / N;

    var bs_bits: u64 = 0;
    var qt_bits: u64 = 0;

    const bs_splat: LaneVec() = @splat('\\');
    const qt_splat: LaneVec() = @splat('"');

    comptime var lane: usize = 0;
    inline while (lane < iters) : (lane += 1) {
        const chunk: LaneVec() = block[lane * N ..][0..N].*;
        const lbs = @as(LaneMask(), @bitCast(@intFromBool(chunk == bs_splat)));
        const lqt = @as(LaneMask(), @bitCast(@intFromBool(chunk == qt_splat)));
        const shift: u6 = @intCast(lane * N);
        bs_bits |= @as(u64, lbs) << shift;
        qt_bits |= @as(u64, lqt) << shift;
    }

    if (bs_bits == 0) {
        const carry_in = prev_escaped.*;
        prev_escaped.* = 0;
        const real_qt = qt_bits & ~carry_in;
        var x = real_qt;
        x ^= x << 1;
        x ^= x << 2;
        x ^= x << 4;
        x ^= x << 8;
        x ^= x << 16;
        x ^= x << 32;
        return x;
    }

    const starts = bs_bits & ~(bs_bits << 1);
    const even_starts = starts & 0x5555_5555_5555_5555;
    const odd_starts = starts & 0xAAAA_AAAA_AAAA_AAAA;
    const even_carry = @addWithOverflow(bs_bits, even_starts);
    const odd_carry = @addWithOverflow(bs_bits, odd_starts);
    const even_ends = (even_carry[0] ^ bs_bits) & ~bs_bits;
    const odd_ends = (odd_carry[0] ^ bs_bits) & ~bs_bits;
    var escaped = (even_ends & 0xAAAA_AAAA_AAAA_AAAA) |
        (odd_ends & 0x5555_5555_5555_5555);
    escaped |= prev_escaped.*;
    prev_escaped.* = if (odd_carry[1] != 0) 1 else 0;

    const real_qt = qt_bits & ~escaped;

    var x = real_qt;
    x ^= x << 1;
    x ^= x << 2;
    x ^= x << 4;
    x ^= x << 8;
    x ^= x << 16;
    x ^= x << 32;
    return x;
}

const SpaceScanner = struct {
    bitmap: u64,
    base: usize,

    fn init() SpaceScanner {
        return .{ .bitmap = 0, .base = std.math.maxInt(usize) };
    }

    fn nonSpaceBits(block: *const [64]u8) u64 {
        const N = comptime laneN();
        const iters = 64 / N;
        const sp: LaneVec() = @splat(@as(u8, ' '));
        const tb: LaneVec() = @splat(@as(u8, '\t'));
        const lf: LaneVec() = @splat(@as(u8, '\n'));
        const cr: LaneVec() = @splat(@as(u8, '\r'));
        var ws: u64 = 0;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const lws = @as(LaneMask(), @bitCast(@intFromBool(
                (chunk == sp) | (chunk == tb) | (chunk == lf) | (chunk == cr),
            )));
            const shift: u6 = @intCast(lane * N);
            ws |= @as(u64, lws) << shift;
        }
        return ~ws;
    }

    fn nextNonSpace(self: *SpaceScanner, input: []const u8, start: usize) usize {
        var i = start;
        if (i >= input.len) return input.len;

        const c = input[i];
        if (c != ' ' and c != '\t' and c != '\n' and c != '\r') return i;

        if (i >= self.base and i < self.base + 64) {
            const offset: u6 = @intCast(i - self.base);
            const mask = self.bitmap & (~@as(u64, 0) << offset);
            if (mask != 0) return self.base + @ctz(mask);
            i = self.base + 64;
            if (i >= input.len) return input.len;
            const c2 = input[i];
            if (c2 != ' ' and c2 != '\t' and c2 != '\n' and c2 != '\r') return i;
        }

        var padded: [64]u8 = @splat(' ');
        while (i < input.len) {
            const remaining = input.len - i;
            if (remaining >= 64) {
                const block: *const [64]u8 = input[i..][0..64];
                const bits = nonSpaceBits(block);
                self.bitmap = bits;
                self.base = i;
                if (bits != 0) return i + @ctz(bits);
                i += 64;
            } else {
                @memcpy(padded[0..remaining], input[i..]);
                @memset(padded[remaining..], ' ');
                const bits = nonSpaceBits(&padded);
                self.bitmap = bits;
                self.base = i;
                const first = @ctz(bits);
                if (first < remaining) return i + first;
                return input.len;
            }
        }
        return input.len;
    }
};

const SPACE_TABLE: [256]u8 = blk: {
    var t = [_]u8{0} ** 256;
    t[' '] = 1;
    t['\t'] = 1;
    t['\n'] = 1;
    t['\r'] = 1;
    break :blk t;
};

fn isSpace(c: u8) bool {
    return SPACE_TABLE[c] != 0;
}

fn swarParseU64Decimal(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;

    var buf: [16]u8 = @splat('0');
    @memcpy(buf[16 - s.len ..], s);

    const v0: u64 = @bitCast(buf[0..8].*);
    const v1: u64 = @bitCast(buf[8..16].*);
    const z: u64 = 0x3030_3030_3030_3030;
    const nine: u64 = 0x0909_0909_0909_0909;
    const d0 = v0 -% z;
    const d1 = v1 -% z;
    const limit: u64 = nine +% 0x7676_7676_7676_7676;
    if ((d0 +% limit) & 0x8080_8080_8080_8080 != 0x8080_8080_8080_8080) return null;
    if ((d1 +% limit) & 0x8080_8080_8080_8080 != 0x8080_8080_8080_8080) return null;

    const p0 = pack8(pack4(pack2(d0)));
    const p1 = pack8(pack4(pack2(d1)));
    return p0 * 100_000_000 + p1;
}

inline fn pack2(d: u64) u64 {
    const lo = d & 0x00FF_00FF_00FF_00FF;
    const hi = (d >> 8) & 0x00FF_00FF_00FF_00FF;
    return lo + hi * 10;
}
inline fn pack4(d: u64) u64 {
    const lo = d & 0x0000_FFFF_0000_FFFF;
    const hi = (d >> 16) & 0x0000_FFFF_0000_FFFF;
    return lo + hi * 100;
}
inline fn pack8(d: u64) u64 {
    const lo = d & 0x0000_0000_FFFF_FFFF;
    const hi = d >> 32;
    return lo + hi * 10_000;
}

fn simdParseU64Decimal(s: []const u8) ?u64 {
    if (s.len == 0 or s.len > 16) return null;
    if (comptime SIMD_WIDTH == .scalar) return swarParseU64Decimal(s);

    const z: @Vector(8, u8) = @splat('0');
    const nine: @Vector(8, u8) = @splat(9);

    var buf: [16]u8 = @splat('0');
    @memcpy(buf[16 - s.len ..], s);

    const hi: @Vector(8, u8) = buf[0..8].*;
    const lo: @Vector(8, u8) = buf[8..16].*;

    const dhi: @Vector(8, u8) = hi -% z;
    const dlo: @Vector(8, u8) = lo -% z;

    if (@reduce(.Or, dhi > nine) or @reduce(.Or, dlo > nine)) return null;

    const w1: @Vector(8, u16) = .{ 10, 1, 10, 1, 10, 1, 10, 1 };
    const phi: @Vector(8, u16) = @as(@Vector(8, u16), dhi) * w1;
    const plo: @Vector(8, u16) = @as(@Vector(8, u16), dlo) * w1;

    const w2: @Vector(4, u16) = .{ 100, 1, 100, 1 };
    const fhi = @Vector(4, u16){
        phi[0] + phi[1], phi[2] + phi[3], phi[4] + phi[5], phi[6] + phi[7],
    } * w2;
    const flo = @Vector(4, u16){
        plo[0] + plo[1], plo[2] + plo[3], plo[4] + plo[5], plo[6] + plo[7],
    } * w2;

    const hi_val: u64 = (@as(u64, fhi[0] + fhi[1]) * 10_000) + (fhi[2] + fhi[3]);
    const lo_val: u64 = (@as(u64, flo[0] + flo[1]) * 10_000) + (flo[2] + flo[3]);

    return hi_val * 100_000_000 + lo_val;
}

fn escapeMask(chunk: LaneVec(), escape_unicode: bool) LaneMask() {
    const ctrl: LaneVec() = @splat(@as(u8, 0x20));
    const dq: LaneVec() = @splat(@as(u8, '"'));
    const bs: LaneVec() = @splat(@as(u8, '\\'));
    const hi: LaneVec() = @splat(@as(u8, 0x7E));
    var bad = (chunk < ctrl) | (chunk == dq) | (chunk == bs);
    if (escape_unicode) bad = bad | (chunk > hi);
    return @bitCast(@intFromBool(bad));
}

const TokenTag = enum {
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

const Token = struct {
    tag: TokenTag,
    slice: []const u8,
    is_float: bool = false,
    has_escape: bool = false,
};

const Tokenizer = struct {
    input: []const u8,
    pos: usize,
    scanner: SpaceScanner,
    prev_escaped: u64,

    fn init(input: []const u8) Error!Tokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{
            .input = input,
            .pos = 0,
            .scanner = SpaceScanner.init(),
            .prev_escaped = 0,
        };
    }

    fn peek(self: *Tokenizer) ?u8 {
        self.pos = self.scanner.nextNonSpace(self.input, self.pos);
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    fn next(self: *Tokenizer) Error!?Token {
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

    fn scanString(self: *Tokenizer) Error!Token {
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

    fn scanNumber(self: *Tokenizer) Error!Token {
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

fn expectColon(tok: *Tokenizer) Error!void {
    tok.pos = tok.scanner.nextNonSpace(tok.input, tok.pos);
    if (tok.pos >= tok.input.len or tok.input[tok.pos] != ':') return error.UnexpectedToken;
    tok.pos += 1;
}

fn numberEndSimd(hay: []const u8, pos: usize) usize {
    const N = comptime laneN();
    const lo_splat: LaneVec() = @splat(@as(u8, '0'));
    const hi_splat: LaneVec() = @splat(@as(u8, '9'));
    var i = pos;

    while (i + N * 2 <= hay.len) {
        const chunk0: LaneVec() = hay[i..][0..N].*;
        const non0 = (chunk0 < lo_splat) | (chunk0 > hi_splat);
        const mask0 = @as(LaneMask(), @bitCast(@intFromBool(non0)));
        if (mask0 != 0) return i + @ctz(mask0);
        i += N;

        const chunk1: LaneVec() = hay[i..][0..N].*;
        const non1 = (chunk1 < lo_splat) | (chunk1 > hi_splat);
        const mask1 = @as(LaneMask(), @bitCast(@intFromBool(non1)));
        if (mask1 != 0) return i + @ctz(mask1);
        i += N;
    }

    while (i + N <= hay.len) {
        const chunk: LaneVec() = hay[i..][0..N].*;
        const non_digit = (chunk < lo_splat) | (chunk > hi_splat);
        const mask = @as(LaneMask(), @bitCast(@intFromBool(non_digit)));
        if (mask != 0) return i + @ctz(mask);
        i += N;
    }

    while (i < hay.len) : (i += 1) {
        switch (hay[i]) {
            '0'...'9' => {},
            else => return i,
        }
    }
    return i;
}

fn decodeString(raw: []const u8, out: []u8) Error![]u8 {
    assert(raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"');
    const inner = raw[1 .. raw.len - 1];
    var src: usize = 0;
    var dst: usize = 0;
    const N = comptime laneN();
    const bs_splat: LaneVec() = @splat(@as(u8, '\\'));
    const ct_splat: LaneVec() = @splat(@as(u8, 0x20));

    while (src < inner.len) {
        if (src + N <= inner.len) {
            const chunk: LaneVec() = inner[src..][0..N].*;
            const hit = (chunk == bs_splat) | (chunk < ct_splat);
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask == 0) {
                @memcpy(out[dst .. dst + N], inner[src .. src + N]);
                src += N;
                dst += N;
                continue;
            }
            const clean = @ctz(mask);
            @memcpy(out[dst .. dst + clean], inner[src .. src + clean]);
            src += clean;
            dst += clean;
        }

        if (src >= inner.len) break;

        if (inner[src] != '\\') {
            out[dst] = inner[src];
            src += 1;
            dst += 1;
            continue;
        }
        src += 1;
        if (src >= inner.len) return error.InvalidEscape;
        switch (inner[src]) {
            '"' => {
                out[dst] = '"';
                src += 1;
                dst += 1;
            },
            '\\' => {
                out[dst] = '\\';
                src += 1;
                dst += 1;
            },
            '/' => {
                out[dst] = '/';
                src += 1;
                dst += 1;
            },
            'b' => {
                out[dst] = '\x08';
                src += 1;
                dst += 1;
            },
            'f' => {
                out[dst] = '\x0C';
                src += 1;
                dst += 1;
            },
            'n' => {
                out[dst] = '\n';
                src += 1;
                dst += 1;
            },
            'r' => {
                out[dst] = '\r';
                src += 1;
                dst += 1;
            },
            't' => {
                out[dst] = '\t';
                src += 1;
                dst += 1;
            },
            'u' => {
                src += 1;
                if (src + 4 > inner.len) return error.InvalidEscape;
                const cp1 = parseHex4(inner[src .. src + 4]) catch return error.InvalidEscape;
                src += 4;
                var codepoint: u21 = @intCast(cp1);
                if (cp1 >= 0xD800 and cp1 <= 0xDBFF) {
                    if (src + 6 > inner.len) return error.InvalidUtf8;
                    if (inner[src] != '\\' or inner[src + 1] != 'u') return error.InvalidUtf8;
                    src += 2;
                    const cp2 = parseHex4(inner[src .. src + 4]) catch return error.InvalidEscape;
                    src += 4;
                    if (cp2 < 0xDC00 or cp2 > 0xDFFF) return error.InvalidUtf8;
                    codepoint = 0x10000 +
                        (@as(u21, cp1 - 0xD800) << 10) |
                        @as(u21, cp2 - 0xDC00);
                }
                dst += std.unicode.utf8Encode(codepoint, out[dst..]) catch return error.InvalidUtf8;
            },
            else => return error.InvalidEscape,
        }
    }
    return out[0..dst];
}

fn parseHex4(s: []const u8) Error!u16 {
    assert(s.len == 4);
    var v: u16 = 0;
    for (s) |c| {
        v = (v << 4) | switch (c) {
            '0'...'9' => @as(u16, c - '0'),
            'a'...'f' => @as(u16, c - 'a' + 10),
            'A'...'F' => @as(u16, c - 'A' + 10),
            else => return error.InvalidEscape,
        };
    }
    return v;
}

fn allocDecodeString(allocator: Allocator, raw: []const u8) Error![]u8 {
    return allocDecodeStringHinted(allocator, raw, true);
}

fn allocDecodeStringHinted(allocator: Allocator, raw: []const u8, has_escape: bool) Error![]u8 {
    assert(raw.len >= 2);
    if (!has_escape) {
        const inner = raw[1 .. raw.len - 1];
        const buf = try allocator.alloc(u8, inner.len);
        @memcpy(buf, inner);
        return buf;
    }
    const buf = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(buf);
    const decoded = try decodeString(raw, buf);
    const n = decoded.len;
    if (n < buf.len) {
        if (allocator.resize(buf, n)) return buf[0..n];
        const tight = try allocator.alloc(u8, n);
        @memcpy(tight, decoded);
        allocator.free(buf);
        return tight;
    }
    return buf;
}

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try Tokenizer.init(input);
    const v = try parseValueInner(allocator, &tok, 0);
    tok.pos = tok.scanner.nextNonSpace(input, tok.pos);
    if (tok.pos < input.len) return error.UnexpectedToken;
    return v;
}

fn parseValueInner(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    return switch (t.tag) {
        .null_lit => .null,
        .true_lit => .{ .bool = true },
        .false_lit => .{ .bool = false },
        .number => parseNumber(t),
        .string => .{ .string = try allocDecodeStringHinted(allocator, t.slice, t.has_escape) },
        .array_begin => try parseArray(allocator, tok, depth + 1),
        .object_begin => try parseObject(allocator, tok, depth + 1),
        else => error.UnexpectedToken,
    };
}

fn parseNumber(t: Token) Error!Value {
    const raw = t.slice;
    if (!t.is_float) {
        if (raw.len > 0 and raw[0] != '-') {
            if (simdParseU64Decimal(raw)) |u| {
                if (u <= @as(u64, std.math.maxInt(i64)))
                    return .{ .integer = @intCast(u) };
            }
        } else if (raw.len > 1) {
            if (simdParseU64Decimal(raw[1..])) |u| {
                if (u > 0 and u <= @as(u64, @intCast(std.math.maxInt(i64))) + 1)
                    return .{ .integer = -@as(i64, @intCast(u)) };
            }
        }
        if (std.fmt.parseInt(i64, raw, 10)) |i| return .{ .integer = i } else |_| {}
        return .{ .number_string = raw };
    }
    if (std.fmt.parseFloat(f64, raw)) |f| return .{ .float = f } else |_| {}
    return .{ .number_string = raw };
}

fn parseArray(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    var arr = Array.empty;
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }
    tok.pos = tok.scanner.nextNonSpace(tok.input, tok.pos);
    if (tok.pos < tok.input.len and tok.input[tok.pos] == ']') {
        tok.pos += 1;
        return .{ .array = arr };
    }
    try arr.ensureTotalCapacity(allocator, 8);
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag == .array_end) return .{ .array = arr };
            if (c.tag != .comma) return error.UnexpectedToken;
        }
        try arr.append(allocator, try parseValueInner(allocator, tok, depth));
    }
    return error.InputTooLarge;
}

fn parseObject(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    var obj = ObjectMap{};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        obj.deinit(allocator);
    }
    tok.pos = tok.scanner.nextNonSpace(tok.input, tok.pos);
    if (tok.pos < tok.input.len and tok.input[tok.pos] == '}') {
        tok.pos += 1;
        return .{ .object = obj };
    }
    try obj.ensureTotalCapacity(allocator, 8);
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag == .object_end) return .{ .object = obj };
            if (c.tag != .comma) return error.UnexpectedToken;
        }
        const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (kt.tag != .string) return error.UnexpectedToken;
        const key = try allocDecodeStringHinted(allocator, kt.slice, kt.has_escape);
        errdefer allocator.free(key);
        try expectColon(tok);
        const v = try parseValueInner(allocator, tok, depth);
        const gop = try obj.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            gop.value_ptr.deinit(allocator);
        }
        gop.value_ptr.* = v;
    }
    return error.InputTooLarge;
}

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try Tokenizer.init(input);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    tok.pos = tok.scanner.nextNonSpace(input, tok.pos);
    if (tok.pos < input.len) return error.UnexpectedToken;
    return v;
}

pub fn parse(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    return parseFromSlice(T, allocator, input, opts);
}

pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
}

fn parseTyped(comptime T: type, allocator: Allocator, tok: *Tokenizer, opts: ParseOptions, depth: u32) Error!T {
    if (depth > opts.max_depth) return error.MaxDepthExceeded;
    switch (@typeInfo(T)) {
        .bool => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            return switch (t.tag) {
                .true_lit => true,
                .false_lit => false,
                else => error.TypeMismatch,
            };
        },
        .int => |int| {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .number) return error.TypeMismatch;
            if (!t.is_float) {
                if (t.slice.len > 0 and t.slice[0] != '-') {
                    if (simdParseU64Decimal(t.slice)) |u| {
                        return std.math.cast(T, u) orelse error.Overflow;
                    }
                } else if (t.slice.len > 1) {
                    if (simdParseU64Decimal(t.slice[1..])) |u| {
                        if (int.signedness == .unsigned) return error.Overflow;
                        const sv = -@as(i64, @intCast(u));
                        return std.math.cast(T, sv) orelse error.Overflow;
                    }
                }
            }
            const i = std.fmt.parseInt(i64, t.slice, 10) catch return error.InvalidNumber;
            if (int.signedness == .unsigned and i < 0) return error.Overflow;
            return std.math.cast(T, i) orelse error.Overflow;
        },
        .float => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .number) return error.TypeMismatch;
            return std.fmt.parseFloat(T, t.slice) catch error.InvalidNumber;
        },
        .optional => |opt| {
            if ((tok.peek() orelse return error.UnexpectedEndOfInput) == 'n') {
                _ = try tok.next();
                return null;
            }
            return try parseTyped(opt.child, allocator, tok, opts, depth);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                if (t.tag != .string) return error.TypeMismatch;
                return allocDecodeStringHinted(allocator, t.slice, t.has_escape);
            }
            if (ptr.size == .slice) return parseTypedSlice(ptr.child, allocator, tok, opts, depth);
            @compileError("panthera: unsupported pointer type " ++ @typeName(T));
        },
        .array => |arr| {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .array_begin) return error.TypeMismatch;
            var result: T = undefined;
            for (0..arr.len) |i| {
                if (i > 0) {
                    const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (c.tag != .comma) return error.UnexpectedToken;
                }
                result[i] = try parseTyped(arr.child, allocator, tok, opts, depth + 1);
            }
            const cl = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (cl.tag != .array_end) return error.UnexpectedToken;
            return result;
        },
        .@"struct" => |st| return parseTypedStruct(T, st, allocator, tok, opts, depth),
        .@"union" => return parseTypedUnion(T, allocator, tok, opts, depth),
        .@"enum" => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .string) return error.TypeMismatch;
            var buf: [MAX_FIELD_NAME]u8 = undefined;
            return std.meta.stringToEnum(T, try decodeString(t.slice, &buf)) orelse error.TypeMismatch;
        },
        else => @compileError("panthera: unsupported type " ++ @typeName(T)),
    }
}

fn parseTypedSlice(comptime Child: type, allocator: Allocator, tok: *Tokenizer, opts: ParseOptions, depth: u32) Error![]Child {
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (t.tag != .array_begin) return error.TypeMismatch;
    var list = std.ArrayListUnmanaged(Child){};
    errdefer {
        for (list.items) |*i| freeTyped(Child, allocator, i.*);
        list.deinit(allocator);
    }
    try list.ensureTotalCapacity(allocator, 8);
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        if (n == 0) {
            const p = tok.peek() orelse return error.UnexpectedEndOfInput;
            if (p == ']') {
                tok.pos += 1;
                break;
            }
        } else {
            const sep = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (sep.tag == .array_end) break;
            if (sep.tag != .comma) return error.UnexpectedToken;
        }
        try list.append(allocator, try parseTyped(Child, allocator, tok, opts, depth + 1));
    }
    return list.toOwnedSlice(allocator);
}

fn fnv1aHash(s: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (s) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

fn comptimeFieldHash(comptime name: []const u8) u64 {
    var h: u64 = 14695981039346656037;
    for (name) |c| {
        h ^= c;
        h *%= 1099511628211;
    }
    return h;
}

fn fieldIndexHash(comptime fields: []const std.builtin.Type.StructField, key: []const u8) ?usize {
    const h = fnv1aHash(key);
    inline for (fields, 0..) |field, i| {
        if (comptimeFieldHash(field.name) == h and std.mem.eql(u8, key, field.name)) return i;
    }
    return null;
}

fn parseTypedStruct(
    comptime T: type,
    comptime st: std.builtin.Type.Struct,
    allocator: Allocator,
    tok: *Tokenizer,
    opts: ParseOptions,
    depth: u32,
) Error!T {
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (t.tag != .object_begin) return error.TypeMismatch;
    var result: T = undefined;
    var filled = [_]bool{false} ** st.fields.len;
    var kbuf: [MAX_FIELD_NAME]u8 = undefined;
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        if (n == 0) {
            const p = tok.peek() orelse return error.UnexpectedEndOfInput;
            if (p == '}') {
                tok.pos += 1;
                break;
            }
        } else {
            const sep = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (sep.tag == .object_end) break;
            if (sep.tag != .comma) return error.UnexpectedToken;
        }
        const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (kt.tag != .string) return error.UnexpectedToken;
        const key = if (!kt.has_escape)
            kt.slice[1 .. kt.slice.len - 1]
        else
            try decodeString(kt.slice, &kbuf);
        try expectColon(tok);
        const fi = fieldIndexHash(st.fields, key);
        if (fi) |idx| {
            if (filled[idx] and opts.duplicate_field_behavior == .reject)
                return error.DuplicateField;
            inline for (st.fields, 0..) |field, i| {
                if (i == idx) {
                    @field(result, field.name) = try parseTyped(field.type, allocator, tok, opts, depth + 1);
                    filled[idx] = true;
                }
            }
        } else {
            if (opts.reject_unknown_fields) return error.UnknownField;
            try skipValue(tok, depth + 1);
        }
    }
    inline for (st.fields, 0..) |field, fi| {
        if (!filled[fi]) {
            if (field.default_value_ptr) |dvp| {
                @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(dvp))).*;
            } else if (opts.require_all_fields) {
                return error.MissingField;
            } else if (@typeInfo(field.type) == .optional) {
                @field(result, field.name) = null;
            } else {
                return error.MissingField;
            }
        }
    }
    return result;
}

fn parseTypedUnion(comptime T: type, allocator: Allocator, tok: *Tokenizer, opts: ParseOptions, depth: u32) Error!T {
    const ot = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (ot.tag != .object_begin) return error.TypeMismatch;
    const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (kt.tag != .string) return error.UnexpectedToken;
    var kbuf: [256]u8 = undefined;
    const key = try decodeString(kt.slice, &kbuf);
    const colon = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (colon.tag != .colon) return error.UnexpectedToken;
    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            const v = try parseTyped(field.type, allocator, tok, opts, depth + 1);
            const cl = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (cl.tag != .object_end) return error.UnexpectedToken;
            return @unionInit(T, field.name, v);
        }
    }
    return error.UnknownField;
}

fn skipValue(tok: *Tokenizer, depth: u32) Error!void {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;

    const SkipFrame = struct { is_array: bool, first: bool };
    var stack: [MAX_DEPTH]SkipFrame = undefined;
    var sp: u32 = 0;

    const first_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    switch (first_tok.tag) {
        .null_lit, .true_lit, .false_lit, .number, .string => {
            if (sp == 0) return;
        },
        .array_begin => {
            stack[sp] = .{ .is_array = true, .first = true };
            sp += 1;
        },
        .object_begin => {
            stack[sp] = .{ .is_array = false, .first = true };
            sp += 1;
        },
        .colon, .comma, .object_end, .array_end => return error.UnexpectedToken,
    }

    while (sp > 0) {
        const frame = &stack[sp - 1];
        const p = tok.peek() orelse return error.UnexpectedEndOfInput;

        if (frame.is_array) {
            if (p == ']') {
                tok.pos += 1;
                sp -= 1;
                continue;
            }
        } else {
            if (p == '}') {
                tok.pos += 1;
                sp -= 1;
                continue;
            }
        }

        if (!frame.first) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag != .comma) return error.UnexpectedToken;
        }
        frame.first = false;

        if (!frame.is_array) {
            _ = try tok.next();
            const col = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (col.tag != .colon) return error.UnexpectedToken;
        }

        const vt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        switch (vt.tag) {
            .null_lit, .true_lit, .false_lit, .number, .string => {},
            .array_begin => {
                if (sp >= MAX_DEPTH) return error.MaxDepthExceeded;
                stack[sp] = .{ .is_array = true, .first = true };
                sp += 1;
            },
            .object_begin => {
                if (sp >= MAX_DEPTH) return error.MaxDepthExceeded;
                stack[sp] = .{ .is_array = false, .first = true };
                sp += 1;
            },
            .colon, .comma, .object_end, .array_end => return error.UnexpectedToken,
        }
    }
}

fn freeTyped(comptime T: type, allocator: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice) {
            if (ptr.child != u8) for (value) |item| freeTyped(ptr.child, allocator, item);
            allocator.free(value);
        },
        .optional => if (value) |v| freeTyped(@typeInfo(T).optional.child, allocator, v),
        .@"struct" => |st| inline for (st.fields) |f| freeTyped(f.type, allocator, @field(value, f.name)),
        .array => |arr| for (value) |item| freeTyped(arr.child, allocator, item),
        else => {},
    }
}

pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var s = Stringifier(*std.Io.Writer){ .writer = writer, .opts = opts, .depth = 0 };
    try s.write(value);
}

fn Stringifier(comptime Writer: type) type {
    return struct {
        writer: Writer,
        opts: StringifyOptions,
        depth: u32,

        const Self = @This();

        const ESC_TABLE: [256]u8 = blk: {
            var t = [_]u8{0} ** 256;
            t['"'] = '"';
            t['\\'] = '\\';
            t['\n'] = 'n';
            t['\r'] = 'r';
            t['\t'] = 't';
            t['\x08'] = 'b';
            t['\x0C'] = 'f';
            var i: usize = 0;
            while (i < 0x20) : (i += 1) {
                if (t[i] == 0) t[i] = 0xFF;
            }
            break :blk t;
        };

        fn write(self: *Self, value: anytype) !void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .null => try self.writer.writeAll("null"),
                .bool => try self.writer.writeAll(if (value) "true" else "false"),
                .int, .comptime_int => try self.writeInt(@as(i64, @intCast(value))),
                .float, .comptime_float => try self.writeFloat(@as(f64, @floatCast(value))),
                .optional => if (value) |v| try self.write(v) else try self.writer.writeAll("null"),
                .@"enum" => {
                    try self.writer.writeByte('"');
                    try self.writeEscaped(@tagName(value));
                    try self.writer.writeByte('"');
                },
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8) {
                        try self.writer.writeByte('"');
                        try self.writeEscaped(value);
                        try self.writer.writeByte('"');
                    } else try self.writeArray(value),
                    .one => try self.write(value.*),
                    else => @compileError("panthera stringify: unsupported pointer"),
                },
                .array => |arr| if (arr.child == u8) {
                    try self.writer.writeByte('"');
                    try self.writeEscaped(&value);
                    try self.writer.writeByte('"');
                } else try self.writeArray(&value),
                .@"struct" => |st| {
                    const pretty = self.opts.whitespace != null;
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    var first = true;
                    inline for (st.fields) |field| {
                        const fv = @field(value, field.name);
                        if (!self.opts.emit_null_optional_fields and
                            @typeInfo(field.type) == .optional and fv == null) continue;
                        if (!first) try self.writer.writeByte(',');
                        first = false;
                        if (pretty) {
                            try self.indentPretty();
                            try self.writer.writeAll("\"" ++ field.name ++ "\": ");
                        } else {
                            try self.writer.writeAll("\"" ++ field.name ++ "\":");
                        }
                        try self.write(fv);
                    }
                    self.depth -= 1;
                    if (!first and pretty) try self.indentPretty();
                    try self.writer.writeByte('}');
                },
                .@"union" => |un| {
                    if (T == Value) {
                        try self.writeValue(value);
                        return;
                    }
                    if (un.tag_type == null) @compileError("panthera: bare union not supported");
                    const pretty = self.opts.whitespace != null;
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    if (pretty) try self.indentPretty();
                    try self.writer.writeByte('"');
                    try self.writeEscaped(@tagName(value));
                    if (pretty) try self.writer.writeAll("\": ") else try self.writer.writeAll("\":");
                    switch (value) {
                        inline else => |pl| try self.write(pl),
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.writer.writeByte('}');
                },
                else => @compileError("panthera stringify: unsupported type " ++ @typeName(T)),
            }
        }

        fn writeInt(self: *Self, v: i64) !void {
            var buf: [32]u8 = undefined;
            var i: usize = 32;
            const neg = v < 0;
            var n: u64 = @bitCast(if (neg) -v else v);
            while (n > 0) {
                i -= 1;
                buf[i] = @as(u8, @intCast(n % 10)) + '0';
                n /= 10;
            }
            if (i == 32) {
                buf[31] = '0';
                i = 31;
            }
            if (neg) {
                i -= 1;
                buf[i] = '-';
            }
            try self.writer.writeAll(buf[i..32]);
        }

        fn writeFloat(self: *Self, v: f64) !void {
            var buf: [64]u8 = undefined;
            try self.writer.writeAll(std.fmt.bufPrint(&buf, "{}", .{v}) catch unreachable);
        }

        fn writeValue(self: *Self, v: Value) !void {
            const pretty = self.opts.whitespace != null;
            switch (v) {
                .null => try self.writer.writeAll("null"),
                .bool => |b| try self.writer.writeAll(if (b) "true" else "false"),
                .integer => |i| try self.writeInt(i),
                .float => |f| try self.writeFloat(f),
                .number_string => |s| try self.writer.writeAll(s),
                .string => |s| {
                    try self.writer.writeByte('"');
                    try self.writeEscaped(s);
                    try self.writer.writeByte('"');
                },
                .array => |a| {
                    if (a.items.len == 0) {
                        try self.writer.writeAll("[]");
                        return;
                    }
                    try self.writer.writeByte('[');
                    self.depth += 1;
                    try self.writeValue(a.items[0]);
                    for (a.items[1..]) |item| {
                        try self.writer.writeByte(',');
                        if (pretty) try self.indentPretty();
                        try self.writeValue(item);
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.writer.writeByte(']');
                },
                .object => |o| {
                    if (o.count() == 0) {
                        try self.writer.writeAll("{}");
                        return;
                    }
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    var it = o.iterator();
                    var first_entry = true;
                    while (it.next()) |entry| {
                        if (!first_entry) try self.writer.writeByte(',');
                        first_entry = false;
                        if (pretty) try self.indentPretty();
                        try self.writer.writeByte('"');
                        try self.writeEscaped(entry.key_ptr.*);
                        if (pretty) try self.writer.writeAll("\": ") else try self.writer.writeAll("\":");
                        try self.writeValue(entry.value_ptr.*);
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.writer.writeByte('}');
                },
            }
        }

        fn writeArray(self: *Self, slice: anytype) !void {
            if (slice.len == 0) {
                try self.writer.writeAll("[]");
                return;
            }
            const pretty = self.opts.whitespace != null;
            try self.writer.writeByte('[');
            self.depth += 1;
            try self.write(slice[0]);
            for (slice[1..]) |item| {
                try self.writer.writeByte(',');
                if (pretty) try self.indentPretty();
                try self.write(item);
            }
            self.depth -= 1;
            if (pretty) try self.indentPretty();
            try self.writer.writeByte(']');
        }

        fn indentPretty(self: *Self) !void {
            const sp = self.opts.whitespace.?;
            try self.writer.writeByte('\n');
            const total: usize = @as(usize, self.depth) * @as(usize, sp);
            const spaces = " " ** (MAX_DEPTH * 8);
            try self.writer.writeAll(spaces[0..@min(total, spaces.len)]);
        }

        fn writeEscaped(self: *Self, s: []const u8) !void {
            const N = comptime laneN();
            const ctrl_splat: LaneVec() = @splat(@as(u8, 0x20));
            const dq_splat: LaneVec() = @splat(@as(u8, '"'));
            const bs_splat: LaneVec() = @splat(@as(u8, '\\'));
            const hi_splat: LaneVec() = @splat(@as(u8, 0x7E));
            const escape_unicode = self.opts.escape_unicode;
            var pos: usize = 0;

            while (pos + N * 2 <= s.len) {
                const chunk0: LaneVec() = s[pos..][0..N].*;
                var bad0 = (chunk0 < ctrl_splat) | (chunk0 == dq_splat) | (chunk0 == bs_splat);
                if (escape_unicode) bad0 = bad0 | (chunk0 > hi_splat);
                const mask0 = @as(LaneMask(), @bitCast(@intFromBool(bad0)));
                if (mask0 == 0) {
                    const chunk1: LaneVec() = s[pos + N ..][0..N].*;
                    var bad1 = (chunk1 < ctrl_splat) | (chunk1 == dq_splat) | (chunk1 == bs_splat);
                    if (escape_unicode) bad1 = bad1 | (chunk1 > hi_splat);
                    const mask1 = @as(LaneMask(), @bitCast(@intFromBool(bad1)));
                    if (mask1 == 0) {
                        try self.writer.writeAll(s[pos .. pos + N * 2]);
                        pos += N * 2;
                        continue;
                    }
                    try self.writer.writeAll(s[pos .. pos + N]);
                    pos += N;
                    const hit: usize = @ctz(mask1);
                    if (hit > 0) try self.writer.writeAll(s[pos .. pos + hit]);
                    try self.writeOneByte(s[pos + hit]);
                    pos += hit + 1;
                } else {
                    const hit: usize = @ctz(mask0);
                    if (hit > 0) try self.writer.writeAll(s[pos .. pos + hit]);
                    try self.writeOneByte(s[pos + hit]);
                    pos += hit + 1;
                }
            }

            while (pos + N <= s.len) {
                const chunk: LaneVec() = s[pos..][0..N].*;
                var bad = (chunk < ctrl_splat) | (chunk == dq_splat) | (chunk == bs_splat);
                if (escape_unicode) bad = bad | (chunk > hi_splat);
                const mask = @as(LaneMask(), @bitCast(@intFromBool(bad)));
                if (mask == 0) {
                    try self.writer.writeAll(s[pos .. pos + N]);
                    pos += N;
                } else {
                    const hit: usize = @ctz(mask);
                    if (hit > 0) try self.writer.writeAll(s[pos .. pos + hit]);
                    try self.writeOneByte(s[pos + hit]);
                    pos += hit + 1;
                }
            }

            if (pos < s.len) {
                var pad: [16]u8 = @splat(' ');
                const rem = s.len - pos;
                @memcpy(pad[0..rem], s[pos..]);
                const pchunk: LaneVec() = pad[0..N].*;
                var pbad = (pchunk < ctrl_splat) | (pchunk == dq_splat) | (pchunk == bs_splat);
                if (escape_unicode) pbad = pbad | (pchunk > hi_splat);
                const pmask = @as(LaneMask(), @bitCast(@intFromBool(pbad)));
                if (pmask == 0) {
                    try self.writer.writeAll(s[pos..]);
                } else {
                    const hit: usize = @ctz(pmask);
                    if (hit > 0) try self.writer.writeAll(s[pos .. pos + hit]);
                    try self.writeOneByte(s[pos + hit]);
                    pos += hit + 1;
                    while (pos < s.len) : (pos += 1) {
                        const b = s[pos];
                        const e = ESC_TABLE[b];
                        if (e == 0 and !(escape_unicode and b > 0x7E)) {
                            try self.writer.writeByte(b);
                        } else {
                            try self.writeOneByte(b);
                        }
                    }
                }
            }
        }

        fn writeOneByte(self: *Self, b: u8) !void {
            const e = ESC_TABLE[b];
            if (e != 0 and e != 0xFF) {
                const seq = [2]u8{ '\\', e };
                try self.writer.writeAll(&seq);
            } else {
                const hex = "0123456789ABCDEF";
                const esc = [6]u8{
                    '\\',        'u',          '0', '0',
                    hex[b >> 4], hex[b & 0xF],
                };
                try self.writer.writeAll(&esc);
            }
        }
    };
}

test "skipWhitespace: all" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 6), sc.nextNonSpace("   \t\n\r", 0));
}
test "skipWhitespace: mixed" {
    var sc = SpaceScanner.init();
    try std.testing.expectEqual(@as(usize, 2), sc.nextNonSpace("  hello", 0));
}
test "tokenizer: literals" {
    var tok = try Tokenizer.init("true false null");
    try std.testing.expectEqual(TokenTag.true_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.false_lit, ((try tok.next()).?).tag);
    try std.testing.expectEqual(TokenTag.null_lit, ((try tok.next()).?).tag);
    try std.testing.expect((try tok.next()) == null);
}
test "tokenizer: string escape" {
    var tok = try Tokenizer.init("\"hello\\nworld\"");
    const t = (try tok.next()).?;
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("hello\nworld", try decodeString(t.slice, &buf));
}
test "tokenizer: numbers" {
    var tok = try Tokenizer.init("-42 3.14e2");
    try std.testing.expectEqualStrings("-42", ((try tok.next()).?).slice);
    try std.testing.expectEqualStrings("3.14e2", ((try tok.next()).?).slice);
}
test "parseValue: object" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"a\":1,\"b\":true,\"c\":null}");
    try std.testing.expectEqual(@as(i64, 1), (v.object.get("a") orelse return error.TestFailed).integer);
    try std.testing.expect((v.object.get("b") orelse return error.TestFailed).bool);
    try std.testing.expect((v.object.get("c") orelse return error.TestFailed) == .null);
}
test "parseValue: nested array" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "[[1,2],[3,4]]");
    try std.testing.expectEqual(@as(i64, 1), v.array.items[0].array.items[0].integer);
}
test "parseFromSlice: struct" {
    const S = struct { name: []const u8, count: u32, ratio: f32, active: bool };
    const r = try parseFromSlice(S, std.testing.allocator,
        \\{"name":"test","count":7,"ratio":0.5,"active":true}
    , .{});
    defer parseFree(S, std.testing.allocator, r);
    try std.testing.expectEqualStrings("test", r.name);
    try std.testing.expectEqual(@as(u32, 7), r.count);
    try std.testing.expect(r.active);
}
test "stringify: roundtrip" {
    const S = struct { x: i32, y: f64, z: bool };
    const val = S{ .x = -3, .y = 1.5, .z = false };
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(val, .{}, &w);
    const back = try parseFromSlice(S, std.testing.allocator, w.buffered(), .{});
    defer parseFree(S, std.testing.allocator, back);
    try std.testing.expectEqual(val.x, back.x);
    try std.testing.expectEqual(val.z, back.z);
}
test "stringify: escaping" {
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify("hello\nworld\t\"!", .{}, &w);
    try std.testing.expectEqualStrings("\"hello\\nworld\\t\\\"!\"", w.buffered());
}
test "stringify: Value roundtrip" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const v = try parseValue(arena.allocator(), "{\"foo\":[1,false,null]}");
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try stringify(v, .{}, &w);
    try std.testing.expect((try parseValue(arena.allocator(), w.buffered())) == .object);
}
test "error: max depth" {
    var buf: [MAX_DEPTH * 2 + 8]u8 = undefined;
    var i: usize = 0;
    while (i < MAX_DEPTH + 2) : (i += 1) buf[i] = '[';
    buf[i] = '1';
    i += 1;
    var j: usize = 0;
    while (j < MAX_DEPTH + 2) : (j += 1) {
        buf[i] = ']';
        i += 1;
    }
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.MaxDepthExceeded, parseValue(arena.allocator(), buf[0..i]));
}
test "error: invalid escape" {
    var tok = try Tokenizer.init("\"\\q\"");
    try std.testing.expectError(error.InvalidEscape, tok.next());
}
test "error: trailing content" {
    var arena = ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.UnexpectedToken, parseValue(arena.allocator(), "{}garbage"));
}
test "simd: integer parse" {
    try std.testing.expectEqual(@as(?u64, 12345), simdParseU64Decimal("12345"));
    try std.testing.expectEqual(@as(?u64, 0), simdParseU64Decimal("0"));
    try std.testing.expectEqual(@as(?u64, null), simdParseU64Decimal("123x5"));
    try std.testing.expectEqual(@as(?u64, 9999999999999999), simdParseU64Decimal("9999999999999999"));
}
