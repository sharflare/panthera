const std = @import("std");
const format = @import("format.zig");

pub fn writeFloat(writer: anytype, v: f64) !void {
    if (!std.math.isFinite(v)) {
        if (std.math.isNan(v)) {
            try writer.writeAll("nan");
            return;
        }
        if (v < 0) {
            try writer.writeAll("-inf");
        } else {
            try writer.writeAll("inf");
        }
        return;
    }

    const int_v = @trunc(v);
    if (v == int_v) {
        if (int_v >= @as(f64, @floatFromInt(std.math.minInt(i64))) and
            int_v <= @as(f64, @floatFromInt(std.math.maxInt(i64))))
        {
            return format.writeInt(writer, @intFromFloat(v));
        }
    }

    const bits: u64 = @bitCast(v);
    const is_negative = (bits >> 63) != 0;
    const biased_exp = @as(u32, @intCast((bits >> 52) & 0x7FF));
    const significand = bits & ((@as(u64, 1) << 52) - 1);

    if (biased_exp == 0 and significand == 0) {
        if (is_negative) {
            try writer.writeAll("-0");
        } else {
            try writer.writeByte('0');
        }
        return;
    }

    const dec = toDecimal(significand, @as(i32, @bitCast(biased_exp)), is_negative);
    try writeDecimal(writer, dec.significand, dec.exponent, dec.is_negative);
}

fn toDecimal(binary_significand: u64, binary_exponent: i32, is_negative_bool: bool) DecimalFp {
    const is_even = binary_significand % 2 == 0;
    var two_fc = binary_significand * 2;
    var bin_exp = binary_exponent;

    if (bin_exp != 0) {
        bin_exp += exponent_bias - significand_bits;

        if (two_fc == 0) {
            const minus_k = log10Pow2Delta(bin_exp);
            const beta = bin_exp + log2Pow10(-minus_k);
            const cache_entry = cache[@as(usize, @intCast(-minus_k - min_k_double))];

            var xi = leftEndpoint(cache_entry, beta);
            const zi = rightEndpoint(cache_entry, beta);

            if (!isShortInterval(bin_exp)) {
                xi += 1;
            }

            var dec_sig = divByPow10(1, zi);
            if (dec_sig * 10 >= xi) {
                var dec_exp = minus_k + 1;
                removeZeros(&dec_sig, &dec_exp);
                return .{ .significand = dec_sig, .exponent = dec_exp, .is_negative = is_negative_bool };
            }

            dec_sig = roundUpEndpoint(cache_entry, beta);
            if (dec_sig % 2 != 0 and
                bin_exp >= shorter_interval_tie_lower_threshold and
                bin_exp <= shorter_interval_tie_upper_threshold)
            {
                dec_sig -= 1;
            } else if (dec_sig < xi) {
                dec_sig += 1;
            }
            return .{ .significand = dec_sig, .exponent = minus_k, .is_negative = is_negative_bool };
        }

        two_fc |= (@as(u64, 1) << (significand_bits + 1));
    } else {
        bin_exp = min_exponent_double - significand_bits;
    }

    const minus_k = log10Pow2(bin_exp) - kappa_double;
    const cache_entry = cache[@as(usize, @intCast(-minus_k - min_k_double))];
    const beta = bin_exp + log2Pow10(-minus_k);

    const deltai = computeDelta(cache_entry, beta);
    const z_result = computeMul((two_fc | 1) << @as(u6, @intCast(beta)), cache_entry);

    const big_divisor: u64 = comptime computePower(kappa_double + 1, u64, 10);
    const small_divisor: u64 = comptime computePower(kappa_double, u64, 10);

    var dec_sig = divByPow10(kappa_double + 1, z_result.integer_part);
    var r = z_result.integer_part - big_divisor * dec_sig;

    {
        if (r < deltai) {
            if ((r | @intFromBool(!z_result.is_integer) | @intFromBool(is_even)) == 0) {
                dec_sig -= 1;
                r = big_divisor;
            }
        } else if (r > deltai) {} else {
            const x_result = computeParity(two_fc - 1, cache_entry, beta);
            if (!(x_result.parity or (x_result.is_integer and is_even))) {} else {
                var dec_exp = minus_k + kappa_double + 1;
                removeZeros(&dec_sig, &dec_exp);
                return .{ .significand = dec_sig, .exponent = dec_exp, .is_negative = is_negative_bool };
            }
        }
    }

    dec_sig *= 10;

    var dist = r - (deltai / 2) + (small_divisor / 2);
    const approx_y_parity = ((dist ^ (small_divisor / 2)) & 1) != 0;
    const divisible_by_small_divisor = checkDivPow10(kappa_double, &dist);

    dec_sig += dist;

    if (divisible_by_small_divisor) {
        const y_result = computeParity(two_fc, cache_entry, beta);
        if (y_result.parity != approx_y_parity) {
            dec_sig -= 1;
        } else {
            if ((dec_sig % 2) & @intFromBool(y_result.is_integer) != 0) {
                dec_sig -= 1;
            }
        }
    }

    return .{ .significand = dec_sig, .exponent = minus_k + kappa_double, .is_negative = is_negative_bool };
}

const DecimalFp = struct {
    significand: u64,
    exponent: i32,
    is_negative: bool,
};

const uint128 = struct { high: u64, low: u64 };

const significand_bits = 52;
const exponent_bias = -1023;
const min_exponent_double = -1022;
const min_k_double = -292;
const kappa_double = log10Pow2(64 - 52 - 2) - 1;

const shorter_interval_tie_lower_threshold = blk: {
    const e = significand_bits + 4;
    break :blk -log5Pow2Delta(e) - 2 - significand_bits;
};

const shorter_interval_tie_upper_threshold = blk: {
    const e = significand_bits + 2;
    break :blk -log5Pow2(e) - 2 - significand_bits;
};

fn isShortInterval(bin_exp: i32) bool {
    const lower: i32 = 2;
    const upper: i32 = comptime blk: {
        const n = count5Factors((@as(u64, 1) << (significand_bits + 2)) - 1) + 1;
        const pow = computePower(n, u64, 10);
        break :blk 2 + floorLog2(pow / 3);
    };
    return bin_exp >= lower and bin_exp <= upper;
}

fn floorLog2(n: u64) i32 {
    return @as(i32, @intCast(63 - @clz(n)));
}

fn log10Pow2(e: i32) i32 {
    return (e *% 315653) >> 20;
}

fn log2Pow10(e: i32) i32 {
    return (e *% 1741647) >> 19;
}

fn log10Pow2Delta(e: i32) i32 {
    return (e *% 631305 -% 261663) >> 21;
}

fn log5Pow2(e: i32) i32 {
    return (e *% 225799) >> 19;
}

fn log5Pow2Delta(e: i32) i32 {
    return (e *% 451597 -% 715764) >> 20;
}

fn umul128(x: u64, y: u64) uint128 {
    const a = @as(u32, @intCast(x >> 32));
    const b = @as(u32, @intCast(x & 0xFFFFFFFF));
    const c = @as(u32, @intCast(y >> 32));
    const d = @as(u32, @intCast(y & 0xFFFFFFFF));

    const ac = @as(u64, a) * c;
    const bc = @as(u64, b) * c;
    const ad = @as(u64, a) * d;
    const bd = @as(u64, b) * d;

    const intermediate = (bd >> 32) + @as(u32, @intCast(ad & 0xFFFFFFFF)) + @as(u32, @intCast(bc & 0xFFFFFFFF));
    const high = ac + (intermediate >> 32) + (ad >> 32) + (bc >> 32);
    const low = (intermediate << 32) + @as(u32, @intCast(bd & 0xFFFFFFFF));
    return .{ .high = high, .low = low };
}

fn umul128Upper(x: u64, y: u64) u64 {
    const a = @as(u32, @intCast(x >> 32));
    const b = @as(u32, @intCast(x & 0xFFFFFFFF));
    const c = @as(u32, @intCast(y >> 32));
    const d = @as(u32, @intCast(y & 0xFFFFFFFF));

    const ac = @as(u64, a) * c;
    const bc = @as(u64, b) * c;
    const ad = @as(u64, a) * d;
    const bd = @as(u64, b) * d;

    const intermediate = (bd >> 32) + @as(u32, @intCast(ad & 0xFFFFFFFF)) + @as(u32, @intCast(bc & 0xFFFFFFFF));
    return ac + (intermediate >> 32) + (ad >> 32) + (bc >> 32);
}

fn umul192Upper(x: u64, y: uint128) uint128 {
    var r = umul128(x, y.high);
    const upper = umul128Upper(x, y.low);
    r.high +%= upper;
    if (r.high < upper) {
        r.low +%= 0;
    }
    return r;
}

fn umul192Lower(x: u64, y: uint128) uint128 {
    const high = x *% y.high;
    var high_low = umul128(x, y.low);
    const result_high = high +% high_low.high;
    if (result_high < high) {
        high_low.low +%= 0;
    }
    return .{ .high = result_high, .low = high_low.low };
}

fn computeMul(u: u64, c: uint128) ComputeMulResult {
    const r = umul192Upper(u, c);
    return .{ .integer_part = r.high, .is_integer = r.low == 0 };
}

fn computeParity(two_f: u64, c: uint128, beta: i32) ComputeMulParityResult {
    const r = umul192Lower(two_f, c);
    const parity = ((r.high >> @as(u6, @intCast(64 - beta))) & 1) != 0;
    const is_integer = ((r.high << @as(u6, @intCast(beta))) | (r.low >> @as(u6, @intCast(64 - beta)))) == 0;
    return .{ .parity = parity, .is_integer = is_integer };
}

fn computeDelta(c: uint128, beta: i32) u64 {
    return c.high >> @as(u6, @intCast(64 - 1 - beta));
}

