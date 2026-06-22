const std = @import("std");
const builtin = @import("builtin");

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

/// Find first occurrence of `byte` in `hay` starting at `pos`.
/// Returns null if not found. Uses SIMD lane compares.
pub fn findByteSimd(hay: []const u8, pos: usize, byte: u8) ?usize {
    const N = comptime laneN();
    const target: LaneVec() = @splat(byte);
    var i = pos;

    while (i + 64 <= hay.len) {
        const block: *const [64]u8 = hay[i..][0..64];
        const iters = 64 / N;
        var mask: u64 = 0;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const hit = chunk == target;
            const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            mask |= lm << @as(u6, @intCast(lane * N));
        }
        if (mask != 0) return i + @ctz(mask);
        i += 64;
    }

    while (i < hay.len) : (i += 1) {
        if (hay[i] == byte) return i;
    }
    return null;
}

/// Find first occurrence of `\n` in `hay` starting at `pos`.
pub fn findNewlineSimd(hay: []const u8, pos: usize) ?usize {
    return findByteSimd(hay, pos, '\n');
}

/// Scan `hay` starting at `pos` while bytes match the given set (up to 4 members).
/// Returns the index of the first non-matching byte (or hay.len if all match).
/// Uses SIMD lane compares for 64-byte blocks.
pub fn scanWhileInSet(hay: []const u8, pos: usize, comptime set: []const u8) usize {
    const N = comptime laneN();
    var i = pos;

    if (set.len == 1) {
        const t: LaneVec() = @splat(set[0]);
        while (i + 64 <= hay.len) {
            const block: *const [64]u8 = hay[i..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = chunk != t;
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) return i + @ctz(mask);
            i += 64;
        }
    } else if (set.len == 2) {
        const t0: LaneVec() = @splat(set[0]);
        const t1: LaneVec() = @splat(set[1]);
        while (i + 64 <= hay.len) {
            const block: *const [64]u8 = hay[i..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk != t0) & (chunk != t1);
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) return i + @ctz(mask);
            i += 64;
        }
    } else if (set.len == 3) {
        const t0: LaneVec() = @splat(set[0]);
        const t1: LaneVec() = @splat(set[1]);
        const t2: LaneVec() = @splat(set[2]);
        while (i + 64 <= hay.len) {
            const block: *const [64]u8 = hay[i..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk != t0) & (chunk != t1) & (chunk != t2);
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) return i + @ctz(mask);
            i += 64;
        }
    } else if (set.len == 4) {
        const t0: LaneVec() = @splat(set[0]);
        const t1: LaneVec() = @splat(set[1]);
        const t2: LaneVec() = @splat(set[2]);
        const t3: LaneVec() = @splat(set[3]);
        while (i + 64 <= hay.len) {
            const block: *const [64]u8 = hay[i..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk != t0) & (chunk != t1) & (chunk != t2) & (chunk != t3);
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) return i + @ctz(mask);
            i += 64;
        }
    } else {
        @compileError("scanWhileInSet supports up to 4 members");
    }

    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        const in_set = for (set) |b| {
            if (c == b) break true;
        } else false;
        if (!in_set) return i;
    }
    return i;
}

/// Scan `hay` starting at `pos` while bytes are in the given range [lo, hi].
/// Returns the index of the first non-matching byte (or hay.len if all match).
pub fn scanWhileInRange(hay: []const u8, pos: usize, lo: u8, hi: u8) usize {
    const N = comptime laneN();
    const lo_splat: LaneVec() = @splat(lo);
    const hi_splat: LaneVec() = @splat(hi);
    var i = pos;

    while (i + 64 <= hay.len) {
        const block: *const [64]u8 = hay[i..][0..64];
        const iters = 64 / N;
        var mask: u64 = 0;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const non = (chunk < lo_splat) | (chunk > hi_splat);
            const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(non)));
            mask |= lm << @as(u6, @intCast(lane * N));
        }
        if (mask != 0) return i + @ctz(mask);
        i += 64;
    }

    while (i < hay.len) : (i += 1) {
        const c = hay[i];
        if (c < lo or c > hi) return i;
    }
    return i;
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
