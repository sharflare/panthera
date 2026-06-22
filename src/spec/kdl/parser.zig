const std = @import("std");
const eql = std.mem.eql;
const Allocator = std.mem.Allocator;

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");
const tokenizer_mod = @import("tokenizer.zig");

const Error = types.Error;
const ParseOptions = types.ParseOptions;
const Value = types.Value;
const ObjectMap = types.ObjectMap;
const Array = types.Array;
const MAX_DEPTH = types.MAX_DEPTH;

const simdParseU64Decimal = simd.simdParseU64Decimal;
const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

const KdlTokenizer = tokenizer_mod.KdlTokenizer;
const TokenTag = tokenizer_mod.TokenTag;

const MAX_FIELD_NAME: usize = 4096;

pub fn decodeString(raw: []const u8, out: []u8) Error![]u8 {
    if (raw.len < 2 or raw[0] != '"' or raw[raw.len - 1] != '"')
        return error.InvalidCharacter;
    const inner = raw[1 .. raw.len - 1];
    var src: usize = 0;
    var dst: usize = 0;
    const N = comptime laneN();
    const bs_splat: LaneVec() = @splat(@as(u8, '\\'));

    while (src < inner.len) {
        if (src + N <= inner.len) {
            const chunk: LaneVec() = inner[src..][0..N].*;
            const hit = chunk == bs_splat;
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
        } else {
            while (src < inner.len and inner[src] != '\\') {
                out[dst] = inner[src];
                src += 1;
                dst += 1;
            }
            if (src >= inner.len) break;
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
            's' => {
                out[dst] = ' ';
                src += 1;
                dst += 1;
            },
            'u' => {
                src += 1;
                if (src >= inner.len or inner[src] != '{') {
                    if (src + 4 > inner.len) return error.InvalidEscape;
                    const cp = parseHex4(inner[src..][0..4]) catch return error.InvalidEscape;
                    src += 4;
                    dst += std.unicode.utf8Encode(@intCast(cp), out[dst..]) catch return error.InvalidEscape;
                } else {
                    src += 1;
                    const end_brace = std.mem.indexOfScalarPos(u8, inner, src, '}') orelse return error.InvalidEscape;
                    const hex_str = inner[src..end_brace];
                    if (hex_str.len == 0 or hex_str.len > 6) return error.InvalidEscape;
                    const codepoint = std.fmt.parseInt(u21, hex_str, 16) catch return error.InvalidEscape;
                    if (codepoint > 0x10FFFF) return error.InvalidEscape;
                    if (codepoint >= 0xD800 and codepoint <= 0xDFFF) return error.InvalidEscape;
                    dst += std.unicode.utf8Encode(@intCast(codepoint), out[dst..]) catch return error.InvalidEscape;
                    src = end_brace + 1;
                }
            },
            '\n' => {
                src += 1;
                while (src < inner.len and (inner[src] == ' ' or inner[src] == '\t')) src += 1;
            },
            '\r' => {
                src += 1;
                if (src < inner.len and inner[src] == '\n') src += 1;
            },
            ' ' => {
                src += 1;
                while (src < inner.len and inner[src] == ' ') src += 1;
            },
            else => return error.InvalidEscape,
        }
    }
    return out[0..dst];
}

fn parseHex4(s: []const u8) Error!u16 {
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

fn needEscapeDecode(raw: []const u8) bool {
    return raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"' and
        (std.mem.indexOfScalar(u8, raw, '\\') != null);
}

pub fn allocDecodeString(allocator: Allocator, raw: []const u8) Error![]const u8 {
    if (raw.len < 2) return error.InvalidCharacter;
    if (raw[0] == '"' and raw[raw.len - 1] == '"') {
        if (std.mem.indexOfScalar(u8, raw, '\\') == null) {
            const inner = raw[1 .. raw.len - 1];
            return allocator.dupe(u8, inner);
        }
        const buf = try allocator.alloc(u8, raw.len);
        errdefer allocator.free(buf);
        const decoded = try decodeString(raw, buf);
        const n = decoded.len;
        if (n < buf.len) {
            const tight = try allocator.alloc(u8, n);
            @memcpy(tight, decoded);
            allocator.free(buf);
            return tight;
        }
        return buf;
    }
    return allocator.dupe(u8, raw);
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
        if (comptimeFieldHash(field.name) == h and eql(u8, key, field.name)) return i;
    }
    return null;
}

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try KdlTokenizer.init(input);
    const v = try parseDocument(allocator, &tok, 0);
    try tok.skipWhitespaceAndComments();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try KdlTokenizer.init(input);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    try tok.skipWhitespaceAndComments();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
}

