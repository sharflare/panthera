//! Panthera — SIMD accelerated JSON serializer for zig
//! drop in replacement for std.json

const std = @import("std");
const builtin = @import("builtin");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;

// --- limits ---

pub const MAX_DEPTH: u32 = 128;
pub const MAX_TOKEN_LEN: usize = 1 << 20;
pub const MAX_INPUT_BYTES: usize = 1 << 30;

// --- errors ---

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

// --- options ---

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

// --- value ---

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

// --- simd ---

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

fn simdN() comptime_int {
    return switch (SIMD_WIDTH) {
        .avx2 => 32,
        .sse2, .neon => 16,
        .scalar => 1,
    };
}

fn MaskInt() type {
    return switch (SIMD_WIDTH) {
        .avx2 => u32,
        .sse2, .neon => u16,
        .scalar => u8,
    };
}

fn Vec() type {
    return @Vector(simdN(), u8);
}

// --- skipWhitespace ---

fn skipWhitespace(hay: []const u8, pos: usize) usize {
    assert(pos <= hay.len);
    var i = pos;
    const N = comptime simdN();
    if (SIMD_WIDTH != .scalar) {
        const sp: Vec() = @splat(' ');
        const tab: Vec() = @splat('\t');
        const lf: Vec() = @splat('\n');
        const cr: Vec() = @splat('\r');
        while (i + N <= hay.len) : (i += N) {
            const c: Vec() = hay[i..][0..N].*;
            const ws = (c == sp) | (c == tab) | (c == lf) | (c == cr);
            const not_ws = ~@as(MaskInt(), @bitCast(@intFromBool(ws)));
            if (not_ws != 0) return i + @ctz(not_ws);
        }
    }
    while (i < hay.len) : (i += 1) {
        switch (hay[i]) {
            ' ', '\t', '\n', '\r' => {},
            else => return i,
        }
    }
    return hay.len;
}

// --- findStringEnd ---

fn findStringEnd(hay: []const u8, pos: usize) usize {
    assert(pos <= hay.len);
    var i = pos;
    const N = comptime simdN();
    if (SIMD_WIDTH != .scalar) {
        const dq: Vec() = @splat('"');
        const bs: Vec() = @splat('\\');
        while (i + N <= hay.len) : (i += N) {
            const c: Vec() = hay[i..][0..N].*;
            const mask: MaskInt() = @bitCast(@intFromBool((c == dq) | (c == bs)));
            if (mask != 0) return i + @ctz(mask);
        }
    }
    while (i < hay.len) : (i += 1) {
        if (hay[i] == '"' or hay[i] == '\\') return i;
    }
    return hay.len;
}

// --- findNumberEnd ---

fn findNumberEnd(hay: []const u8, pos: usize) usize {
    assert(pos <= hay.len);
    var i = pos;
    const N = comptime simdN();
    if (SIMD_WIDTH != .scalar) {
        const z0: Vec() = @splat('0');
        const z9: Vec() = @splat('9');
        const dt: Vec() = @splat('.');
        const el: Vec() = @splat('e');
        const eu: Vec() = @splat('E');
        const pl: Vec() = @splat('+');
        const mn: Vec() = @splat('-');
        while (i + N <= hay.len) : (i += N) {
            const c: Vec() = hay[i..][0..N].*;
            const is_num =
                ((c >= z0) & (c <= z9)) |
                (c == dt) | (c == el) | (c == eu) | (c == pl) | (c == mn);
            const not_num = ~@as(MaskInt(), @bitCast(@intFromBool(is_num)));
            if (not_num != 0) return i + @ctz(not_num);
        }
    }
    while (i < hay.len) : (i += 1) {
        switch (hay[i]) {
            '0'...'9', '.', 'e', 'E', '+', '-' => {},
            else => return i,
        }
    }
    return i;
}

// --- findEscapeEnd ---

