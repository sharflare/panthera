const std = @import("std");
const assert = std.debug.assert;
const Allocator = std.mem.Allocator;

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");
const tokenizer = @import("tokenizer.zig");

const Error = types.Error;
const ParseOptions = types.ParseOptions;
const Value = types.Value;
const ObjectMap = types.ObjectMap;
const Array = types.Array;

const simdParseU64Decimal = simd.simdParseU64Decimal;

const YamlTokenizer = tokenizer.YamlTokenizer;
const fnv1aHash = tokenizer.fnv1aHash;
const fieldHash = tokenizer.fieldHash;
const fieldIdx = tokenizer.fieldIdx;

const MAX_FIELD_NAME: usize = 4096;

fn infer(raw: []const u8, allocator: Allocator) Error!Value {
    if (std.mem.eql(u8, raw, "null") or std.mem.eql(u8, raw, "~") or
        std.mem.eql(u8, raw, "Null") or std.mem.eql(u8, raw, "NULL"))
        return .null;
    if (std.mem.eql(u8, raw, "true") or std.mem.eql(u8, raw, "True") or std.mem.eql(u8, raw, "TRUE") or
        std.mem.eql(u8, raw, "yes") or std.mem.eql(u8, raw, "Yes") or std.mem.eql(u8, raw, "YES") or
        std.mem.eql(u8, raw, "on") or std.mem.eql(u8, raw, "On") or std.mem.eql(u8, raw, "ON"))
        return .{ .bool = true };
    if (std.mem.eql(u8, raw, "false") or std.mem.eql(u8, raw, "False") or std.mem.eql(u8, raw, "FALSE") or
        std.mem.eql(u8, raw, "no") or std.mem.eql(u8, raw, "No") or std.mem.eql(u8, raw, "NO") or
        std.mem.eql(u8, raw, "off") or std.mem.eql(u8, raw, "Off") or std.mem.eql(u8, raw, "OFF"))
        return .{ .bool = false };

    var is_int = true;
    var is_float = false;
    var has_digits = false;
    for (raw, 0..) |c, i| {
        if (i == 0 and c == '-') continue;
        if (c == '.' or c == 'e' or c == 'E') {
            is_int = false;
            is_float = true;
            continue;
        }
        if (!has_digits and c == '+') continue;
        if (c >= '0' and c <= '9') {
            has_digits = true;
            continue;
        }
        is_int = false;
        is_float = false;
        break;
    }

    if (is_int and has_digits) {
        if (raw.len > 1 and raw[0] == '0' and raw[1] != '.') {} else {
            if (raw[0] != '-') {
                if (simdParseU64Decimal(raw)) |u| {
                    if (u <= std.math.maxInt(i64)) return .{ .integer = @intCast(u) };
                }
            } else if (raw.len > 1) {
                if (simdParseU64Decimal(raw[1..])) |u| {
                    if (u > 0 and u <= @as(u64, @intCast(std.math.maxInt(i64))) + 1)
                        return .{ .integer = -@as(i64, @intCast(u)) };
                }
            }
        }
    }
    if (is_float and has_digits) {
        return .{ .float = try std.fmt.parseFloat(f64, raw) };
    }
    return .{ .string = try allocator.dupe(u8, raw) };
}

fn parseScalar(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    const raw = tok.scanPlain() orelse return error.UnexpectedToken;
    return infer(raw, allocator);
}

fn parseDQStr(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    const bytes = try parseDQRaw(tok, allocator);
    return .{ .string = bytes };
}

fn parseSQStr(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    const bytes = try parseSQRaw(tok, allocator);
    return .{ .string = bytes };
}