fn parseDocument(allocator: Allocator, tok: *KdlTokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    var nodes = Array.empty;
    errdefer {
        for (nodes.items) |*item| item.deinit(allocator);
        nodes.deinit(allocator);
    }
    try nodes.ensureTotalCapacity(allocator, 32);

    try tok.skipWhitespaceAndComments();
    while (!tok.atEnd()) {
        const peek_c = tok.peek();
        if (peek_c == '{' or peek_c == '}' or peek_c == ';') break;
        const node = try parseNode(allocator, tok, depth + 1);
        nodes.appendAssumeCapacity(node);
        try tok.skipWhitespaceAndComments();
        if (tok.peek() == ';') {
            tok.pos += 1;
            try tok.skipWhitespaceAndComments();
        }
    }

    return .{ .array = nodes };
}

fn parseNode(allocator: Allocator, tok: *KdlTokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;

    var type_annotation: ?[]const u8 = null;
    if (tok.peek() == '(') {
        const ta_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        if (ta_tok.tag != .type_annotation) return error.UnexpectedToken;
        type_annotation = std.mem.trim(u8, ta_tok.slice, "()");
    }

    try tok.skipWhitespaceAndComments();
    const name_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    const name: []const u8 = switch (name_tok.tag) {
        .node_name => name_tok.slice,
        .string => name_tok.slice,
        .number, .boolean, .null_lit => name_tok.slice,
        else => return error.UnexpectedToken,
    };

    var args = Array.empty;
    errdefer {
        for (args.items) |*item| item.deinit(allocator);
        args.deinit(allocator);
    }
    try args.ensureTotalCapacity(allocator, 8);

    var props = ObjectMap{};
    errdefer {
        var it = props.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        props.deinit(allocator);
    }
    try props.ensureTotalCapacity(allocator, 8);

    var children: ?Value = null;

    while (true) {
        try tok.skipInline();
        if (tok.atEnd()) break;

        const c = tok.peek();
        if (c == ';') break;
        if (c == '\n' or c == '\r') {
            tok.skipNewline();
            break;
        }
        if (c == '}' or c == ')' or c == ']') break;
        if (c == '/') {
            if (tok.peekN(1) == '/' or tok.peekN(1) == '*' or tok.peekN(1) == '-') break;
        }
        if (c == '\\') {
            tok.skipLineContinuation();
            continue;
        }

        if (c == '{') {
            tok.pos += 1;
            children = try parseDocument(allocator, tok, depth + 1);
            try tok.skipWhitespaceAndComments();
            if (tok.peek() != '}') return error.UnexpectedToken;
            tok.pos += 1;
            break;
        }

        _ = if (tok.peek() == '(') blk: {
            const ta_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (ta_tok.tag != .type_annotation) return error.UnexpectedToken;
            try tok.skipInline();
            break :blk std.mem.trim(u8, ta_tok.slice, "()");
        } else null;

        const item_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;

        try tok.skipInline();
        if (tok.peek() == '=') {
            tok.pos += 1;
            try tok.skipInline();
            const val_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            const val = try inferValueFromToken(val_tok, allocator);
            const key = try getTokenName(item_tok, allocator);
            const gop = try props.getOrPut(allocator, key);
            if (gop.found_existing) {
                allocator.free(key);
                gop.value_ptr.deinit(allocator);
            }
            gop.value_ptr.* = val;
        } else {
            const val = try inferValueFromToken(item_tok, allocator);
            args.appendAssumeCapacity(val);
        }
    }

    const name_alloc = try allocator.dupe(u8, name);
    var node_obj = ObjectMap{};
    errdefer {
        allocator.free(name_alloc);
        var it = node_obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        node_obj.deinit(allocator);
    }
    const cap_extra: u32 = if (type_annotation != null) 1 else 0;
    try node_obj.ensureTotalCapacity(allocator, cap_extra + 4);
    node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "name"), Value{ .string = name_alloc });
    node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "args"), Value{ .array = args });
    node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "props"), Value{ .object = props });

    if (type_annotation) |ta| {
        node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "type"), Value{ .string = try allocator.dupe(u8, ta) });
    }

    if (children) |ch| {
        node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "children"), ch);
    } else {
        node_obj.putAssumeCapacityNoClobber(try allocator.dupe(u8, "children"), Value{ .array = Array.empty });
    }

    return .{ .object = node_obj };
}