fn findEscapeEnd(s: []const u8, pos: usize, escape_unicode: bool) usize {
    assert(pos <= s.len);
    var i = pos;
    const N = comptime simdN();
    if (SIMD_WIDTH != .scalar) {
        const ctrl: Vec() = @splat(@as(u8, 0x20));
        const dq: Vec() = @splat('"');
        const bs: Vec() = @splat('\\');
        const hi: Vec() = @splat(@as(u8, 0x7E));
        while (i + N <= s.len) : (i += N) {
            const c: Vec() = s[i..][0..N].*;
            var bad = (c < ctrl) | (c == dq) | (c == bs);
            if (escape_unicode) bad = bad | (c > hi);
            const mask: MaskInt() = @bitCast(@intFromBool(bad));
            if (mask != 0) return i + @ctz(mask);
        }
    }
    while (i < s.len) : (i += 1) {
        const b = s[i];
        if (b < 0x20 or b == '"' or b == '\\') return i;
        if (escape_unicode and b > 0x7E) return i;
    }
    return s.len;
}

// --- token ---

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
};

// --- tokenizer ---

const Tokenizer = struct {
    input: []const u8,
    pos: usize,

    fn init(input: []const u8) Error!Tokenizer {
        if (input.len > MAX_INPUT_BYTES) return error.InputTooLarge;
        return .{ .input = input, .pos = 0 };
    }

    fn peek(self: *Tokenizer) ?u8 {
        self.pos = skipWhitespace(self.input, self.pos);
        return if (self.pos < self.input.len) self.input[self.pos] else null;
    }

    fn next(self: *Tokenizer) Error!?Token {
        self.pos = skipWhitespace(self.input, self.pos);
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
        var accum: usize = 0;
        while (self.pos < self.input.len and accum <= MAX_TOKEN_LEN) {
            const end = findStringEnd(self.input, self.pos);
            accum += end - self.pos;
            self.pos = end;
            if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
            if (accum > MAX_TOKEN_LEN) return error.TokenTooLong;
            if (self.input[self.pos] == '"') {
                self.pos += 1;
                return .{ .tag = .string, .slice = self.input[start..self.pos] };
            }
            self.pos += 1; // backslash
            if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
            const esc = self.input[self.pos];
            self.pos += 1;
            switch (esc) {
                '"', '\\', '/', 'b', 'f', 'n', 'r', 't' => accum += 2,
                'u' => {
                    if (self.pos + 4 > self.input.len) return error.UnexpectedEndOfInput;
                    inline for (0..4) |_| {
                        switch (self.input[self.pos]) {
                            '0'...'9', 'a'...'f', 'A'...'F' => self.pos += 1,
                            else => return error.InvalidEscape,
                        }
                    }
                    accum += 6;
                },
                else => return error.InvalidEscape,
            }
        }
        return error.TokenTooLong;
    }

    fn scanNumber(self: *Tokenizer) Error!Token {
        const start = self.pos;
        if (self.input[self.pos] == '-') self.pos += 1;
        if (self.pos >= self.input.len) return error.UnexpectedEndOfInput;
        if (self.input[self.pos] == '0') {
            self.pos += 1;
        } else if (self.input[self.pos] >= '1' and self.input[self.pos] <= '9') {
            self.pos = findNumberEnd(self.input, self.pos);
        } else return error.InvalidNumber;
        if (self.pos < self.input.len and self.input[self.pos] == '.') {
            self.pos += 1;
            const before = self.pos;
            self.pos = findNumberEnd(self.input, self.pos);
            if (self.pos == before) return error.InvalidNumber;
        }
        if (self.pos < self.input.len and
            (self.input[self.pos] == 'e' or self.input[self.pos] == 'E'))
        {
            self.pos += 1;
            if (self.pos < self.input.len and
                (self.input[self.pos] == '+' or self.input[self.pos] == '-'))
                self.pos += 1;
            const before = self.pos;
            self.pos = findNumberEnd(self.input, self.pos);
            if (self.pos == before) return error.InvalidNumber;
        }
        const sl = self.input[start..self.pos];
        if (sl.len > MAX_TOKEN_LEN) return error.TokenTooLong;
        return .{ .tag = .number, .slice = sl };
    }

    fn literal(self: *Tokenizer, comptime word: []const u8, tag: TokenTag) Error!Token {
        if (self.pos + word.len > self.input.len) return error.UnexpectedEndOfInput;
        if (!std.mem.eql(u8, self.input[self.pos .. self.pos + word.len], word))
            return error.UnexpectedToken;
        defer self.pos += word.len;
        return .{ .tag = tag, .slice = self.input[self.pos .. self.pos + word.len] };
    }
};