fn parseDQRaw(tok: *YamlTokenizer, allocator: Allocator) Error![]const u8 {
    assert(tok.peek() == '"');
    tok.pos += 1;
    const start = tok.pos;
    const N = comptime simd.laneN();
    const dq: simd.LaneVec() = @splat('"');
    const bs: simd.LaneVec() = @splat('\\');

    while (tok.pos < tok.input.len) {
        if (tok.pos + 64 <= tok.input.len) {
            const block: *const [64]u8 = tok.input[tok.pos..][0..64];
            var mask: u64 = 0;
            const iters = 64 / N;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == dq) | (chunk == bs);
                const lm = @as(simd.LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= @as(u64, lm) << (lane * N);
            }
            if (mask == 0) {
                tok.pos += 64;
                continue;
            }
            tok.pos += @ctz(mask);
        }
        if (tok.pos >= tok.input.len) return error.UnexpectedEndOfInput;
        const c = tok.input[tok.pos];
        if (c == '"') {
            const raw = tok.input[start..tok.pos];
            tok.pos += 1;
            const has_bs = for (raw) |b| {
                if (b == '\\') break true;
            } else false;
            if (!has_bs) return allocator.dupe(u8, raw);
            var buf = try allocator.alloc(u8, raw.len);
            errdefer allocator.free(buf);
            var src: usize = 0;
            var dst: usize = 0;
            while (src < raw.len) {
                if (raw[src] != '\\') {
                    buf[dst] = raw[src];
                    src += 1;
                    dst += 1;
                    continue;
                }
                src += 1;
                if (src >= raw.len) return error.InvalidEscape;
                switch (raw[src]) {
                    '"', '\\' => {
                        buf[dst] = raw[src];
                        src += 1;
                        dst += 1;
                    },
                    '/' => {
                        buf[dst] = '/';
                        src += 1;
                        dst += 1;
                    },
                    'b' => {
                        buf[dst] = '\x08';
                        src += 1;
                        dst += 1;
                    },
                    'f' => {
                        buf[dst] = '\x0C';
                        src += 1;
                        dst += 1;
                    },
                    'n' => {
                        buf[dst] = '\n';
                        src += 1;
                        dst += 1;
                    },
                    'r' => {
                        buf[dst] = '\r';
                        src += 1;
                        dst += 1;
                    },
                    't' => {
                        buf[dst] = '\t';
                        src += 1;
                        dst += 1;
                    },
                    '0' => {
                        buf[dst] = 0;
                        src += 1;
                        dst += 1;
                    },
                    else => return error.InvalidEscape,
                }
            }
            if (dst < buf.len) buf = allocator.realloc(buf, dst) catch buf[0..dst];
            return buf;
        }
        if (c == '\\') {
            tok.pos += 2;
            continue;
        }
        tok.pos += 1;
    }
    return error.UnexpectedEndOfInput;
}

fn parseSQRaw(tok: *YamlTokenizer, allocator: Allocator) Error![]const u8 {
    assert(tok.peek() == '\'');
    tok.pos += 1;
    const start = tok.pos;
    var out: std.ArrayListUnmanaged(u8) = .empty;
    errdefer out.deinit(allocator);

    while (tok.pos < tok.input.len) {
        if (tok.pos + 64 <= tok.input.len) {
            const block: *const [64]u8 = tok.input[tok.pos..][0..64];
            const sq: simd.LaneVec() = @splat('\'');
            var mask: u64 = 0;
            const iters = 64 / simd.laneN();
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: simd.LaneVec() = block[lane * simd.laneN() ..][0..simd.laneN()].*;
                const hit = chunk == sq;
                const lm = @as(simd.LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= @as(u64, lm) << (lane * simd.laneN());
            }
            if (mask == 0) {
                tok.pos += 64;
                continue;
            }
            const offset = @ctz(mask);
            const actual = tok.pos + offset;
            if (actual + 1 < tok.input.len and tok.input[actual + 1] == '\'') {
                try out.append(allocator, '\'');
                try out.appendSlice(allocator, tok.input[start..actual]);
                tok.pos = actual + 2;
                continue;
            }
            try out.appendSlice(allocator, tok.input[start..actual]);
            tok.pos = actual + 1;
            return out.toOwnedSlice(allocator);
        }
        if (tok.input[tok.pos] == '\'') {
            if (tok.pos + 1 < tok.input.len and tok.input[tok.pos + 1] == '\'') {
                try out.append(allocator, '\'');
                tok.pos += 2;
                continue;
            }
            try out.appendSlice(allocator, tok.input[start..tok.pos]);
            tok.pos += 1;
            return out.toOwnedSlice(allocator);
        }
        tok.pos += 1;
    }
    return error.UnexpectedEndOfInput;
}

