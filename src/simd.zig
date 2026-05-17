const std = @import("std");
const builtin = @import("builtin");

pub const SimdWidth = enum { scalar, sse2, avx2, neon };

pub fn detectSimd() SimdWidth {
    const arch = builtin.cpu.arch;
    if (arch == .x86_64) {
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .avx2)) return .avx2;
        if (std.Target.x86.featureSetHas(builtin.cpu.features, .sse2)) return .sse2;
        return .scalar;
    }
    if (arch == .aarch64) return .neon;
    return .scalar;
}

pub const SIMD_WIDTH: SimdWidth = detectSimd();

pub fn laneN() comptime_int {
    return switch (SIMD_WIDTH) {
        .avx2 => 32,
        .sse2, .neon => 16,
        .scalar => 8,
    };
}

pub fn LaneMask() type {
    return switch (SIMD_WIDTH) {
        .avx2 => u32,
        .sse2, .neon => u16,
        .scalar => u8,
    };
}

pub fn LaneVec() type {
    return @Vector(laneN(), u8);
}

pub fn getStringBits(block: *const [64]u8, prev_escaped: *u64) u64 {
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

pub const SpaceScanner = struct {
    bitmap: u64,
    base: usize,

    pub fn init() SpaceScanner {
        return .{ .bitmap = 0, .base = std.math.maxInt(usize) };
    }

    pub fn nonSpaceBits(block: *const [64]u8) u64 {
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

    pub fn nextNonSpace(self: *SpaceScanner, input: []const u8, start: usize) usize {
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

pub const SPACE_TABLE: [256]u8 = blk: {
    var t = [_]u8{0} ** 256;
    t[' '] = 1;
    t['\t'] = 1;
    t['\n'] = 1;
    t['\r'] = 1;
    break :blk t;
};

pub fn isSpace(c: u8) bool {
    return SPACE_TABLE[c] != 0;
}

pub fn swarParseU64Decimal(s: []const u8) ?u64 {
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

pub inline fn pack2(d: u64) u64 {
    const lo = d & 0x00FF_00FF_00FF_00FF;
    const hi = (d >> 8) & 0x00FF_00FF_00FF_00FF;
    return lo + hi * 10;
}

pub inline fn pack4(d: u64) u64 {
    const lo = d & 0x0000_FFFF_0000_FFFF;
    const hi = (d >> 16) & 0x0000_FFFF_0000_FFFF;
    return lo + hi * 100;
}

pub inline fn pack8(d: u64) u64 {
    const lo = d & 0x0000_0000_FFFF_FFFF;
    const hi = d >> 32;
    return lo + hi * 10_000;
}

/// Parse up to 16 decimal digits from `s` into a u64.
/// Returns null if `s` is empty, longer than 16 bytes, or contains a non-digit.
/// Uses SIMD when available, falls back to SWAR on scalar targets.
pub fn simdParseU64Decimal(s: []const u8) ?u64 {
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

pub fn escapeMask(chunk: LaneVec(), escape_unicode: bool) LaneMask() {
    const ctrl: LaneVec() = @splat(@as(u8, 0x20));
    const dq: LaneVec() = @splat(@as(u8, '"'));
    const bs: LaneVec() = @splat(@as(u8, '\\'));
    const hi: LaneVec() = @splat(@as(u8, 0x7E));
    var bad = (chunk < ctrl) | (chunk == dq) | (chunk == bs);
    if (escape_unicode) bad = bad | (chunk > hi);
    return @bitCast(@intFromBool(bad));
}

/// Return the index of the first non-digit byte in `hay` starting at `pos`.
pub fn numberEndSimd(hay: []const u8, pos: usize) usize {
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