fn getTokenName(tok: tokenizer_mod.Token, allocator: Allocator) Error![]const u8 {
    return switch (tok.tag) {
        .node_name => allocator.dupe(u8, tok.slice),
        .string => allocDecodeString(allocator, tok.slice),
        .number, .boolean, .null_lit => allocator.dupe(u8, tok.slice),
        else => error.UnexpectedToken,
    };
}

fn inferValueFromToken(tok: tokenizer_mod.Token, allocator: Allocator) Error!Value {
    return switch (tok.tag) {
        .null_lit => Value{ .null = {} },
        .boolean => Value{ .bool = eql(u8, tok.slice, "#true") },
        .number => parseNumberToken(tok, allocator),
        .string => {
            if (tok.slice.len >= 2 and tok.slice[0] == '"' and tok.slice[tok.slice.len - 1] == '"') {
                if (tok.slice.len >= 6 and tok.slice[0..3].len == 3 and
                    eql(u8, tok.slice[0..3], "\"\"\""))
                {
                    const decoded = try allocDecodeString(allocator, tok.slice);
                    return Value{ .string = decoded };
                }
                return Value{ .string = try allocDecodeString(allocator, tok.slice) };
            }
            if (tok.slice.len >= 4 and tok.slice[0] == '#') {
                const open_quote = std.mem.indexOfScalar(u8, tok.slice, '"') orelse return error.InvalidCharacter;
                const close_quote = std.mem.lastIndexOfScalar(u8, tok.slice, '"') orelse return error.InvalidCharacter;
                if (close_quote <= open_quote) return error.InvalidCharacter;
                return Value{ .string = try allocator.dupe(u8, tok.slice[open_quote + 1 .. close_quote]) };
            }
            return Value{ .string = try allocator.dupe(u8, tok.slice) };
        },
        .node_name => Value{ .string = try allocator.dupe(u8, tok.slice) },
        .keyword_number => {
            if (eql(u8, tok.slice, "#inf")) return Value{ .float = std.math.inf(f64) };
            if (eql(u8, tok.slice, "#-inf")) return Value{ .float = -std.math.inf(f64) };
            return Value{ .float = std.math.nan(f64) };
        },
        else => error.UnexpectedToken,
    };
}

pub fn inferValue(tok: tokenizer_mod.Token, allocator: Allocator) Error!Value {
    return inferValueFromToken(tok, allocator);
}

fn parseNumberToken(tok: tokenizer_mod.Token, allocator: Allocator) Error!Value {
    const raw = tok.slice;
    if (raw.len == 0) return error.InvalidNumber;
    if (tok.is_float) {
        if (raw[0] == '#') {
            if (eql(u8, raw, "#inf")) return Value{ .float = std.math.inf(f64) };
            if (eql(u8, raw, "#-inf")) return Value{ .float = -std.math.inf(f64) };
            return Value{ .float = std.math.nan(f64) };
        }
        var fbuf: [128]u8 = undefined;
        const fclean = stripUnderscores(raw, &fbuf);
        return Value{ .float = std.fmt.parseFloat(f64, fclean) catch return Value{ .number_string = try allocator.dupe(u8, raw) } };
    }
    if (raw.len > 2 and raw[0] == '0') {
        switch (raw[1]) {
            'x', 'X', 'o', 'O', 'b', 'B' => {
                if (parseNonDecimal(raw)) |v| return Value{ .integer = v };
                return Value{ .number_string = try allocator.dupe(u8, raw) };
            },
            else => {},
        }
    }
    var clean_buf: [64]u8 = undefined;
    const clean = stripUnderscores(raw, &clean_buf);

    if (clean[0] != '-') {
        if (simdParseU64Decimal(clean)) |u| {
            if (u <= std.math.maxInt(i64))
                return Value{ .integer = @intCast(u) };
        }
    } else if (clean.len > 1) {
        if (simdParseU64Decimal(clean[1..])) |u| {
            if (u > 0 and u <= @as(u64, @intCast(std.math.maxInt(i64))) + 1)
                return Value{ .integer = -@as(i64, @intCast(u)) };
        }
    }
    return Value{ .number_string = try allocator.dupe(u8, raw) };
}