// --- string decode ---

fn decodeString(raw: []const u8, out: []u8) Error![]u8 {
    assert(raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"');
    const inner = raw[1 .. raw.len - 1];
    var src: usize = 0;
    var dst: usize = 0;
    while (src < inner.len) {
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
    const buf = try allocator.alloc(u8, raw.len);
    errdefer allocator.free(buf);
    const decoded = try decodeString(raw, buf);
    if (decoded.len < buf.len) return allocator.realloc(buf, decoded.len);
    return buf;
}

// --- dynamic value parser ---

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try Tokenizer.init(input);
    const v = try parseValueInner(allocator, &tok, 0);
    if (skipWhitespace(input, tok.pos) < input.len) return error.UnexpectedToken;
    return v;
}

fn parseValueInner(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    return switch (t.tag) {
        .null_lit => .null,
        .true_lit => .{ .bool = true },
        .false_lit => .{ .bool = false },
        .number => parseNumber(t.slice),
        .string => .{ .string = try allocDecodeString(allocator, t.slice) },
        .array_begin => try parseArray(allocator, tok, depth + 1),
        .object_begin => try parseObject(allocator, tok, depth + 1),
        else => error.UnexpectedToken,
    };
}

fn parseNumber(raw: []const u8) Error!Value {
    if (std.fmt.parseInt(i64, raw, 10)) |i| return .{ .integer = i } else |_| {}
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
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        const p = tok.peek() orelse return error.UnexpectedEndOfInput;
        if (p == ']') {
            tok.pos += 1;
            return .{ .array = arr };
        }
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
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
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        const p = tok.peek() orelse return error.UnexpectedEndOfInput;
        if (p == '}') {
            tok.pos += 1;
            return .{ .object = obj };
        }
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag != .comma) return error.UnexpectedToken;
        }
        const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (kt.tag != .string) return error.UnexpectedToken;
        const key = try allocDecodeString(allocator, kt.slice);
        errdefer allocator.free(key);
        const colon = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (colon.tag != .colon) return error.UnexpectedToken;
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