fn parseBlkScalar(tok: *YamlTokenizer, ch: u8, allocator: Allocator) Error!Value {
    const is_literal = ch == '|';
    tok.pos += 1;
    tok.skipLine();
    const base_indent = tok.measureIndent();
    if (tok.atEnd() or tok.peek() == '\n') return .{ .string = try allocator.dupe(u8, "") };

    var result: std.ArrayListUnmanaged(u8) = .empty;
    errdefer result.deinit(allocator);
    var prev_blank = false;
    while (!tok.atEnd()) {
        const indent = tok.measureIndent();
        if (indent < base_indent) break;
        tok.pos += indent;
        const line_start = tok.pos;
        while (tok.pos < tok.input.len and tok.input[tok.pos] != '\n') : (tok.pos += 1) {}

        const is_blank = line_start == tok.pos;
        if (result.items.len > 0) {
            if (is_literal or is_blank or prev_blank) {
                try result.append(allocator, '\n');
            } else {
                try result.append(allocator, ' ');
            }
        }
        if (!is_blank) {
            try result.appendSlice(allocator, tok.input[line_start..tok.pos]);
        }
        prev_blank = is_blank;

        if (tok.pos < tok.input.len and tok.input[tok.pos] == '\n') tok.pos += 1;
    }

    var trailing = result.items.len;
    while (trailing > 0 and result.items[trailing - 1] == '\n') : (trailing -= 1) {}
    if (trailing < result.items.len) result.shrinkAndFree(allocator, trailing);

    return .{ .string = try result.toOwnedSlice(allocator) };
}

fn parseValueTok(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    tok.skipEmpty();
    if (tok.atEnd()) return error.UnexpectedEndOfInput;
    const c = tok.peek();
    if (c == '{') return parseFMap(tok, allocator);
    if (c == '[') return parseFSq(tok, allocator);
    if (c == '"') return parseDQStr(tok, allocator);
    if (c == '\'') return parseSQStr(tok, allocator);

    const line = tok.peekLine();
    const trimmed = blk: {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        break :blk line[i..];
    };
    if (trimmed.len > 0 and (trimmed[0] == '|' or trimmed[0] == '>')) {
        const ch = trimmed[0];
        tok.pos += @intFromPtr(trimmed.ptr) - @intFromPtr(tok.input.ptr);
        return parseBlkScalar(tok, ch, allocator);
    }

    if (tok.flow_depth == 0) {
        if (trimmed.len > 0 and trimmed[0] == '-') {
            if (trimmed.len > 1 and trimmed[1] == ' ') {
                const indent = tok.measureIndent();
                return parseSeq(tok, allocator, indent);
            }
        }

        for (trimmed, 0..) |ch, i| {
            if (ch == ':' and i + 1 < trimmed.len and trimmed[i + 1] == ' ') {
                const indent = tok.measureIndent();
                return parseMap(tok, allocator, indent);
            }
        }
    }

    return parseScalar(tok, allocator);
}

fn parseSeq(tok: *YamlTokenizer, allocator: Allocator, indent: usize) Error!Value {
    var arr = Array.empty;
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }
    try arr.ensureTotalCapacity(allocator, 32);

    while (!tok.atEnd()) {
        tok.skipEmpty();
        if (tok.atEnd()) break;
        const li = tok.measureIndent();
        if (li < indent) break;
        if (li > indent) {
            tok.skipLine();
            continue;
        }
        if (tok.peek() != '-') break;
        tok.pos += 1;
        if (!tok.atEnd() and tok.peek() == ' ') tok.pos += 1;

        tok.skipEmpty();
        if (tok.atEnd()) {
            try arr.append(allocator, .null);
            break;
        }

        const c = tok.peek();
        if (c == '-' or c == '{' or c == '[' or c == '"' or c == '\'') {
            try arr.append(allocator, try parseValueTok(tok, allocator));
            continue;
        }
        const line = tok.peekLine();
        const trimmed = blk: {
            var i: usize = 0;
            while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
            break :blk line[i..];
        };
        if (trimmed.len > 0 and (trimmed[0] == '|' or trimmed[0] == '>')) {
            const ch = trimmed[0];
            tok.pos += @intFromPtr(trimmed.ptr) - @intFromPtr(tok.input.ptr);
            try arr.append(allocator, try parseBlkScalar(tok, ch, allocator));
            continue;
        }

        const val = try parseScalar(tok, allocator);
        if (val == .null and tok.blankLine()) {
            tok.skipLine();
            const child_indent = tok.measureIndent();
            if (child_indent > indent + 1) {
                const nested = try parseBlkVal(tok, allocator, child_indent);
                try arr.append(allocator, nested);
                continue;
            }
        }
        try arr.append(allocator, val);
    }

    return .{ .array = arr };
}