fn parseNonDecimal(raw: []const u8) ?i64 {
    if (raw.len < 3) return null;
    const inner = raw[2..];
    if (std.mem.indexOfScalar(u8, inner, '_')) |_| {
        var filtered: [128]u8 = undefined;
        var j: usize = 0;
        for (inner) |c| {
            if (c != '_') {
                if (j >= filtered.len) return null;
                filtered[j] = c;
                j += 1;
            }
        }
        const cleaned = filtered[0..j];
        return switch (raw[1]) {
            'x', 'X' => std.fmt.parseInt(i64, cleaned, 16) catch null,
            'o', 'O' => std.fmt.parseInt(i64, cleaned, 8) catch null,
            'b', 'B' => std.fmt.parseInt(i64, cleaned, 2) catch null,
            else => null,
        };
    }
    return switch (raw[1]) {
        'x', 'X' => std.fmt.parseInt(i64, inner, 16) catch null,
        'o', 'O' => std.fmt.parseInt(i64, inner, 8) catch null,
        'b', 'B' => std.fmt.parseInt(i64, inner, 2) catch null,
        else => null,
    };
}

fn parseTyped(comptime T: type, allocator: Allocator, tok: *KdlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    if (depth > opts.max_depth) return error.MaxDepthExceeded;
    switch (@typeInfo(T)) {
        .bool => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            return switch (t.tag) {
                .boolean => eql(u8, t.slice, "#true"),
                .node_name => {
                    if (eql(u8, t.slice, "true")) return true;
                    if (eql(u8, t.slice, "false")) return false;
                    return error.TypeMismatch;
                },
                else => error.TypeMismatch,
            };
        },
        .int => |int| {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .number) return error.TypeMismatch;
            if (!t.is_float and t.slice.len > 0 and t.slice[0] != '#') {
                if (t.slice[0] != '-') {
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
            var num_buf: [128]u8 = undefined;
            const cleaned = stripUnderscores(t.slice, &num_buf);
            const i = std.fmt.parseInt(i64, cleaned, 10) catch return error.InvalidNumber;
            if (int.signedness == .unsigned and i < 0) return error.Overflow;
            return std.math.cast(T, i) orelse error.Overflow;
        },
        .float => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .number) return error.TypeMismatch;
            var num_buf: [128]u8 = undefined;
            const cleaned = stripUnderscores(t.slice, &num_buf);
            return std.fmt.parseFloat(T, cleaned) catch error.InvalidNumber;
        },
        .optional => |opt| {
            const p = tok.peek();
            if (p == '#') {
                const saved = tok.pos;
                tok.pos += 1;
                if (tok.pos < tok.input.len and tok.pos + 3 < tok.input.len and
                    eql(u8, tok.input[tok.pos..][0..4], "null") and
                    (tok.pos + 4 >= tok.input.len or isDelimiter(tok.input[tok.pos + 4])))
                {
                    tok.pos += 4;
                    return null;
                }
                tok.pos = saved;
            }
            if (p == 'n') {
                const saved = tok.pos;
                const ident_tok = try tok.scanIdentifier();
                if (ident_tok.tag == .node_name and eql(u8, ident_tok.slice, "null")) {
                    return null;
                }
                tok.pos = saved;
            }
            return try parseTyped(opt.child, allocator, tok, opts, depth);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                return switch (t.tag) {
                    .string => allocDecodeString(allocator, t.slice),
                    .node_name => allocator.dupe(u8, t.slice),
                    else => error.TypeMismatch,
                };
            }
            if (ptr.size == .slice) return parseTypedSlice(ptr.child, allocator, tok, opts, depth);
            @compileError("panthera: unsupported pointer type " ++ @typeName(T));
        },
        .array => |arr| {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (t.tag != .open_brace) return error.TypeMismatch;
            var result: T = undefined;
            for (0..arr.len) |i| {
                if (i > 0) {
                    try tok.skipWhitespaceAndComments();
                }
                result[i] = try parseTyped(arr.child, allocator, tok, opts, depth + 1);
            }
            const cl = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            if (cl.tag != .close_brace) return error.UnexpectedToken;
            return result;
        },
        .@"struct" => |st| return parseTypedStruct(T, st, allocator, tok, opts, depth),
        .@"union" => return parseTypedUnion(T, allocator, tok, opts, depth),
        .@"enum" => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            var buf: [MAX_FIELD_NAME]u8 = undefined;
            const name = switch (t.tag) {
                .node_name => t.slice,
                .string => try decodeString(t.slice, &buf),
                else => return error.TypeMismatch,
            };
            return std.meta.stringToEnum(T, name) orelse error.TypeMismatch;
        },
        else => @compileError("panthera: unsupported type " ++ @typeName(T)),
    }
}