// --- typed parse ---

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try Tokenizer.init(input);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    if (skipWhitespace(input, tok.pos) < input.len) return error.UnexpectedToken;
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
                return allocDecodeString(allocator, t.slice);
            }
            if (ptr.size == .Slice) return parseTypedSlice(ptr.child, allocator, tok, opts, depth);
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
            var buf: [MAX_TOKEN_LEN]u8 = undefined;
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
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        const p = tok.peek() orelse return error.UnexpectedEndOfInput;
        if (p == ']') {
            tok.pos += 1;
            break;
        }
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag != .comma) return error.UnexpectedToken;
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
    var n: usize = 0;
    while (n <= MAX_INPUT_BYTES) : (n += 1) {
        const p = tok.peek() orelse return error.UnexpectedEndOfInput;
        if (p == '}') {
            tok.pos += 1;
            break;
        }
        if (n > 0) {
            const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (c.tag != .comma) return error.UnexpectedToken;
        }
        const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (kt.tag != .string) return error.UnexpectedToken;
        var kbuf: [MAX_TOKEN_LEN]u8 = undefined;
        const key = try decodeString(kt.slice, &kbuf);
        const colon = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (colon.tag != .colon) return error.UnexpectedToken;
        var matched = false;
        inline for (st.fields, 0..) |field, fi| {
            if (std.mem.eql(u8, key, field.name)) {
                if (filled[fi] and opts.duplicate_field_behavior == .reject)
                    return error.DuplicateField;
                @field(result, field.name) = try parseTyped(field.type, allocator, tok, opts, depth + 1);
                filled[fi] = true;
                matched = true;
                break;
            }
        }
        if (!matched) {
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
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    switch (t.tag) {
        .null_lit, .true_lit, .false_lit, .number, .string => {},
        .array_begin => {
            var n: usize = 0;
            while (n <= MAX_INPUT_BYTES) : (n += 1) {
                const p = tok.peek() orelse return error.UnexpectedEndOfInput;
                if (p == ']') {
                    tok.pos += 1;
                    return;
                }
                if (n > 0) {
                    const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (c.tag != .comma) return error.UnexpectedToken;
                }
                try skipValue(tok, depth + 1);
            }
        },
        .object_begin => {
            var n: usize = 0;
            while (n <= MAX_INPUT_BYTES) : (n += 1) {
                const p = tok.peek() orelse return error.UnexpectedEndOfInput;
                if (p == '}') {
                    tok.pos += 1;
                    return;
                }
                if (n > 0) {
                    const c = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (c.tag != .comma) return error.UnexpectedToken;
                }
                _ = try tok.next();
                const col = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                if (!std.mem.eql(u8, col.slice, ":")) return error.UnexpectedToken;
                try skipValue(tok, depth + 1);
            }
        },
        .colon, .comma, .object_end, .array_end => return error.UnexpectedToken,
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

// --- stringify ---

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

        fn write(self: *Self, value: anytype) !void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .null => try self.writer.writeAll("null"),
                .bool => try self.writer.writeAll(if (value) "true" else "false"),
                .int, .comptime_int => {
                    var buf: [32]u8 = undefined;
                    try self.writer.writeAll(std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable);
                },
                .float, .comptime_float => {
                    var buf: [64]u8 = undefined;
                    try self.writer.writeAll(std.fmt.bufPrint(&buf, "{}", .{value}) catch unreachable);
                },
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
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    var first = true;
                    inline for (st.fields) |field| {
                        const fv = @field(value, field.name);
                        if (!self.opts.emit_null_optional_fields and
                            @typeInfo(field.type) == .optional and fv == null) continue;
                        if (!first) try self.writer.writeByte(',');
                        first = false;
                        try self.indent();
                        try self.writer.writeByte('"');
                        try self.writeEscaped(field.name);
                        try self.writer.writeAll("\":");
                        if (self.opts.whitespace != null) try self.writer.writeByte(' ');
                        try self.write(fv);
                    }
                    self.depth -= 1;
                    if (!first) try self.indent();
                    try self.writer.writeByte('}');
                },
                .@"union" => |un| {
                    if (T == Value) {
                        try self.writeValue(value);
                        return;
                    }
                    if (un.tag_type == null) @compileError("panthera: bare union not supported");
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    try self.indent();
                    try self.writer.writeByte('"');
                    try self.writeEscaped(@tagName(value));
                    try self.writer.writeAll("\":");
                    if (self.opts.whitespace != null) try self.writer.writeByte(' ');
                    switch (value) {
                        inline else => |pl| try self.write(pl),
                    }
                    self.depth -= 1;
                    try self.indent();
                    try self.writer.writeByte('}');
                },
                else => @compileError("panthera stringify: unsupported type " ++ @typeName(T)),
            }
        }

        fn writeValue(self: *Self, v: Value) !void {
            switch (v) {
                .null => try self.writer.writeAll("null"),
                .bool => |b| try self.writer.writeAll(if (b) "true" else "false"),
                .integer => |i| {
                    var buf: [32]u8 = undefined;
                    try self.writer.writeAll(std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable);
                },
                .float => |f| {
                    var buf: [64]u8 = undefined;
                    try self.writer.writeAll(std.fmt.bufPrint(&buf, "{}", .{f}) catch unreachable);
                },
                .number_string => |s| try self.writer.writeAll(s),
                .string => |s| {
                    try self.writer.writeByte('"');
                    try self.writeEscaped(s);
                    try self.writer.writeByte('"');
                },
                .array => |a| {
                    try self.writer.writeByte('[');
                    self.depth += 1;
                    for (a.items, 0..) |item, i| {
                        if (i > 0) try self.writer.writeByte(',');
                        try self.indent();
                        try self.writeValue(item);
                    }
                    self.depth -= 1;
                    if (a.items.len > 0) try self.indent();
                    try self.writer.writeByte(']');
                },
                .object => |o| {
                    try self.writer.writeByte('{');
                    self.depth += 1;
                    var it = o.iterator();
                    var first = true;
                    while (it.next()) |entry| {
                        if (!first) try self.writer.writeByte(',');
                        first = false;
                        try self.indent();
                        try self.writer.writeByte('"');
                        try self.writeEscaped(entry.key_ptr.*);
                        try self.writer.writeAll("\":");
                        if (self.opts.whitespace != null) try self.writer.writeByte(' ');
                        try self.writeValue(entry.value_ptr.*);
                    }
                    self.depth -= 1;
                    if (!first) try self.indent();
                    try self.writer.writeByte('}');
                },
            }
        }

        fn writeArray(self: *Self, slice: anytype) !void {
            try self.writer.writeByte('[');
            self.depth += 1;
            for (slice, 0..) |item, i| {
                if (i > 0) try self.writer.writeByte(',');
                try self.indent();
                try self.write(item);
            }
            self.depth -= 1;
            if (slice.len > 0) try self.indent();
            try self.writer.writeByte(']');
        }

        fn indent(self: *Self) !void {
            const sp = self.opts.whitespace orelse return;
            try self.writer.writeByte('\n');
            var i: u32 = 0;
            while (i < self.depth * sp) : (i += 1) try self.writer.writeByte(' ');
        }

        fn writeEscaped(self: *Self, s: []const u8) !void {
            var pos: usize = 0;
            while (pos < s.len) {
                const start = pos;
                pos = findEscapeEnd(s, pos, self.opts.escape_unicode);
                if (pos > start) try self.writer.writeAll(s[start..pos]);
                if (pos >= s.len) break;
                const b = s[pos];
                pos += 1;
                switch (b) {
                    '"' => try self.writer.writeAll("\\\""),
                    '\\' => try self.writer.writeAll("\\\\"),
                    '\n' => try self.writer.writeAll("\\n"),
                    '\r' => try self.writer.writeAll("\\r"),
                    '\t' => try self.writer.writeAll("\\t"),
                    '\x08' => try self.writer.writeAll("\\b"),
                    '\x0C' => try self.writer.writeAll("\\f"),
                    else => {
                        var esc: [6]u8 = undefined;
                        _ = std.fmt.bufPrint(&esc, "\\u{X:0>4}", .{b}) catch unreachable;
                        try self.writer.writeAll(&esc);
                    },
                }
            }
        }
    };
}