fn parseBlkVal(tok: *YamlTokenizer, allocator: Allocator, indent: usize) Error!Value {
    tok.skipEmpty();
    if (tok.atEnd()) return .null;

    const li = tok.measureIndent();
    if (li < indent) return .null;

    if (tok.peek() == '-') {
        if (tok.pos + 1 < tok.input.len and tok.input[tok.pos + 1] == ' ') {
            tok.pos += 2;
            return parseSeq(tok, allocator, indent);
        }
    }

    if (tok.peek() == '{') return parseFMap(tok, allocator);
    if (tok.peek() == '[') return parseFSq(tok, allocator);

    const line = tok.peekLine();
    const trimmed = blk: {
        var i: usize = 0;
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        break :blk line[i..];
    };
    if (trimmed.len > 0 and (trimmed[0] == '|' or trimmed[0] == '>')) {
        const ch = trimmed[0];
        tok.pos += @intFromPtr(trimmed.ptr) - @intFromPtr(tok.input.ptr);
        return parseBlkScalar(tok, ch, allocator);
    }

    if (li > indent) return parseMap(tok, allocator, indent - 1);

    return parseScalar(tok, allocator);
}

fn parseMap(tok: *YamlTokenizer, allocator: Allocator, first_indent: usize) Error!Value {
    var obj = ObjectMap{};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        obj.deinit(allocator);
    }
    try obj.ensureTotalCapacity(allocator, 32);

    while (!tok.atEnd()) {
        tok.skipEmpty();
        if (tok.atEnd()) break;
        const li = tok.measureIndent();
        if (li < first_indent) break;
        if (li > first_indent) {
            tok.skipLine();
            continue;
        }
        if (tok.peek() == '-') break;

        const key = try parseKey(tok, allocator) orelse break;
        errdefer allocator.free(key);

        tok.skipWhitespace();
        if (tok.atEnd() or tok.peek() != ':') {
            const gop = try obj.getOrPut(allocator, key);
            if (gop.found_existing) {
                allocator.free(key);
                gop.value_ptr.deinit(allocator);
            }
            gop.value_ptr.* = .{ .string = key };
            continue;
        }
        tok.pos += 1;

        const val = try parseAfterColon(tok, allocator);
        const gop = try obj.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            gop.value_ptr.deinit(allocator);
        }
        gop.value_ptr.* = val;
    }

    return .{ .object = obj };
}

fn parseKey(tok: *YamlTokenizer, allocator: Allocator) Error!?[]const u8 {
    tok.skipWhitespace();
    if (tok.atEnd()) return null;
    if (tok.peek() == '"') return @as(?[]const u8, try parseDQRaw(tok, allocator));
    if (tok.peek() == '\'') return @as(?[]const u8, try parseSQRaw(tok, allocator));

    const line = tok.peekLine();
    var end: usize = 0;
    while (end < line.len) : (end += 1) {
        switch (line[end]) {
            ':' => break,
            ' ', '\t' => break,
            else => {},
        }
    }
    if (end == 0) return null;
    const raw = tok.input[tok.pos..][0..end];
    tok.pos += end;
    return @as(?[]const u8, try allocator.dupe(u8, raw));
}

fn parseKeyBuf(tok: *YamlTokenizer, buf: []u8) Error!?[]const u8 {
    tok.skipWhitespace();
    if (tok.atEnd()) return null;
    if (tok.peek() == '"') {
        const raw = tok.peekLine();
        if (raw.len == 0 or raw.len > buf.len) return null;
        @memcpy(buf[0..raw.len], raw);
        return @as(?[]const u8, buf[0..raw.len]);
    }
    if (tok.peek() == '\'') {
        const raw = tok.peekLine();
        if (raw.len == 0 or raw.len > buf.len) return null;
        @memcpy(buf[0..raw.len], raw);
        return @as(?[]const u8, buf[0..raw.len]);
    }

    const line = tok.peekLine();
    var end: usize = 0;
    while (end < line.len and end < buf.len) : (end += 1) {
        switch (line[end]) {
            ':' => break,
            ' ', '\t' => break,
            else => {},
        }
    }
    if (end == 0 or end > buf.len) return null;
    @memcpy(buf[0..end], line[0..end]);
    tok.pos += end;
    return @as(?[]const u8, buf[0..end]);
}