fn leftEndpoint(c: uint128, beta: i32) u64 {
    return (c.high - (c.high >> (significand_bits + 2))) >> @as(u6, @intCast(64 - significand_bits - 1 - beta));
}

fn rightEndpoint(c: uint128, beta: i32) u64 {
    return (c.high + (c.high >> (significand_bits + 1))) >> @as(u6, @intCast(64 - significand_bits - 1 - beta));
}

fn roundUpEndpoint(c: uint128, beta: i32) u64 {
    return ((c.high >> @as(u6, @intCast(64 - significand_bits - 2 - beta))) + 1) / 2;
}

fn divByPow10(comptime N: comptime_int, n: u64) u64 {
    return switch (N) {
        1 => umul128Upper(n, 1844674407370955162),
        3 => umul128Upper(n, 4722366482869645214) >> 8,
        else => n / comptime computePower(N, u64, 10),
    };
}

fn checkDivPow10(comptime N: comptime_int, n: *u64) bool {
    const magic_number: u32 = comptime switch (N) {
        1 => 6554,
        2 => 656,
        else => @compileError("unsupported N"),
    };
    const prod = @as(u32, @intCast(n.* * magic_number));
    const result = (prod & 0xFFFF) < magic_number;
    n.* = prod >> 16;
    return result;
}

fn computePower(comptime k: comptime_int, comptime T: type, a: T) T {
    var e = k;
    var p: T = 1;
    var base = a;
    while (e > 0) {
        if (e % 2 != 0) p *= base;
        e /= 2;
        base *= base;
    }
    return p;
}

fn count5Factors(n: u64) i32 {
    var x = n;
    var c: i32 = 0;
    while (x % 5 == 0) {
        x /= 5;
        c += 1;
    }
    return c;
}

fn removeZeros(significand: *u64, exponent: *i32) void {
    var r = std.math.rotr(u64, significand.* *% 28999941890838049, 8);
    var b = r < 184467440738;
    var s: u32 = @intFromBool(b);
    if (b) significand.* = r;

    r = std.math.rotr(u64, significand.* *% 182622766329724561, 4);
    b = r < 1844674407370956;
    s = s * 2 + @intFromBool(b);
    if (b) significand.* = r;

    r = std.math.rotr(u64, significand.* *% 10330176681277348905, 2);
    b = r < 184467440737095517;
    s = s * 2 + @intFromBool(b);
    if (b) significand.* = r;

    r = std.math.rotr(u64, significand.* *% 14757395258967641293, 1);
    b = r < 1844674407370955162;
    s = s * 2 + @intFromBool(b);
    if (b) significand.* = r;

    exponent.* += @as(i32, @intCast(s));
}

const ComputeMulResult = struct {
    integer_part: u64,
    is_integer: bool,
};

const ComputeMulParityResult = struct {
    parity: bool,
    is_integer: bool,
};

fn writeDecimal(writer: anytype, sig: u64, exp: i32, neg: bool) !void {
    var d: [32]u8 = undefined;
    var di: usize = d.len;
    var n = sig;
    while (n >= 100) {
        di -= 2;
        const pair = (n % 100) * 2;
        n /= 100;
        d[di] = format.DIGIT_TABLE[pair];
        d[di + 1] = format.DIGIT_TABLE[pair + 1];
    }
    if (n >= 10) {
        di -= 2;
        const pair = n * 2;
        d[di] = format.DIGIT_TABLE[pair];
        d[di + 1] = format.DIGIT_TABLE[pair + 1];
    } else if (n > 0) {
        di -= 1;
        d[di] = @as(u8, @intCast(n)) + '0';
    } else {
        di = d.len - 1;
        d[di] = '0';
    }
    const digits = d[di..];

    if (neg) try writer.writeByte('-');

    if (exp >= 0) {
        try writer.writeAll(digits);
        var i: usize = 0;
        while (i < @as(usize, @intCast(exp))) : (i += 1) {
            try writer.writeByte('0');
        }
    } else {
        const uns_exp = @as(usize, @intCast(-exp));
        if (uns_exp < digits.len) {
            const before_dot = digits.len - uns_exp;
            try writer.writeAll(digits[0..before_dot]);
            try writer.writeByte('.');
            try writer.writeAll(digits[before_dot..]);
        } else {
            try writer.writeByte('0');
            try writer.writeByte('.');
            var i: usize = 0;
            while (i < uns_exp - digits.len) : (i += 1) {
                try writer.writeByte('0');
            }
            try writer.writeAll(digits);
        }
    }
}

