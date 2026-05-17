const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const types = @import("types.zig");
const simd = @import("simd.zig");
const tokenizer_mod = @import("tokenizer.zig");

const Error = types.Error;
const ParseOptions = types.ParseOptions;
const Value = types.Value;
const ObjectMap = types.ObjectMap;
const Array = types.Array;
const MAX_DEPTH = types.MAX_DEPTH;
const MAX_INPUT_BYTES = types.MAX_INPUT_BYTES;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;
const simdParseU64Decimal = simd.simdParseU64Decimal;

const Tokenizer = tokenizer_mod.Tokenizer;
const TokenTag = tokenizer_mod.TokenTag;
const expectColon = tokenizer_mod.expectColon;

const MAX_FIELD_NAME: usize = 4096;

/// Decode a raw JSON string token (including surrounding quotes and escape sequences)
/// into `out`. Returns the written slice. `out` must be at least `raw.len` bytes.
pub fn decodeString(raw: []const u8, out: []u8) Error![]u8 {
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

/// Like `decodeString` but allocates the output buffer.
/// Pass `has_escape = false` to skip escape processing and do a fast memcpy.
pub fn allocDecodeStringHinted(allocator: Allocator, raw: []const u8, has_escape: bool) Error![]u8 {
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

/// Parse a JSON byte slice into an untyped `Value` tree.
/// The returned value owns all its memory; call `value.deinit(allocator)` when done.
/// An `ArenaAllocator` is recommended for tree-shaped data.
pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try Tokenizer.init(input);
    const v = try parseValueInner(allocator, &tok, 0);
    tok.pos = tok.scanner.nextNonSpace(input, tok.pos);
    if (tok.pos < input.len) return error.UnexpectedToken;
    return v;
}

/// Parse a JSON byte slice directly into type `T`.
/// Allocates only for slices, strings, and nested pointers.
/// Free the result with `parseFree(T, allocator, value)`.
pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try Tokenizer.init(input);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    tok.pos = tok.scanner.nextNonSpace(input, tok.pos);
    if (tok.pos < input.len) return error.UnexpectedToken;
    return v;
}

/// Free memory allocated by `parseFromSlice` for value of type `T`.
pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
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

fn parseNumber(t: tokenizer_mod.Token) Error!Value {
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

pub fn freeTyped(comptime T: type, allocator: Allocator, value: T) void {
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