fn parseAfterColon(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    tok.skipWhitespace();
    if (tok.atEnd()) return .null;
    if (tok.peek() == '#') {
        tok.skipLine();
        return parseChild(tok, allocator);
    }
    if (tok.peek() == '\n') {
        tok.pos += 1;
        return parseChild(tok, allocator);
    }
    if (tok.peek() == '|' or tok.peek() == '>') return parseBlkScalar(tok, tok.peek(), allocator);
    if (tok.peek() == '{') return parseFMap(tok, allocator);
    if (tok.peek() == '[') return parseFSq(tok, allocator);
    if (tok.peek() == '"') return parseDQStr(tok, allocator);
    if (tok.peek() == '\'') return parseSQStr(tok, allocator);
    return parseScalar(tok, allocator);
}

fn parseChild(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    tok.skipEmpty();
    if (tok.atEnd()) return .null;
    const indent = tok.measureIndent();
    if (tok.atEnd() or tok.peek() == '\n') return .null;
    if (tok.peek() == '-') {
        return parseSeq(tok, allocator, indent);
    }
    if (indent > 0) return parseMap(tok, allocator, 0);
    return parseScalar(tok, allocator);
}

fn parseFMap(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    assert(tok.peek() == '{');
    tok.pos += 1;
    tok.flow_depth += 1;
    defer tok.flow_depth -= 1;
    var obj = ObjectMap{};
    errdefer {
        var it = obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        obj.deinit(allocator);
    }
    try obj.ensureTotalCapacity(allocator, 32);

    tok.skipWhitespace();
    if (!tok.atEnd() and tok.peek() == '}') {
        tok.pos += 1;
        return .{ .object = obj };
    }

    while (true) {
        tok.skipWhitespace();
        if (!tok.atEnd() and tok.peek() == '}') {
            tok.pos += 1;
            return .{ .object = obj };
        }

        const key = try parseFKey(tok, allocator);
        errdefer allocator.free(key);
        tok.skipWhitespace();
        if (tok.atEnd() or tok.peek() != ':') return error.UnexpectedToken;
        tok.pos += 1;
        tok.skipWhitespace();

        const v = try parseValueTok(tok, allocator);
        const gop = try obj.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            gop.value_ptr.deinit(allocator);
        }
        gop.value_ptr.* = v;

        tok.skipWhitespace();
        if (!tok.atEnd() and tok.peek() == ',') tok.pos += 1;
    }
}

fn parseFKey(tok: *YamlTokenizer, allocator: Allocator) Error![]const u8 {
    if (tok.atEnd()) return error.UnexpectedEndOfInput;
    if (tok.peek() == '"') return parseDQRaw(tok, allocator);
    if (tok.peek() == '\'') return parseSQRaw(tok, allocator);
    const line = tok.peekLine();
    var end: usize = 0;
    while (end < line.len) : (end += 1) {
        switch (line[end]) {
            ':', ',', ' ', '\t', '}', '\n', '\r' => break,
            else => {},
        }
    }
    if (end == 0) return error.UnexpectedToken;
    const raw = tok.input[tok.pos..][0..end];
    tok.pos += end;
    return allocator.dupe(u8, raw);
}

fn parseFSq(tok: *YamlTokenizer, allocator: Allocator) Error!Value {
    assert(tok.peek() == '[');
    tok.pos += 1;
    tok.flow_depth += 1;
    defer tok.flow_depth -= 1;
    var arr = Array.empty;
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }
    try arr.ensureTotalCapacity(allocator, 32);

    tok.skipWhitespace();
    if (!tok.atEnd() and tok.peek() == ']') {
        tok.pos += 1;
        return .{ .array = arr };
    }

    while (true) {
        try arr.append(allocator, try parseValueTok(tok, allocator));
        tok.skipWhitespace();
        if (!tok.atEnd() and tok.peek() == ']') {
            tok.pos += 1;
            return .{ .array = arr };
        }
        if (!tok.atEnd() and tok.peek() == ',') tok.pos += 1;
    }
}

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try YamlTokenizer.init(input);
    const v = try parseValueTok(&tok, allocator);
    tok.skipEmpty();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