const cache: [619]uint128 = blk: {
    @setEvalBranchQuota(10000);
    break :blk .{
        uint128{ .high = 0xff77b1fcbebcdc4f, .low = 0x25e8e89c13bb0f7b },
        uint128{ .high = 0x9faacf3df73609b1, .low = 0x77b191618c54e9ad },
        uint128{ .high = 0xc795830d75038c1d, .low = 0xd59df5b9ef6a2418 },
        uint128{ .high = 0xf97ae3d0d2446f25, .low = 0x4b0573286b44ad1e },
        uint128{ .high = 0x9becce62836ac577, .low = 0x4ee367f9430aec33 },
        uint128{ .high = 0xc2e801fb244576d5, .low = 0x229c41f793cda740 },
        uint128{ .high = 0xf3a20279ed56d48a, .low = 0x6b43527578c11110 },
        uint128{ .high = 0x9845418c345644d6, .low = 0x830a13896b78aaaa },
        uint128{ .high = 0xbe5691ef416bd60c, .low = 0x23cc986bc656d554 },
        uint128{ .high = 0xedec366b11c6cb8f, .low = 0x2cbfbe86b7ec8aa9 },
        uint128{ .high = 0x94b3a202eb1c3f39, .low = 0x7bf7d71432f3d6aa },
        uint128{ .high = 0xb9e08a83a5e34f07, .low = 0xdaf5ccd93fb0cc54 },
        uint128{ .high = 0xe858ad248f5c22c9, .low = 0xd1b3400f8f9cff69 },
        uint128{ .high = 0x91376c36d99995be, .low = 0x23100809b9c21fa2 },
        uint128{ .high = 0xb58547448ffffb2d, .low = 0xabd40a0c2832a78b },
        uint128{ .high = 0xe2e69915b3fff9f9, .low = 0x16c90c8f323f516d },
        uint128{ .high = 0x8dd01fad907ffc3b, .low = 0xae3da7d97f6792e4 },
        uint128{ .high = 0xb1442798f49ffb4a, .low = 0x99cd11cfdf41779d },
        uint128{ .high = 0xdd95317f31c7fa1d, .low = 0x40405643d711d584 },
        uint128{ .high = 0x8a7d3eef7f1cfc52, .low = 0x482835ea666b2573 },
        uint128{ .high = 0xad1c8eab5ee43b66, .low = 0xda3243650005eed0 },
        uint128{ .high = 0xd863b256369d4a40, .low = 0x90bed43e40076a83 },
        uint128{ .high = 0x873e4f75e2224e68, .low = 0x5a7744a6e804a292 },
        uint128{ .high = 0xa90de3535aaae202, .low = 0x711515d0a205cb37 },
        uint128{ .high = 0xd3515c2831559a83, .low = 0x0d5a5b44ca873e04 },
        uint128{ .high = 0x8412d9991ed58091, .low = 0xe858790afe9486c3 },
        uint128{ .high = 0xa5178fff668ae0b6, .low = 0x626e974dbe39a873 },
        uint128{ .high = 0xce5d73ff402d98e3, .low = 0xfb0a3d212dc81290 },
        uint128{ .high = 0x80fa687f881c7f8e, .low = 0x7ce66634bc9d0b9a },
        uint128{ .high = 0xa139029f6a239f72, .low = 0x1c1fffc1ebc44e81 },
        uint128{ .high = 0xc987434744ac874e, .low = 0xa327ffb266b56221 },
        uint128{ .high = 0xfbe9141915d7a922, .low = 0x4bf1ff9f0062baa9 },
        uint128{ .high = 0x9d71ac8fada6c9b5, .low = 0x6f773fc3603db4aa },
        uint128{ .high = 0xc4ce17b399107c22, .low = 0xcb550fb4384d21d4 },
        uint128{ .high = 0xf6019da07f549b2b, .low = 0x7e2a53a146606a49 },
        uint128{ .high = 0x99c102844f94e0fb, .low = 0x2eda7444cbfc426e },
        uint128{ .high = 0xc0314325637a1939, .low = 0xfa911155fefb5309 },
        uint128{ .high = 0xf03d93eebc589f88, .low = 0x793555ab7eba27cb },
        uint128{ .high = 0x96267c7535b763b5, .low = 0x4bc1558b2f3458df },
        uint128{ .high = 0xbbb01b9283253ca2, .low = 0x9eb1aaedfb016f17 },
        uint128{ .high = 0xea9c227723ee8bcb, .low = 0x465e15a979c1cadd },
        uint128{ .high = 0x92a1958a7675175f, .low = 0x0bfacd89ec191eca },
        uint128{ .high = 0xb749faed14125d36, .low = 0xcef980ec671f667c },
        uint128{ .high = 0xe51c79a85916f484, .low = 0x82b7e12780e7401b },
        uint128{ .high = 0x8f31cc0937ae58d2, .low = 0xd1b2ecb8b0908811 },
        uint128{ .high = 0xb2fe3f0b8599ef07, .low = 0x861fa7e6dcb4aa16 },
        uint128{ .high = 0xdfbdcece67006ac9, .low = 0x67a791e093e1d49b },
        uint128{ .high = 0x8bd6a141006042bd, .low = 0xe0c8bb2c5c6d24e1 },
        uint128{ .high = 0xaecc49914078536d, .low = 0x58fae9f773886e19 },
        uint128{ .high = 0xda7f5bf590966848, .low = 0xaf39a475506a899f },
        uint128{ .high = 0x888f99797a5e012d, .low = 0x6d8406c952429604 },
        uint128{ .high = 0xaab37fd7d8f58178, .low = 0xc8e5087ba6d33b84 },
        uint128{ .high = 0xd5605fcdcf32e1d6, .low = 0xfb1e4a9a90880a65 },
        uint128{ .high = 0x855c3be0a17fcd26, .low = 0x5cf2eea09a550680 },
        uint128{ .high = 0xa6b34ad8c9dfc06f, .low = 0xf42faa48c0ea481f },
        uint128{ .high = 0xd0601d8efc57b08b, .low = 0xf13b94daf124da27 },
        uint128{ .high = 0x823c12795db6ce57, .low = 0x76c53d08d6b70859 },
        uint128{ .high = 0xa2cb1717b52481ed, .low = 0x54768c4b0c64ca6f },
        uint128{ .high = 0xcb7ddcdda26da268, .low = 0xa9942f5dcf7dfd0a },
        uint128{ .high = 0xfe5d54150b090b02, .low = 0xd3f93b35435d7c4d },
        uint128{ .high = 0x9efa548d26e5a6e1, .low = 0xc47bc5014a1a6db0 },
        uint128{ .high = 0xc6b8e9b0709f109a, .low = 0x359ab6419ca1091c },
        uint128{ .high = 0xf867241c8cc6d4c0, .low = 0xc30163d203c94b63 },
        uint128{ .high = 0x9b407691d7fc44f8, .low = 0x79e0de63425dcf1e },
        uint128{ .high = 0xc21094364dfb5636, .low = 0x985915fc12f542e5 },
        uint128{ .high = 0xf294b943e17a2bc4, .low = 0x3e6f5b7b17b2939e },
        uint128{ .high = 0x979cf3ca6cec5b5a, .low = 0xa705992ceecf9c43 },
        uint128{ .high = 0xbd8430bd08277231, .low = 0x50c6ff782a838354 },
        uint128{ .high = 0xece53cec4a314ebd, .low = 0xa4f8bf5635246429 },
        uint128{ .high = 0x940f4613ae5ed136, .low = 0x871b7795e136be9a },
        uint128{ .high = 0xb913179899f68584, .low = 0x28e2557b59846e40 },
        uint128{ .high = 0xe757dd7ec07426e5, .low = 0x331aeada2fe589d0 },
        uint128{ .high = 0x9096ea6f3848984f, .low = 0x3ff0d2c85def7622 },
        uint128{ .high = 0xb4bca50b065abe63, .low = 0x0fed077a756b53aa },
        uint128{ .high = 0xe1ebce4dc7f16dfb, .low = 0xd3e8495912c62895 },
        uint128{ .high = 0x8d3360f09cf6e4bd, .low = 0x64712dd7abbbd95d },
        uint128{ .high = 0xb080392cc4349dec, .low = 0xbd8d794d96aacfb4 },
        uint128{ .high = 0xdca04777f541c567, .low = 0xecf0d7a0fc5583a1 },
        uint128{ .high = 0x89e42caaf9491b60, .low = 0xf41686c49db57245 },
        uint128{ .high = 0xac5d37d5b79b6239, .low = 0x311c2875c522ced6 },
        uint128{ .high = 0xd77485cb25823ac7, .low = 0x7d633293366b828c },
        uint128{ .high = 0x86a8d39ef77164bc, .low = 0xae5dff9c02033198 },
        uint128{ .high = 0xa8530886b54dbdeb, .low = 0xd9f57f830283fdfd },
        uint128{ .high = 0xd267caa862a12d66, .low = 0xd072df63c324fd7c },
        uint128{ .high = 0x8380dea93da4bc60, .low = 0x4247cb9e59f71e6e },
        uint128{ .high = 0xa46116538d0deb78, .low = 0x52d9be85f074e609 },
        uint128{ .high = 0xcd795be870516656, .low = 0x67902e276c921f8c },
        uint128{ .high = 0x806bd9714632dff6, .low = 0x00ba1cd8a3db53b7 },
        uint128{ .high = 0xa086cfcd97bf97f3, .low = 0x80e8a40eccd228a5 },
        uint128{ .high = 0xc8a883c0fdaf7df0, .low = 0x6122cd128006b2ce },
        uint128{ .high = 0xfad2a4b13d1b5d6c, .low = 0x796b805720085f82 },
        uint128{ .high = 0x9cc3a6eec6311a63, .low = 0xcbe3303674053bb1 },
        uint128{ .high = 0xc3f490aa77bd60fc, .low = 0xbedbfc4411068a9d },
        uint128{ .high = 0xf4f1b4d515acb93b, .low = 0xee92fb5515482d45 },
        uint128{ .high = 0x991711052d8bf3c5, .low = 0x751bdd152d4d1c4b },
        uint128{ .high = 0xbf5cd54678eef0b6, .low = 0xd262d45a78a0635e },
        uint128{ .high = 0xef340a98172aace4, .low = 0x86fb897116c87c35 },
        uint128{ .high = 0x9580869f0e7aac0e, .low = 0xd45d35e6ae3d4da1 },
        uint128{ .high = 0xbae0a846d2195712, .low = 0x8974836059cca10a },
        uint128{ .high = 0xe998d258869facd7, .low = 0x2bd1a438703fc94c },
        uint128{ .high = 0x91ff83775423cc06, .low = 0x7b6306a34627ddd0 },
        uint128{ .high = 0xb67f6455292cbf08, .low = 0x1a3bc84c17b1d543 },
        uint128{ .high = 0xe41f3d6a7377eeca, .low = 0x20caba5f1d9e4a94 },
        uint128{ .high = 0x8e938662882af53e, .low = 0x547eb47b7282ee9d },
        uint128{ .high = 0xb23867fb2a35b28d, .low = 0xe99e619a4f23aa44 },
        uint128{ .high = 0xdec681f9f4c31f31, .low = 0x6405fa00e2ec94d5 },
        uint128{ .high = 0x8b3c113c38f9f37e, .low = 0xde83bc408dd3dd05 },
        uint128{ .high = 0xae0b158b4738705e, .low = 0x9624ab50b148d446 },
        uint128{ .high = 0xd98ddaee19068c76, .low = 0x3badd624dd9b0958 },
        uint128{ .high = 0x87f8a8d4cfa417c9, .low = 0xe54ca5d70a80e5d7 },
        uint128{ .high = 0xa9f6d30a038d1dbc, .low = 0x5e9fcf4ccd211f4d },
        uint128{ .high = 0xd47487cc8470652b, .low = 0x7647c32000696720 },
        uint128{ .high = 0x84c8d4dfd2c63f3b, .low = 0x29ecd9f40041e074 },
        uint128{ .high = 0xa5fb0a17c777cf09, .low = 0xf468107100525891 },
        uint128{ .high = 0xcf79cc9db955c2cc, .low = 0x7182148d4066eeb5 },
        uint128{ .high = 0x81ac1fe293d599bf, .low = 0xc6f14cd848405531 },
        uint128{ .high = 0xa21727db38cb002f, .low = 0xb8ada00e5a506a7d },
        uint128{ .high = 0xca9cf1d206fdc03b, .low = 0xa6d90811f0e4851d },
        uint128{ .high = 0xfd442e4688bd304a, .low = 0x908f4a166d1da664 },
        uint128{ .high = 0x9e4a9cec15763e2e, .low = 0x9a598e4e043287ff },
        uint128{ .high = 0xc5dd44271ad3cdba, .low = 0x40eff1e1853f29fe },
        uint128{ .high = 0xf7549530e188c128, .low = 0xd12bee59e68ef47d },
        uint128{ .high = 0x9a94dd3e8cf578b9, .low = 0x82bb74f8301958cf },
        uint128{ .high = 0xc13a148e3032d6e7, .low = 0xe36a52363c1faf02 },
        uint128{ .high = 0xf18899b1bc3f8ca1, .low = 0xdc44e6c3cb279ac2 },
        uint128{ .high = 0x96f5600f15a7b7e5, .low = 0x29ab103a5ef8c0ba },
        uint128{ .high = 0xbcb2b812db11a5de, .low = 0x7415d448f6b6f0e8 },
        uint128{ .high = 0xebdf661791d60f56, .low = 0x111b495b3464ad22 },
        uint128{ .high = 0x936b9fcebb25c995, .low = 0xcab10dd900beec35 },
        uint128{ .high = 0xb84687c269ef3bfb, .low = 0x3d5d514f40eea743 },
        uint128{ .high = 0xe65829b3046b0afa, .low = 0x0cb4a5a3112a5113 },
        uint128{ .high = 0x8ff71a0fe2c2e6dc, .low = 0x47f0e785eaba72ac },
        uint128{ .high = 0xb3f4e093db73a093, .low = 0x59ed216765690f57 },
        uint128{ .high = 0xe0f218b8d25088b8, .low = 0x306869c13ec3532d },
        uint128{ .high = 0x8c974f7383725573, .low = 0x1e414218c73a13fc },
        uint128{ .high = 0xafbd2350644eeacf, .low = 0xe5d1929ef90898fb },
        uint128{ .high = 0xdbac6c247d62a583, .low = 0xdf45f746b74abf3a },
        uint128{ .high = 0x894bc396ce5da772, .low = 0x6b8bba8c328eb784 },
        uint128{ .high = 0xab9eb47c81f5114f, .low = 0x066ea92f3f326565 },
        uint128{ .high = 0xd686619ba27255a2, .low = 0xc80a537b0efefebe },
        uint128{ .high = 0x8613fd0145877585, .low = 0xbd06742ce95f5f37 },
        uint128{ .high = 0xa798fc4196e952e7, .low = 0x2c48113823b73705 },
        uint128{ .high = 0xd17f3b51fca3a7a0, .low = 0xf75a15862ca504c6 },
        uint128{ .high = 0x82ef85133de648c4, .low = 0x9a984d73dbe722fc },
        uint128{ .high = 0xa3ab66580d5fdaf5, .low = 0xc13e60d0d2e0ebbb },
        uint128{ .high = 0xcc963fee10b7d1b3, .low = 0x318df905079926a9 },
        uint128{ .high = 0xffbbcfe994e5c61f, .low = 0xfdf17746497f7053 },
        uint128{ .high = 0x9fd561f1fd0f9bd3, .low = 0xfeb6ea8bedefa634 },
        uint128{ .high = 0xc7caba6e7c5382c8, .low = 0xfe64a52ee96b8fc1 },
        uint128{ .high = 0xf9bd690a1b68637b, .low = 0x3dfdce7aa3c673b1 },
        uint128{ .high = 0x9c1661a651213e2d, .low = 0x06bea10ca65c084f },
        uint128{ .high = 0xc31bfa0fe5698db8, .low = 0x486e494fcff30a63 },
        uint128{ .high = 0xf3e2f893dec3f126, .low = 0x5a89dba3c3efccfb },
        uint128{ .high = 0x986ddb5c6b3a76b7, .low = 0xf89629465a75e01d },
        uint128{ .high = 0xbe89523386091465, .low = 0xf6bbb397f1135824 },
        uint128{ .high = 0xee2ba6c0678b597f, .low = 0x746aa07ded582e2d },
        uint128{ .high = 0x94db483840b717ef, .low = 0xa8c2a44eb4571cdd },
        uint128{ .high = 0xba121a4650e4ddeb, .low = 0x92f34d62616ce414 },
        uint128{ .high = 0xe896a0d7e51e1566, .low = 0x77b020baf9c81d18 },
        uint128{ .high = 0x915e2486ef32cd60, .low = 0x0ace1474dc1d122f },
        uint128{ .high = 0xb5b5ada8aaff80b8, .low = 0x0d819992132456bb },
        uint128{ .high = 0xe3231912d5bf60e6, .low = 0x10e1fff697ed6c6a },
        uint128{ .high = 0x8df5efabc5979c8f, .low = 0xca8d3ffa1ef463c2 },
        uint128{ .high = 0xb1736b96b6fd83b3, .low = 0xbd308ff8a6b17cb3 },
        uint128{ .high = 0xddd0467c64bce4a0, .low = 0xac7cb3f6d05ddbdf },
        uint128{ .high = 0x8aa22c0dbef60ee4, .low = 0x6bcdf07a423aa96c },
        uint128{ .high = 0xad4ab7112eb3929d, .low = 0x86c16c98d2c953c7 },
        uint128{ .high = 0xd89d64d57a607744, .low = 0xe871c7bf077ba8b8 },
        uint128{ .high = 0x87625f056c7c4a8b, .low = 0x11471cd764ad4973 },
        uint128{ .high = 0xa93af6c6c79b5d2d, .low = 0xd598e40d3dd89bd0 },
        uint128{ .high = 0xd389b47879823479, .low = 0x4aff1d108d4ec2c4 },
        uint128{ .high = 0x843610cb4bf160cb, .low = 0xcedf722a585139bb },
        uint128{ .high = 0xa54394fe1eedb8fe, .low = 0xc2974eb4ee658829 },
        uint128{ .high = 0xce947a3da6a9273e, .low = 0x733d226229feea33 },
        uint128{ .high = 0x811ccc668829b887, .low = 0x0806357d5a3f5260 },
        uint128{ .high = 0xa163ff802a3426a8, .low = 0xca07c2dcb0cf26f8 },
        uint128{ .high = 0xc9bcff6034c13052, .low = 0xfc89b393dd02f0b6 },
        uint128{ .high = 0xfc2c3f3841f17c67, .low = 0xbbac2078d443ace3 },
        uint128{ .high = 0x9d9ba7832936edc0, .low = 0xd54b944b84aa4c0e },
        uint128{ .high = 0xc5029163f384a931, .low = 0x0a9e795e65d4df12 },
        uint128{ .high = 0xf64335bcf065d37d, .low = 0x4d4617b5ff4a16d6 },
        uint128{ .high = 0x99ea0196163fa42e, .low = 0x504bced1bf8e4e46 },
        uint128{ .high = 0xc06481fb9bcf8d39, .low = 0xe45ec2862f71e1d7 },
        uint128{ .high = 0xf07da27a82c37088, .low = 0x5d767327bb4e5a4d },
        uint128{ .high = 0x964e858c91ba2655, .low = 0x3a6a07f8d510f870 },
        uint128{ .high = 0xbbe226efb628afea, .low = 0x890489f70a55368c },
        uint128{ .high = 0xeadab0aba3b2dbe5, .low = 0x2b45ac74ccea842f },
        uint128{ .high = 0x92c8ae6b464fc96f, .low = 0x3b0b8bc90012929e },
        uint128{ .high = 0xb77ada0617e3bbcb, .low = 0x09ce6ebb40173745 },
        uint128{ .high = 0xe55990879ddcaabd, .low = 0xcc420a6a101d0516 },
        uint128{ .high = 0x8f57fa54c2a9eab6, .low = 0x9fa946824a12232e },
        uint128{ .high = 0xb32df8e9f3546564, .low = 0x47939822dc96abfa },
        uint128{ .high = 0xdff9772470297ebd, .low = 0x59787e2b93bc56f8 },
        uint128{ .high = 0x8bfbea76c619ef36, .low = 0x57eb4edb3c55b65b },
        uint128{ .high = 0xaefae51477a06b03, .low = 0xede622920b6b23f2 },
        uint128{ .high = 0xdab99e59958885c4, .low = 0xe95fab368e45ecee },
        uint128{ .high = 0x88b402f7fd75539b, .low = 0x11dbcb0218ebb415 },
        uint128{ .high = 0xaae103b5fcd2a881, .low = 0xd652bdc29f26a11a },
        uint128{ .high = 0xd59944a37c0752a2, .low = 0x4be76d3346f04960 },
        uint128{ .high = 0x857fcae62d8493a5, .low = 0x6f70a4400c562ddc },
        uint128{ .high = 0xa6dfbd9fb8e5b88e, .low = 0xcb4ccd500f6bb953 },
        uint128{ .high = 0xd097ad07a71f26b2, .low = 0x7e2000a41346a7a8 },
        uint128{ .high = 0x825ecc24c873782f, .low = 0x8ed400668c0c28c9 },
        uint128{ .high = 0xa2f67f2dfa90563b, .low = 0x728900802f0f32fb },
        uint128{ .high = 0xcbb41ef979346bca, .low = 0x4f2b40a03ad2ffba },
        uint128{ .high = 0xfea126b7d78186bc, .low = 0xe2f610c84987bfa9 },
        uint128{ .high = 0x9f24b832e6b0f436, .low = 0x0dd9ca7d2df4d7ca },
        uint128{ .high = 0xc6ede63fa05d3143, .low = 0x91503d1c79720dbc },
        uint128{ .high = 0xf8a95fcf88747d94, .low = 0x75a44c6397ce912b },
        uint128{ .high = 0x9b69dbe1b548ce7c, .low = 0xc986afbe3ee11abb },
        uint128{ .high = 0xc24452da229b021b, .low = 0xfbe85badce996169 },
        uint128{ .high = 0xf2d56790ab41c2a2, .low = 0xfae27299423fb9c4 },
        uint128{ .high = 0x97c560ba6b0919a5, .low = 0xdccd879fc967d41b },
        uint128{ .high = 0xbdb6b8e905cb600f, .low = 0x5400e987bbc1c921 },
        uint128{ .high = 0xed246723473e3813, .low = 0x290123e9aab23b69 },
        uint128{ .high = 0x9436c0760c86e30b, .low = 0xf9a0b6720aaf6522 },
        uint128{ .high = 0xb94470938fa89bce, .low = 0xf808e40e8d5b3e6a },
        uint128{ .high = 0xe7958cb87392c2c2, .low = 0xb60b1d1230b20e05 },
        uint128{ .high = 0x90bd77f3483bb9b9, .low = 0xb1c6f22b5e6f48c3 },
        uint128{ .high = 0xb4ecd5f01a4aa828, .low = 0x1e38aeb6360b1af4 },
        uint128{ .high = 0xe2280b6c20dd5232, .low = 0x25c6da63c38de1b1 },
        uint128{ .high = 0x8d590723948a535f, .low = 0x579c487e5a38ad0f },
        uint128{ .high = 0xb0af48ec79ace837, .low = 0x2d835a9df0c6d852 },
        uint128{ .high = 0xdcdb1b2798182244, .low = 0xf8e431456cf88e66 },
        uint128{ .high = 0x8a08f0f8bf0f156b, .low = 0x1b8e9ecb641b5900 },
        uint128{ .high = 0xac8b2d36eed2dac5, .low = 0xe272467e3d222f40 },
        uint128{ .high = 0xd7adf884aa879177, .low = 0x5b0ed81dcc6abb10 },
        uint128{ .high = 0x86ccbb52ea94baea, .low = 0x98e947129fc2b4ea },
        uint128{ .high = 0xa87fea27a539e9a5, .low = 0x3f2398d747b36225 },
        uint128{ .high = 0xd29fe4b18e88640e, .low = 0x8eec7f0d19a03aae },
        uint128{ .high = 0x83a3eeeef9153e89, .low = 0x1953cf68300424ad },
        uint128{ .high = 0xa48ceaaab75a8e2b, .low = 0x5fa8c3423c052dd8 },
        uint128{ .high = 0xcdb02555653131b6, .low = 0x3792f412cb06794e },
        uint128{ .high = 0x808e17555f3ebf11, .low = 0xe2bbd88bbee40bd1 },
        uint128{ .high = 0xa0b19d2ab70e6ed6, .low = 0x5b6aceaeae9d0ec5 },
        uint128{ .high = 0xc8de047564d20a8b, .low = 0xf245825a5a445276 },
        uint128{ .high = 0xfb158592be068d2e, .low = 0xeed6e2f0f0d56713 },
        uint128{ .high = 0x9ced737bb6c4183d, .low = 0x55464dd69685606c },
        uint128{ .high = 0xc428d05aa4751e4c, .low = 0xaa97e14c3c26b887 },
        uint128{ .high = 0xf53304714d9265df, .low = 0xd53dd99f4b3066a9 },
        uint128{ .high = 0x993fe2c6d07b7fab, .low = 0xe546a8038efe402a },
        uint128{ .high = 0xbf8fdb78849a5f96, .low = 0xde98520472bdd034 },
        uint128{ .high = 0xef73d256a5c0f77c, .low = 0x963e66858f6d4441 },
        uint128{ .high = 0x95a8637627989aad, .low = 0xdde7001379a44aa9 },
        uint128{ .high = 0xbb127c53b17ec159, .low = 0x5560c018580d5d53 },
        uint128{ .high = 0xe9d71b689dde71af, .low = 0xaab8f01e6e10b4a7 },
        uint128{ .high = 0x9226712162ab070d, .low = 0xcab3961304ca70e9 },
        uint128{ .high = 0xb6b00d69bb55c8d1, .low = 0x3d607b97c5fd0d23 },
        uint128{ .high = 0xe45c10c42a2b3b05, .low = 0x8cb89a7db77c506b },
        uint128{ .high = 0x8eb98a7a9a5b04e3, .low = 0x77f3608e92adb243 },
        uint128{ .high = 0xb267ed1940f1c61c, .low = 0x55f038b237591ed4 },
        uint128{ .high = 0xdf01e85f912e37a3, .low = 0x6b6c46dec52f6689 },
        uint128{ .high = 0x8b61313bbabce2c6, .low = 0x2323ac4b3b3da016 },
        uint128{ .high = 0xae397d8aa96c1b77, .low = 0xabec975e0a0d081b },
        uint128{ .high = 0xd9c7dced53c72255, .low = 0x96e7bd358c904a22 },
        uint128{ .high = 0x881cea14545c7575, .low = 0x7e50d64177da2e55 },
        uint128{ .high = 0xaa242499697392d2, .low = 0xdde50bd1d5d0b9ea },
        uint128{ .high = 0xd4ad2dbfc3d07787, .low = 0x955e4ec64b44e865 },
        uint128{ .high = 0x84ec3c97da624ab4, .low = 0xbd5af13bef0b113f },
        uint128{ .high = 0xa6274bbdd0fadd61, .low = 0xecb1ad8aeacdd58f },
        uint128{ .high = 0xcfb11ead453994ba, .low = 0x67de18eda5814af3 },
        uint128{ .high = 0x81ceb32c4b43fcf4, .low = 0x80eacf948770ced8 },
        uint128{ .high = 0xa2425ff75e14fc31, .low = 0xa1258379a94d028e },
        uint128{ .high = 0xcad2f7f5359a3b3e, .low = 0x096ee45813a04331 },
        uint128{ .high = 0xfd87b5f28300ca0d, .low = 0x8bca9d6e188853fd },
        uint128{ .high = 0x9e74d1b791e07e48, .low = 0x775ea264cf55347e },
        uint128{ .high = 0xc612062576589dda, .low = 0x95364afe032a819e },
        uint128{ .high = 0xf79687aed3eec551, .low = 0x3a83ddbd83f52205 },
        uint128{ .high = 0x9abe14cd44753b52, .low = 0xc4926a9672793543 },
        uint128{ .high = 0xc16d9a0095928a27, .low = 0x75b7053c0f178294 },
        uint128{ .high = 0xf1c90080baf72cb1, .low = 0x5324c68b12dd6339 },
        uint128{ .high = 0x971da05074da7bee, .low = 0xd3f6fc16ebca5e04 },
        uint128{ .high = 0xbce5086492111aea, .low = 0x88f4bb1ca6bcf585 },
        uint128{ .high = 0xec1e4a7db69561a5, .low = 0x2b31e9e3d06c32e6 },
        uint128{ .high = 0x9392ee8e921d5d07, .low = 0x3aff322e62439fd0 },
        uint128{ .high = 0xb877aa3236a4b449, .low = 0x09befeb9fad487c3 },
        uint128{ .high = 0xe69594bec44de15b, .low = 0x4c2ebe687989a9b4 },
        uint128{ .high = 0x901d7cf73ab0acd9, .low = 0x0f9d37014bf60a11 },
        uint128{ .high = 0xb424dc35095cd80f, .low = 0x538484c19ef38c95 },
        uint128{ .high = 0xe12e13424bb40e13, .low = 0x2865a5f206b06fba },
        uint128{ .high = 0x8cbccc096f5088cb, .low = 0xf93f87b7442e45d4 },
        uint128{ .high = 0xafebff0bcb24aafe, .low = 0xf78f69a51539d749 },
        uint128{ .high = 0xdbe6fecebdedd5be, .low = 0xb573440e5a884d1c },
        uint128{ .high = 0x89705f4136b4a597, .low = 0x31680a88f8953031 },
        uint128{ .high = 0xabcc77118461cefc, .low = 0xfdc20d2b36ba7c3e },
        uint128{ .high = 0xd6bf94d5e57a42bc, .low = 0x3d32907604691b4d },
        uint128{ .high = 0x8637bd05af6c69b5, .low = 0xa63f9a49c2c1b110 },
        uint128{ .high = 0xa7c5ac471b478423, .low = 0x0fcf80dc33721d54 },
        uint128{ .high = 0xd1b71758e219652b, .low = 0xd3c36113404ea4a9 },
        uint128{ .high = 0x83126e978d4fdf3b, .low = 0x645a1cac083126ea },
        uint128{ .high = 0xa3d70a3d70a3d70a, .low = 0x3d70a3d70a3d70a4 },
        uint128{ .high = 0xcccccccccccccccc, .low = 0xcccccccccccccccd },
        uint128{ .high = 0x8000000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xa000000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xc800000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xfa00000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0x9c40000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xc350000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xf424000000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0x9896800000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xbebc200000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xee6b280000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0x9502f90000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xba43b74000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xe8d4a51000000000, .low = 0x0000000000000000 },
        uint128{ .high = 0x9184e72a00000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xb5e620f480000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xe35fa931a0000000, .low = 0x0000000000000000 },
        uint128{ .high = 0x8e1bc9bf04000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xb1a2bc2ec5000000, .low = 0x0000000000000000 },
        uint128{ .high = 0xde0b6b3a76400000, .low = 0x0000000000000000 },
        uint128{ .high = 0x8ac7230489e80000, .low = 0x0000000000000000 },
        uint128{ .high = 0xad78ebc5ac620000, .low = 0x0000000000000000 },
        uint128{ .high = 0xd8d726b7177a8000, .low = 0x0000000000000000 },
        uint128{ .high = 0x878678326eac9000, .low = 0x0000000000000000 },
        uint128{ .high = 0xa968163f0a57b400, .low = 0x0000000000000000 },
        uint128{ .high = 0xd3c21bcecceda100, .low = 0x0000000000000000 },
        uint128{ .high = 0x84595161401484a0, .low = 0x0000000000000000 },
        uint128{ .high = 0xa56fa5b99019a5c8, .low = 0x0000000000000000 },
        uint128{ .high = 0xcecb8f27f4200f3a, .low = 0x0000000000000000 },
        uint128{ .high = 0x813f3978f8940984, .low = 0x4000000000000000 },
        uint128{ .high = 0xa18f07d736b90be5, .low = 0x5000000000000000 },
        uint128{ .high = 0xc9f2c9cd04674ede, .low = 0xa400000000000000 },
        uint128{ .high = 0xfc6f7c4045812296, .low = 0x4d00000000000000 },
        uint128{ .high = 0x9dc5ada82b70b59d, .low = 0xf020000000000000 },
        uint128{ .high = 0xc5371912364ce305, .low = 0x6c28000000000000 },
        uint128{ .high = 0xf684df56c3e01bc6, .low = 0xc732000000000000 },
        uint128{ .high = 0x9a130b963a6c115c, .low = 0x3c7f400000000000 },
        uint128{ .high = 0xc097ce7bc90715b3, .low = 0x4b9f100000000000 },
        uint128{ .high = 0xf0bdc21abb48db20, .low = 0x1e86d40000000000 },
        uint128{ .high = 0x96769950b50d88f4, .low = 0x1314448000000000 },
        uint128{ .high = 0xbc143fa4e250eb31, .low = 0x17d955a000000000 },
        uint128{ .high = 0xeb194f8e1ae525fd, .low = 0x5dcfab0800000000 },
        uint128{ .high = 0x92efd1b8d0cf37be, .low = 0x5aa1cae500000000 },
        uint128{ .high = 0xb7abc627050305ad, .low = 0xf14a3d9e40000000 },
        uint128{ .high = 0xe596b7b0c643c719, .low = 0x6d9ccd05d0000000 },
        uint128{ .high = 0x8f7e32ce7bea5c6f, .low = 0xe4820023a2000000 },
        uint128{ .high = 0xb35dbf821ae4f38b, .low = 0xdda2802c8a800000 },
        uint128{ .high = 0xe0352f62a19e306e, .low = 0xd50b2037ad200000 },
        uint128{ .high = 0x8c213d9da502de45, .low = 0x4526f422cc340000 },
        uint128{ .high = 0xaf298d050e4395d6, .low = 0x9670b12b7f410000 },
        uint128{ .high = 0xdaf3f04651d47b4c, .low = 0x3c0cdd765f114000 },
        uint128{ .high = 0x88d8762bf324cd0f, .low = 0xa5880a69fb6ac800 },
        uint128{ .high = 0xab0e93b6efee0053, .low = 0x8eea0d047a457a00 },
        uint128{ .high = 0xd5d238a4abe98068, .low = 0x72a4904598d6d880 },
        uint128{ .high = 0x85a36366eb71f041, .low = 0x47a6da2b7f864750 },
        uint128{ .high = 0xa70c3c40a64e6c51, .low = 0x999090b65f67d924 },
        uint128{ .high = 0xd0cf4b50cfe20765, .low = 0xfff4b4e3f741cf6d },
        uint128{ .high = 0x82818f1281ed449f, .low = 0xbff8f10e7a8921a5 },
        uint128{ .high = 0xa321f2d7226895c7, .low = 0xaff72d52192b6a0e },
        uint128{ .high = 0xcbea6f8ceb02bb39, .low = 0x9bf4f8a69f764491 },
        uint128{ .high = 0xfee50b7025c36a08, .low = 0x02f236d04753d5b5 },
        uint128{ .high = 0x9f4f2726179a2245, .low = 0x01d762422c946591 },
        uint128{ .high = 0xc722f0ef9d80aad6, .low = 0x424d3ad2b7b97ef6 },
        uint128{ .high = 0xf8ebad2b84e0d58b, .low = 0xd2e0898765a7deb3 },
        uint128{ .high = 0x9b934c3b330c8577, .low = 0x63cc55f49f88eb30 },
        uint128{ .high = 0xc2781f49ffcfa6d5, .low = 0x3cbf6b71c76b25fc },
        uint128{ .high = 0xf316271c7fc3908a, .low = 0x8bef464e3945ef7b },
        uint128{ .high = 0x97edd871cfda3a56, .low = 0x97758bf0e3cbb5ad },
        uint128{ .high = 0xbde94e8e43d0c8ec, .low = 0x3d52eeed1cbea318 },
        uint128{ .high = 0xed63a231d4c4fb27, .low = 0x4ca7aaa863ee4bde },
        uint128{ .high = 0x945e455f24fb1cf8, .low = 0x8fe8caa93e74ef6b },
        uint128{ .high = 0xb975d6b6ee39e436, .low = 0xb3e2fd538e122b45 },
        uint128{ .high = 0xe7d34c64a9c85d44, .low = 0x60dbbca87196b617 },
        uint128{ .high = 0x90e40fbeea1d3a4a, .low = 0xbc8955e946fe31ce },
        uint128{ .high = 0xb51d13aea4a488dd, .low = 0x6babab6398bdbe42 },
        uint128{ .high = 0xe264589a4dcdab14, .low = 0xc696963c7eed2dd2 },
        uint128{ .high = 0x8d7eb76070a08aec, .low = 0xfc1e1de5cf543ca3 },
        uint128{ .high = 0xb0de65388cc8ada8, .low = 0x3b25a55f43294bcc },
        uint128{ .high = 0xdd15fe86affad912, .low = 0x49ef0eb713f39ebf },
        uint128{ .high = 0x8a2dbf142dfcc7ab, .low = 0x6e3569326c784338 },
        uint128{ .high = 0xacb92ed9397bf996, .low = 0x49c2c37f07965405 },
        uint128{ .high = 0xd7e77a8f87daf7fb, .low = 0xdc33745ec97be907 },
        uint128{ .high = 0x86f0ac99b4e8dafd, .low = 0x69a028bb3ded71a4 },
        uint128{ .high = 0xa8acd7c0222311bc, .low = 0xc40832ea0d68ce0d },
        uint128{ .high = 0xd2d80db02aabd62b, .low = 0xf50a3fa490c30191 },
        uint128{ .high = 0x83c7088e1aab65db, .low = 0x792667c6da79e0fb },
        uint128{ .high = 0xa4b8cab1a1563f52, .low = 0x577001b891185939 },
        uint128{ .high = 0xcde6fd5e09abcf26, .low = 0xed4c0226b55e6f87 },
        uint128{ .high = 0x80b05e5ac60b6178, .low = 0x544f8158315b05b5 },
        uint128{ .high = 0xa0dc75f1778e39d6, .low = 0x696361ae3db1c722 },
        uint128{ .high = 0xc913936dd571c84c, .low = 0x03bc3a19cd1e38ea },
        uint128{ .high = 0xfb5878494ace3a5f, .low = 0x04ab48a04065c724 },
        uint128{ .high = 0x9d174b2dcec0e47b, .low = 0x62eb0d64283f9c77 },
        uint128{ .high = 0xc45d1df942711d9a, .low = 0x3ba5d0bd324f8395 },
        uint128{ .high = 0xf5746577930d6500, .low = 0xca8f44ec7ee3647a },
        uint128{ .high = 0x9968bf6abbe85f20, .low = 0x7e998b13cf4e1ecc },
        uint128{ .high = 0xbfc2ef456ae276e8, .low = 0x9e3fedd8c321a67f },
        uint128{ .high = 0xefb3ab16c59b14a2, .low = 0xc5cfe94ef3ea101f },
        uint128{ .high = 0x95d04aee3b80ece5, .low = 0xbba1f1d158724a13 },
        uint128{ .high = 0xbb445da9ca61281f, .low = 0x2a8a6e45ae8edc98 },
        uint128{ .high = 0xea1575143cf97226, .low = 0xf52d09d71a3293be },
        uint128{ .high = 0x924d692ca61be758, .low = 0x593c2626705f9c57 },
        uint128{ .high = 0xb6e0c377cfa2e12e, .low = 0x6f8b2fb00c77836d },
        uint128{ .high = 0xe498f455c38b997a, .low = 0x0b6dfb9c0f956448 },
        uint128{ .high = 0x8edf98b59a373fec, .low = 0x4724bd4189bd5ead },
        uint128{ .high = 0xb2977ee300c50fe7, .low = 0x58edec91ec2cb658 },
        uint128{ .high = 0xdf3d5e9bc0f653e1, .low = 0x2f2967b66737e3ee },
        uint128{ .high = 0x8b865b215899f46c, .low = 0xbd79e0d20082ee75 },
        uint128{ .high = 0xae67f1e9aec07187, .low = 0xecd8590680a3aa12 },
        uint128{ .high = 0xda01ee641a708de9, .low = 0xe80e6f4820cc9496 },
        uint128{ .high = 0x884134fe908658b2, .low = 0x3109058d147fdcde },
        uint128{ .high = 0xaa51823e34a7eede, .low = 0xbd4b46f0599fd416 },
        uint128{ .high = 0xd4e5e2cdc1d1ea96, .low = 0x6c9e18ac7007c91b },
        uint128{ .high = 0x850fadc09923329e, .low = 0x03e2cf6bc604ddb1 },
        uint128{ .high = 0xa6539930bf6bff45, .low = 0x84db8346b786151d },
        uint128{ .high = 0xcfe87f7cef46ff16, .low = 0xe612641865679a64 },
        uint128{ .high = 0x81f14fae158c5f6e, .low = 0x4fcb7e8f3f60c07f },
        uint128{ .high = 0xa26da3999aef7749, .low = 0xe3be5e330f38f09e },
        uint128{ .high = 0xcb090c8001ab551c, .low = 0x5cadf5bfd3072cc6 },
        uint128{ .high = 0xfdcb4fa002162a63, .low = 0x73d9732fc7c8f7f7 },
        uint128{ .high = 0x9e9f11c4014dda7e, .low = 0x2867e7fddcdd9afb },
        uint128{ .high = 0xc646d63501a1511d, .low = 0xb281e1fd541501b9 },
        uint128{ .high = 0xf7d88bc24209a565, .low = 0x1f225a7ca91a4227 },
        uint128{ .high = 0x9ae757596946075f, .low = 0x3375788de9b06959 },
        uint128{ .high = 0xc1a12d2fc3978937, .low = 0x0052d6b1641c83af },
        uint128{ .high = 0xf209787bb47d6b84, .low = 0xc0678c5dbd23a49b },
        uint128{ .high = 0x9745eb4d50ce6332, .low = 0xf840b7ba963646e1 },
        uint128{ .high = 0xbd176620a501fbff, .low = 0xb650e5a93bc3d899 },
        uint128{ .high = 0xec5d3fa8ce427aff, .low = 0xa3e51f138ab4cebf },
        uint128{ .high = 0x93ba47c980e98cdf, .low = 0xc66f336c36b10138 },
        uint128{ .high = 0xb8a8d9bbe123f017, .low = 0xb80b0047445d4185 },
        uint128{ .high = 0xe6d3102ad96cec1d, .low = 0xa60dc059157491e6 },
        uint128{ .high = 0x9043ea1ac7e41392, .low = 0x87c89837ad68db30 },
        uint128{ .high = 0xb454e4a179dd1877, .low = 0x29babe4598c311fc },
        uint128{ .high = 0xe16a1dc9d8545e94, .low = 0xf4296dd6fef3d67b },
        uint128{ .high = 0x8ce2529e2734bb1d, .low = 0x1899e4a65f58660d },
        uint128{ .high = 0xb01ae745b101e9e4, .low = 0x5ec05dcff72e7f90 },
        uint128{ .high = 0xdc21a1171d42645d, .low = 0x76707543f4fa1f74 },
        uint128{ .high = 0x899504ae72497eba, .low = 0x6a06494a791c53a9 },
        uint128{ .high = 0xabfa45da0edbde69, .low = 0x0487db9d17636893 },
        uint128{ .high = 0xd6f8d7509292d603, .low = 0x45a9d2845d3c42b7 },
        uint128{ .high = 0x865b86925b9bc5c2, .low = 0x0b8a2392ba45a9b3 },
        uint128{ .high = 0xa7f26836f282b732, .low = 0x8e6cac7768d7141f },
        uint128{ .high = 0xd1ef0244af2364ff, .low = 0x3207d795430cd927 },
        uint128{ .high = 0x8335616aed761f1f, .low = 0x7f44e6bd49e807b9 },
        uint128{ .high = 0xa402b9c5a8d3a6e7, .low = 0x5f16206c9c6209a7 },
        uint128{ .high = 0xcd036837130890a1, .low = 0x36dba887c37a8c10 },
        uint128{ .high = 0x802221226be55a64, .low = 0xc2494954da2c978a },
        uint128{ .high = 0xa02aa96b06deb0fd, .low = 0xf2db9baa10b7bd6d },
        uint128{ .high = 0xc83553c5c8965d3d, .low = 0x6f92829494e5acc8 },
        uint128{ .high = 0xfa42a8b73abbf48c, .low = 0xcb772339ba1f17fa },
        uint128{ .high = 0x9c69a97284b578d7, .low = 0xff2a760414536efc },
        uint128{ .high = 0xc38413cf25e2d70d, .low = 0xfef5138519684abb },
        uint128{ .high = 0xf46518c2ef5b8cd1, .low = 0x7eb258665fc25d6a },
        uint128{ .high = 0x98bf2f79d5993802, .low = 0xef2f773ffbd97a62 },
        uint128{ .high = 0xbeeefb584aff8603, .low = 0xaafb550ffacfd8fb },
        uint128{ .high = 0xeeaaba2e5dbf6784, .low = 0x95ba2a53f983cf39 },
        uint128{ .high = 0x952ab45cfa97a0b2, .low = 0xdd945a747bf26184 },
        uint128{ .high = 0xba756174393d88df, .low = 0x94f971119aeef9e5 },
        uint128{ .high = 0xe912b9d1478ceb17, .low = 0x7a37cd5601aab85e },
        uint128{ .high = 0x91abb422ccb812ee, .low = 0xac62e055c10ab33b },
        uint128{ .high = 0xb616a12b7fe617aa, .low = 0x577b986b314d600a },
        uint128{ .high = 0xe39c49765fdf9d94, .low = 0xed5a7e85fda0b80c },
        uint128{ .high = 0x8e41ade9fbebc27d, .low = 0x14588f13be847308 },
        uint128{ .high = 0xb1d219647ae6b31c, .low = 0x596eb2d8ae258fc9 },
        uint128{ .high = 0xde469fbd99a05fe3, .low = 0x6fca5f8ed9aef3bc },
        uint128{ .high = 0x8aec23d680043bee, .low = 0x25de7bb9480d5855 },
        uint128{ .high = 0xada72ccc20054ae9, .low = 0xaf561aa79a10ae6b },
        uint128{ .high = 0xd910f7ff28069da4, .low = 0x1b2ba1518094da05 },
        uint128{ .high = 0x87aa9aff79042286, .low = 0x90fb44d2f05d0843 },
        uint128{ .high = 0xa99541bf57452b28, .low = 0x353a1607ac744a54 },
        uint128{ .high = 0xd3fa922f2d1675f2, .low = 0x42889b8997915ce9 },
        uint128{ .high = 0x847c9b5d7c2e09b7, .low = 0x69956135febada12 },
        uint128{ .high = 0xa59bc234db398c25, .low = 0x43fab9837e699096 },
        uint128{ .high = 0xcf02b2c21207ef2e, .low = 0x94f967e45e03f4bc },
        uint128{ .high = 0x8161afb94b44f57d, .low = 0x1d1be0eebac278f6 },
        uint128{ .high = 0xa1ba1ba79e1632dc, .low = 0x6462d92a69731733 },
        uint128{ .high = 0xca28a291859bbf93, .low = 0x7d7b8f7503cfdcff },
        uint128{ .high = 0xfcb2cb35e702af78, .low = 0x5cda735244c3d43f },
        uint128{ .high = 0x9defbf01b061adab, .low = 0x3a0888136afa64a8 },
        uint128{ .high = 0xc56baec21c7a1916, .low = 0x088aaa1845b8fdd1 },
        uint128{ .high = 0xf6c69a72a3989f5b, .low = 0x8aad549e57273d46 },
        uint128{ .high = 0x9a3c2087a63f6399, .low = 0x36ac54e2f678864c },
        uint128{ .high = 0xc0cb28a98fcf3c7f, .low = 0x84576a1bb416a7de },
        uint128{ .high = 0xf0fdf2d3f3c30b9f, .low = 0x656d44a2a11c51d6 },
        uint128{ .high = 0x969eb7c47859e743, .low = 0x9f644ae5a4b1b326 },
        uint128{ .high = 0xbc4665b596706114, .low = 0x873d5d9f0dde1fef },
        uint128{ .high = 0xeb57ff22fc0c7959, .low = 0xa90cb506d155a7eb },
        uint128{ .high = 0x9316ff75dd87cbd8, .low = 0x09a7f12442d588f3 },
        uint128{ .high = 0xb7dcbf5354e9bece, .low = 0x0c11ed6d538aeb30 },
        uint128{ .high = 0xe5d3ef282a242e81, .low = 0x8f1668c8a86da5fb },
        uint128{ .high = 0x8fa475791a569d10, .low = 0xf96e017d694487bd },
        uint128{ .high = 0xb38d92d760ec4455, .low = 0x37c981dcc395a9ad },
        uint128{ .high = 0xe070f78d3927556a, .low = 0x85bbe253f47b1418 },
        uint128{ .high = 0x8c469ab843b89562, .low = 0x93956d7478ccec8f },
        uint128{ .high = 0xaf58416654a6babb, .low = 0x387ac8d1970027b3 },
        uint128{ .high = 0xdb2e51bfe9d0696a, .low = 0x06997b05fcc0319f },
        uint128{ .high = 0x88fcf317f22241e2, .low = 0x441fece3bdf81f04 },
        uint128{ .high = 0xab3c2fddeeaad25a, .low = 0xd527e81cad7626c4 },
        uint128{ .high = 0xd60b3bd56a5586f1, .low = 0x8a71e223d8d3b075 },
        uint128{ .high = 0x85c7056562757456, .low = 0xf6872d5667844e4a },
        uint128{ .high = 0xa738c6bebb12d16c, .low = 0xb428f8ac016561dc },
        uint128{ .high = 0xd106f86e69d785c7, .low = 0xe13336d701beba53 },
        uint128{ .high = 0x82a45b450226b39c, .low = 0xecc0024661173474 },
        uint128{ .high = 0xa34d721642b06084, .low = 0x27f002d7f95d0191 },
        uint128{ .high = 0xcc20ce9bd35c78a5, .low = 0x31ec038df7b441f5 },
        uint128{ .high = 0xff290242c83396ce, .low = 0x7e67047175a15272 },
        uint128{ .high = 0x9f79a169bd203e41, .low = 0x0f0062c6e984d387 },
        uint128{ .high = 0xc75809c42c684dd1, .low = 0x52c07b78a3e60869 },
        uint128{ .high = 0xf92e0c3537826145, .low = 0xa7709a56ccdf8a83 },
        uint128{ .high = 0x9bbcc7a142b17ccb, .low = 0x88a66076400bb692 },
        uint128{ .high = 0xc2abf989935ddbfe, .low = 0x6acff893d00ea436 },
        uint128{ .high = 0xf356f7ebf83552fe, .low = 0x0583f6b8c4124d44 },
        uint128{ .high = 0x98165af37b2153de, .low = 0xc3727a337a8b704b },
        uint128{ .high = 0xbe1bf1b059e9a8d6, .low = 0x744f18c0592e4c5d },
        uint128{ .high = 0xeda2ee1c7064130c, .low = 0x1162def06f79df74 },
        uint128{ .high = 0x9485d4d1c63e8be7, .low = 0x8addcb5645ac2ba9 },
        uint128{ .high = 0xb9a74a0637ce2ee1, .low = 0x6d953e2bd7173693 },
        uint128{ .high = 0xe8111c87c5c1ba99, .low = 0xc8fa8db6ccdd0438 },
        uint128{ .high = 0x910ab1d4db9914a0, .low = 0x1d9c9892400a22a3 },
        uint128{ .high = 0xb54d5e4a127f59c8, .low = 0x2503beb6d00cab4c },
        uint128{ .high = 0xe2a0b5dc971f303a, .low = 0x2e44ae64840fd61e },
        uint128{ .high = 0x8da471a9de737e24, .low = 0x5ceaecfed289e5d3 },
        uint128{ .high = 0xb10d8e1456105dad, .low = 0x7425a83e872c5f48 },
        uint128{ .high = 0xdd50f1996b947518, .low = 0xd12f124e28f7771a },
        uint128{ .high = 0x8a5296ffe33cc92f, .low = 0x82bd6b70d99aaa70 },
        uint128{ .high = 0xace73cbfdc0bfb7b, .low = 0x636cc64d1001550c },
        uint128{ .high = 0xd8210befd30efa5a, .low = 0x3c47f7e05401aa4f },
        uint128{ .high = 0x8714a775e3e95c78, .low = 0x65acfaec34810a72 },
        uint128{ .high = 0xa8d9d1535ce3b396, .low = 0x7f1839a741a14d0e },
        uint128{ .high = 0xd31045a8341ca07c, .low = 0x1ede48111209a051 },
        uint128{ .high = 0x83ea2b892091e44d, .low = 0x934aed0aab460433 },
        uint128{ .high = 0xa4e4b66b68b65d60, .low = 0xf81da84d56178540 },
        uint128{ .high = 0xce1de40642e3f4b9, .low = 0x36251260ab9d668f },
        uint128{ .high = 0x80d2ae83e9ce78f3, .low = 0xc1d72b7c6b42601a },
        uint128{ .high = 0xa1075a24e4421730, .low = 0xb24cf65b8612f820 },
        uint128{ .high = 0xc94930ae1d529cfc, .low = 0xdee033f26797b628 },
        uint128{ .high = 0xfb9b7cd9a4a7443c, .low = 0x169840ef017da3b2 },
        uint128{ .high = 0x9d412e0806e88aa5, .low = 0x8e1f289560ee864f },
        uint128{ .high = 0xc491798a08a2ad4e, .low = 0xf1a6f2bab92a27e3 },
        uint128{ .high = 0xf5b5d7ec8acb58a2, .low = 0xae10af696774b1dc },
        uint128{ .high = 0x9991a6f3d6bf1765, .low = 0xacca6da1e0a8ef2a },
        uint128{ .high = 0xbff610b0cc6edd3f, .low = 0x17fd090a58d32af4 },
        uint128{ .high = 0xeff394dcff8a948e, .low = 0xddfc4b4cef07f5b1 },
        uint128{ .high = 0x95f83d0a1fb69cd9, .low = 0x4abdaf101564f98f },
        uint128{ .high = 0xbb764c4ca7a4440f, .low = 0x9d6d1ad41abe37f2 },
        uint128{ .high = 0xea53df5fd18d5513, .low = 0x84c86189216dc5ee },
        uint128{ .high = 0x92746b9be2f8552c, .low = 0x32fd3cf5b4e49bb5 },
        uint128{ .high = 0xb7118682dbb66a77, .low = 0x3fbc8c33221dc2a2 },
        uint128{ .high = 0xe4d5e82392a40515, .low = 0x0fabaf3feaa5334b },
        uint128{ .high = 0x8f05b1163ba6832d, .low = 0x29cb4d87f2a7400f },
        uint128{ .high = 0xb2c71d5bca9023f8, .low = 0x743e20e9ef511013 },
        uint128{ .high = 0xdf78e4b2bd342cf6, .low = 0x914da9246b255417 },
        uint128{ .high = 0x8bab8eefb6409c1a, .low = 0x1ad089b6c2f7548f },
        uint128{ .high = 0xae9672aba3d0c320, .low = 0xa184ac2473b529b2 },
        uint128{ .high = 0xda3c0f568cc4f3e8, .low = 0xc9e5d72d90a2741f },
        uint128{ .high = 0x8865899617fb1871, .low = 0x7e2fa67c7a658893 },
        uint128{ .high = 0xaa7eebfb9df9de8d, .low = 0xddbb901b98feeab8 },
        uint128{ .high = 0xd51ea6fa85785631, .low = 0x552a74227f3ea566 },
        uint128{ .high = 0x8533285c936b35de, .low = 0xd53a88958f872760 },
        uint128{ .high = 0xa67ff273b8460356, .low = 0x8a892abaf368f138 },
        uint128{ .high = 0xd01fef10a657842c, .low = 0x2d2b7569b0432d86 },
        uint128{ .high = 0x8213f56a67f6b29b, .low = 0x9c3b29620e29fc74 },
        uint128{ .high = 0xa298f2c501f45f42, .low = 0x8349f3ba91b47b90 },
        uint128{ .high = 0xcb3f2f7642717713, .low = 0x241c70a936219a74 },
        uint128{ .high = 0xfe0efb53d30dd4d7, .low = 0xed238cd383aa0111 },
        uint128{ .high = 0x9ec95d1463e8a506, .low = 0xf4363804324a40ab },
        uint128{ .high = 0xc67bb4597ce2ce48, .low = 0xb143c6053edcd0d6 },
        uint128{ .high = 0xf81aa16fdc1b81da, .low = 0xdd94b7868e94050b },
        uint128{ .high = 0x9b10a4e5e9913128, .low = 0xca7cf2b4191c8327 },
        uint128{ .high = 0xc1d4ce1f63f57d72, .low = 0xfd1c2f611f63a3f1 },
        uint128{ .high = 0xf24a01a73cf2dccf, .low = 0xbc633b39673c8ced },
        uint128{ .high = 0x976e41088617ca01, .low = 0xd5be0503e085d814 },
        uint128{ .high = 0xbd49d14aa79dbc82, .low = 0x4b2d8644d8a74e19 },
        uint128{ .high = 0xec9c459d51852ba2, .low = 0xddf8e7d60ed1219f },
        uint128{ .high = 0x93e1ab8252f33b45, .low = 0xcabb90e5c942b504 },
        uint128{ .high = 0xb8da1662e7b00a17, .low = 0x3d6a751f3b936244 },
        uint128{ .high = 0xe7109bfba19c0c9d, .low = 0x0cc512670a783ad5 },
        uint128{ .high = 0x906a617d450187e2, .low = 0x27fb2b80668b24c6 },
        uint128{ .high = 0xb484f9dc9641e9da, .low = 0xb1f9f660802dedf7 },
        uint128{ .high = 0xe1a63853bbd26451, .low = 0x5e7873f8a0396974 },
        uint128{ .high = 0x8d07e33455637eb2, .low = 0xdb0b487b6423e1e9 },
        uint128{ .high = 0xb049dc016abc5e5f, .low = 0x91ce1a9a3d2cda63 },
        uint128{ .high = 0xdc5c5301c56b75f7, .low = 0x7641a140cc7810fc },
        uint128{ .high = 0x89b9b3e11b6329ba, .low = 0xa9e904c87fcb0a9e },
        uint128{ .high = 0xac2820d9623bf429, .low = 0x546345fa9fbdcd45 },
        uint128{ .high = 0xd732290fbacaf133, .low = 0xa97c177947ad4096 },
        uint128{ .high = 0x867f59a9d4bed6c0, .low = 0x49ed8eabcccc485e },
        uint128{ .high = 0xa81f301449ee8c70, .low = 0x5c68f256bfff5a75 },
        uint128{ .high = 0xd226fc195c6a2f8c, .low = 0x73832eec6fff3112 },
        uint128{ .high = 0x83585d8fd9c25db7, .low = 0xc831fd53c5ff7eac },
        uint128{ .high = 0xa42e74f3d032f525, .low = 0xba3e7ca8b77f5e56 },
        uint128{ .high = 0xcd3a1230c43fb26f, .low = 0x28ce1bd2e55f35ec },
        uint128{ .high = 0x80444b5e7aa7cf85, .low = 0x7980d163cf5b81b4 },
        uint128{ .high = 0xa0555e361951c366, .low = 0xd7e105bcc3326220 },
        uint128{ .high = 0xc86ab5c39fa63440, .low = 0x8dd9472bf3fefaa8 },
        uint128{ .high = 0xfa856334878fc150, .low = 0xb14f98f6f0feb952 },
        uint128{ .high = 0x9c935e00d4b9d8d2, .low = 0x6ed1bf9a569f33d4 },
        uint128{ .high = 0xc3b8358109e84f07, .low = 0x0a862f80ec4700c9 },
        uint128{ .high = 0xf4a642e14c6262c8, .low = 0xcd27bb612758c0fb },
        uint128{ .high = 0x98e7e9cccfbd7dbd, .low = 0x8038d51cb897789d },
        uint128{ .high = 0xbf21e44003acdd2c, .low = 0xe0470a63e6bd56c4 },
        uint128{ .high = 0xeeea5d5004981478, .low = 0x1858ccfce06cac75 },
        uint128{ .high = 0x95527a5202df0ccb, .low = 0x0f37801e0c43ebc9 },
        uint128{ .high = 0xbaa718e68396cffd, .low = 0xd30560258f54e6bb },
        uint128{ .high = 0xe950df20247c83fd, .low = 0x47c6b82ef32a206a },
        uint128{ .high = 0x91d28b7416cdd27e, .low = 0x4cdc331d57fa5442 },
        uint128{ .high = 0xb6472e511c81471d, .low = 0xe0133fe4adf8e953 },
        uint128{ .high = 0xe3d8f9e563a198e5, .low = 0x58180fddd97723a7 },
        uint128{ .high = 0x8e679c2f5e44ff8f, .low = 0x570f09eaa7ea7649 },
        uint128{ .high = 0xb201833b35d63f73, .low = 0x2cd2cc6551e513db },
        uint128{ .high = 0xde81e40a034bcf4f, .low = 0xf8077f7ea65e58d2 },
        uint128{ .high = 0x8b112e86420f6191, .low = 0xfb04afaf27faf783 },
        uint128{ .high = 0xadd57a27d29339f6, .low = 0x79c5db9af1f9b564 },
        uint128{ .high = 0xd94ad8b1c7380874, .low = 0x18375281ae7822bd },
        uint128{ .high = 0x87cec76f1c830548, .low = 0x8f2293910d0b15b6 },
        uint128{ .high = 0xa9c2794ae3a3c69a, .low = 0xb2eb3875504ddb23 },
        uint128{ .high = 0xd433179d9c8cb841, .low = 0x5fa60692a46151ec },
        uint128{ .high = 0x849feec281d7f328, .low = 0xdbc7c41ba6bcd334 },
        uint128{ .high = 0xa5c7ea73224deff3, .low = 0x12b9b522906c0801 },
        uint128{ .high = 0xcf39e50feae16bef, .low = 0xd768226b34870a01 },
        uint128{ .high = 0x81842f29f2cce375, .low = 0xe6a1158300d46641 },
        uint128{ .high = 0xa1e53af46f801c53, .low = 0x60495ae3c1097fd1 },
        uint128{ .high = 0xca5e89b18b602368, .low = 0x385bb19cb14bdfc5 },
        uint128{ .high = 0xfcf62c1dee382c42, .low = 0x46729e03dd9ed7b6 },
        uint128{ .high = 0x9e19db92b4e31ba9, .low = 0x6c07a2c26a8346d2 },
        uint128{ .high = 0xc5a05277621be293, .low = 0xc7098b7305241886 },
        uint128{ .high = 0xf70867153aa2db38, .low = 0xb8cbee4fc66d1ea8 },
    };
};