// --- juicy main (0.16.0) ---

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const stdout = std.Io.File.stdout();

    const demo =
        \\{"name":"panthera","version":1,"fast":true,"tags":["simd","json","zig"]}
    ;

    var arena = ArenaAllocator.init(gpa);
    defer arena.deinit();
    const aa = arena.allocator();

    var out: [4096]u8 = undefined;

    const v = try parseValue(aa, demo);
    var fbs = std.io.fixedBufferStream(&out);
    try stringify(v, .{ .whitespace = 2 }, fbs.writer());
    try fbs.writer().writeByte('\n');
    try stdout.writeStreamingAll(io, fbs.getWritten());

    const Demo = struct { name: []const u8, version: u32, fast: bool, tags: [][]const u8 };
    var fbs2 = std.io.fixedBufferStream(&out);
    try stringify(try parseFromSlice(Demo, aa, demo, .{}), .{ .whitespace = 2 }, fbs2.writer());
    try fbs2.writer().writeByte('\n');
    try stdout.writeStreamingAll(io, fbs2.getWritten());

    try stdout.writeStreamingAll(io, switch (SIMD_WIDTH) {
        .avx2 => "simd: AVX2 (32 bytes)\n",
        .sse2 => "simd: SSE2 (16 bytes)\n",
        .neon => "simd: NEON (16 bytes)\n",
        .scalar => "simd: scalar\n",
    });
}

// --- tests ---

test "skipWhitespace: all" {
    try std.testing.expectEqual(@as(usize, 6), skipWhitespace("   \t\n\r", 0));
}
test "skipWhitespace: mixed" {
    try std.testing.expectEqual(@as(usize, 2), skipWhitespace("  hello", 0));
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