fn parseTyped(comptime T: type, allocator: Allocator, tok: *YamlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    if (depth > opts.max_depth) return error.MaxDepthExceeded;
    switch (@typeInfo(T)) {
        .bool => {
            const v = try parseValueTok(tok, allocator);
            return switch (v) {
                .bool => |b| b,
                else => error.TypeMismatch,
            };
        },
        .int => |int| {
            const v = try parseValueTok(tok, allocator);
            return switch (v) {
                .integer => |i| std.math.cast(T, i) orelse error.Overflow,
                .string => |s| {
                    const i = std.fmt.parseInt(i64, s, 10) catch return error.InvalidNumber;
                    if (int.signedness == .unsigned and i < 0) return error.Overflow;
                    return std.math.cast(T, i) orelse error.Overflow;
                },
                else => error.TypeMismatch,
            };
        },
        .float => {
            const v = try parseValueTok(tok, allocator);
            return switch (v) {
                .float => |f| @as(T, @floatCast(f)),
                .integer => |i| @as(T, @floatCast(@as(f64, @floatFromInt(i)))),
                .string => |s| std.fmt.parseFloat(T, s) catch error.InvalidNumber,
                else => error.TypeMismatch,
            };
        },
        .optional => |opt| {
            tok.skipEmpty();
            if (tok.atEnd()) return error.UnexpectedEndOfInput;
            if (tok.tryConsumeNull()) return null;
            return try parseTyped(opt.child, allocator, tok, opts, depth);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                tok.skipEmpty();
                if (tok.atEnd()) return error.UnexpectedEndOfInput;
                const c = tok.peek();
                if (c == '"') {
                    const s = try parseDQRaw(tok, allocator);
                    return s;
                }
                if (c == '\'') {
                    const s = try parseSQRaw(tok, allocator);
                    return s;
                }
                const raw = tok.scanPlain() orelse return error.UnexpectedToken;
                return try allocator.dupe(u8, raw);
            }
            if (ptr.size == .slice) return parseSlice(ptr.child, allocator, tok, opts, depth);
            @compileError("panthera yaml: unsupported pointer type " ++ @typeName(T));
        },
        .array => |arr_info| {
            const v = try parseValueTok(tok, allocator);
            defer v.deinit(allocator);
            switch (v) {
                .array => |a| {
                    if (a.items.len != arr_info.len) return error.TypeMismatch;
                    var result: T = undefined;
                    for (a.items, 0..) |item, i| {
                        result[i] = try valToT(arr_info.child, allocator, item);
                    }
                    return result;
                },
                else => return error.TypeMismatch,
            }
        },
        .@"struct" => |st| return parseStruct(T, st, allocator, tok, opts, depth),
        .@"union" => return parseUnion(T, allocator, tok, opts, depth),
        .@"enum" => {
            const v = try parseValueTok(tok, allocator);
            defer v.deinit(allocator);
            return switch (v) {
                .string => |s| std.meta.stringToEnum(T, s) orelse error.TypeMismatch,
                else => error.TypeMismatch,
            };
        },
        else => @compileError("panthera yaml: unsupported type " ++ @typeName(T)),
    }
}

fn parseSlice(comptime Child: type, allocator: Allocator, tok: *YamlTokenizer, _: ParseOptions, _: u32) Error![]Child {
    const v = try parseValueTok(tok, allocator);
    defer v.deinit(allocator);
    switch (v) {
        .array => |a| {
            var list = std.ArrayListUnmanaged(Child){};
            errdefer {
                for (list.items) |*i| freeTyped(Child, allocator, i.*);
                list.deinit(allocator);
            }
            try list.ensureTotalCapacity(allocator, a.items.len);
            for (a.items) |item| {
                try list.append(allocator, try valToT(Child, allocator, item));
            }
            return list.toOwnedSlice(allocator);
        },
        else => return error.TypeMismatch,
    }
}

fn valToT(comptime T: type, allocator: Allocator, v: Value) Error!T {
    switch (@typeInfo(T)) {
        .bool => return switch (v) {
            .bool => |b| b,
            else => error.TypeMismatch,
        },
        .int => return switch (v) {
            .integer => |i| std.math.cast(T, i) orelse error.Overflow,
            .string => |s| {
                const iv = std.fmt.parseInt(i64, s, 10) catch return error.InvalidNumber;
                return std.math.cast(T, iv) orelse error.Overflow;
            },
            else => error.TypeMismatch,
        },
        .float => return switch (v) {
            .float => |f| @as(T, @floatCast(f)),
            .integer => |i| @as(T, @floatCast(@as(f64, @floatFromInt(i)))),
            .string => |s| std.fmt.parseFloat(T, s) catch error.InvalidNumber,
            else => error.TypeMismatch,
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return switch (v) {
                    .string => |s| try allocator.dupe(u8, s),
                    else => error.TypeMismatch,
                };
            }
            return error.TypeMismatch;
        },
        else => @compileError("panthera yaml: unsupported type " ++ @typeName(T)),
    }
}