fn parseTypedSlice(comptime Child: type, allocator: Allocator, tok: *KdlTokenizer, opts: ParseOptions, depth: u32) Error![]Child {
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (t.tag != .open_brace) return error.TypeMismatch;
    var list: std.ArrayListUnmanaged(Child) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (list.items) |*i| freeTyped(Child, allocator, i.*);
        list.deinit(allocator);
    }
    try list.ensureTotalCapacity(allocator, 32);
    var first = true;
    while (true) {
        try tok.skipWhitespaceAndComments();
        if (first) {
            first = false;
            if (tok.peek() == '}') {
                tok.pos += 1;
                break;
            }
        } else {
            if (tok.peek() == '}') {
                tok.pos += 1;
                break;
            }
            if (tok.peek() == ';') {
                tok.pos += 1;
                try tok.skipWhitespaceAndComments();
                if (tok.peek() == '}') {
                    tok.pos += 1;
                    break;
                }
            }
        }
        try list.append(allocator, try parseTyped(Child, allocator, tok, opts, depth + 1));
    }
    return list.toOwnedSlice(allocator);
}

fn parseTypedStruct(
    comptime T: type,
    comptime st: std.builtin.Type.Struct,
    allocator: Allocator,
    tok: *KdlTokenizer,
    opts: ParseOptions,
    depth: u32,
) Error!T {
    var result: T = undefined;
    var filled = [_]bool{false} ** st.fields.len;
    var kbuf: [MAX_FIELD_NAME]u8 = undefined;

    try tok.skipWhitespaceAndComments();
    var first = true;
    while (true) {
        try tok.skipWhitespaceAndComments();
        if (tok.atEnd()) break;
        if (first) {
            first = false;
        } else {
            if (tok.peek() == ';') {
                tok.pos += 1;
                try tok.skipWhitespaceAndComments();
                if (tok.atEnd()) break;
            }
            if (tok.peek() == '}') {
                tok.pos += 1;
                break;
            }
        }

        const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        const key = switch (kt.tag) {
            .node_name => kt.slice,
            .string => try decodeString(kt.slice, &kbuf),
            else => return error.UnexpectedToken,
        };

        try tok.skipWhitespaceAndComments();
        if (tok.peek() == '=') {
            tok.pos += 1;
            try tok.skipWhitespaceAndComments();
        }

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

fn parseTypedUnion(comptime T: type, allocator: Allocator, tok: *KdlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    var kbuf: [256]u8 = undefined;
    const key = switch (kt.tag) {
        .node_name => kt.slice,
        .string => try decodeString(kt.slice, &kbuf),
        else => return error.UnexpectedToken,
    };

    try tok.skipWhitespaceAndComments();
    if (tok.peek() == '=') {
        tok.pos += 1;
        try tok.skipWhitespaceAndComments();
    }

    inline for (@typeInfo(T).@"union".fields) |field| {
        if (eql(u8, key, field.name)) {
            const v = try parseTyped(field.type, allocator, tok, opts, depth + 1);
            return @unionInit(T, field.name, v);
        }
    }
    return error.UnknownField;
}

fn skipValue(tok: *KdlTokenizer, depth: u32) Error!void {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    _ = t;
}

fn stripUnderscores(raw: []const u8, buf: []u8) []const u8 {
    if (std.mem.indexOfScalar(u8, raw, '_') == null) return raw;
    var j: usize = 0;
    for (raw) |c| {
        if (c != '_') {
            if (j >= buf.len) return raw;
            buf[j] = c;
            j += 1;
        }
    }
    return buf[0..j];
}

fn isDelimiter(c: u8) bool {
    return switch (c) {
        ' ', '\t', '\n', '\r', '(', ')', '{', '}', '/', '\\', '"', ';', '=' => true,
        else => false,
    };
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