fn parseStruct(
    comptime T: type,
    comptime st: std.builtin.Type.Struct,
    allocator: Allocator,
    tok: *YamlTokenizer,
    opts: ParseOptions,
    depth: u32,
) Error!T {
    tok.skipEmpty();
    if (tok.atEnd()) return error.UnexpectedEndOfInput;

    if (tok.peek() == '{') {
        var v = try parseFMap(tok, allocator);
        return switch (v) {
            .object => |*o| try objToStruct(T, st, allocator, o, opts),
            else => error.TypeMismatch,
        };
    }

    const block_indent = tok.measureIndent();
    var result: T = undefined;
    var filled = [_]bool{false} ** st.fields.len;

    while (!tok.atEnd()) {
        tok.skipEmpty();
        if (tok.atEnd()) break;
        const li = tok.measureIndent();
        if (li != block_indent) break;
        if (tok.peek() == '-') break;

        var key_buf: [MAX_FIELD_NAME]u8 = undefined;
        const key = (try parseKeyBuf(tok, &key_buf)) orelse break;

        tok.skipWhitespace();
        if (!tok.atEnd() and tok.peek() == ':') tok.pos += 1;

        const fi = fieldIdx(st.fields, key);
        if (fi) |idx| {
            if (filled[idx] and opts.duplicate_field_behavior == .reject) return error.DuplicateField;
            inline for (st.fields, 0..) |field, i| {
                if (i == idx) {
                    @field(result, field.name) = try parseTyped(field.type, allocator, tok, opts, depth + 1);
                    filled[idx] = true;
                }
            }
        } else {
            if (opts.reject_unknown_fields) return error.UnknownField;
            tok.skipLine();
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

fn objToStruct(
    comptime T: type,
    comptime st: std.builtin.Type.Struct,
    allocator: Allocator,
    obj: *ObjectMap,
    opts: ParseOptions,
) Error!T {
    defer {
        var it = obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        obj.deinit(allocator);
    }
    var result: T = undefined;
    var filled = [_]bool{false} ** st.fields.len;
    var it = obj.iterator();
    while (it.next()) |entry| {
        const key = entry.key_ptr.*;
        const val = entry.value_ptr.*;
        const fi = fieldIdx(st.fields, key);
        if (fi) |idx| {
            if (filled[idx] and opts.duplicate_field_behavior == .reject) return error.DuplicateField;
            inline for (st.fields, 0..) |field, i| {
                if (i == idx) {
                    @field(result, field.name) = try valToT(field.type, allocator, val);
                    filled[idx] = true;
                }
            }
        } else {
            if (opts.reject_unknown_fields) return error.UnknownField;
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

fn parseUnion(comptime T: type, allocator: Allocator, tok: *YamlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    tok.skipEmpty();
    if (tok.atEnd()) return error.UnexpectedEndOfInput;

    if (tok.peek() == '{') {
        var v = try parseFMap(tok, allocator);
        const result = switch (v) {
            .object => |o| blk: {
                var it = o.iterator();
                const entry = it.next() orelse return error.UnexpectedEndOfInput;
                const tag = entry.key_ptr.*;
                const val = entry.value_ptr.*;
                inline for (@typeInfo(T).@"union".fields) |field| {
                    if (std.mem.eql(u8, tag, field.name)) {
                        break :blk @unionInit(T, field.name, try valToT(field.type, allocator, val));
                    }
                }
                return error.UnknownField;
            },
            else => return error.TypeMismatch,
        };
        v.deinit(allocator);
        return result;
    }

    const line = tok.peekLine();
    var colon: usize = line.len;
    for (line, 0..) |ch, i| {
        if (ch == ':') {
            colon = i;
            break;
        }
    }
    if (colon < line.len) {
        inline for (@typeInfo(T).@"union".fields) |field| {
            if (std.mem.eql(u8, line[0..colon], field.name)) {
                tok.pos += colon;
                tok.skipWhitespace();
                if (!tok.atEnd() and tok.peek() == ':') tok.pos += 1;
                const val = try parseTyped(field.type, allocator, tok, opts, depth + 1);
                return @unionInit(T, field.name, val);
            }
        }
    }
    return error.UnknownField;
}

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try YamlTokenizer.init(input);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    tok.skipEmpty();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
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
