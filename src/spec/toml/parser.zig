const std = @import("std");
const assert = std.debug.assert;
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

const Tokenizer = tokenizer_mod.TomlTokenizer;
const TokenTag = tokenizer_mod.TokenTag;

const MAX_FIELD_NAME: usize = 4096;

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try Tokenizer.init(input);
    return try parseDocument(allocator, &tok);
}

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try Tokenizer.init(input);
    const v = try parseDocument(allocator, &tok);
    var result: T = undefined;
    try populateTyped(T, allocator, &result, &v, opts, 0);
    return result;
}

pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
}

fn parseDocument(allocator: Allocator, tok: *Tokenizer) Error!Value {
    var root_obj = ObjectMap{};
    errdefer {
        var it = root_obj.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        root_obj.deinit(allocator);
    }
    try root_obj.ensureTotalCapacity(allocator, 64);

    var current_path: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
    defer current_path.deinit(allocator);

    while (true) {
        const p = tok.peek();
        if (p == null) break;

        if (p.? == '[') {
            // Table header or table array header
            if (tok.pos + 1 < tok.input.len and tok.input[tok.pos + 1] == '[') {
                const start_tok = try tok.scanTableArrayHeader();
                current_path.clearRetainingCapacity();
                var it = std.mem.tokenizeScalar(u8, start_tok.slice, '.');
                while (it.next()) |part| {
                    try current_path.append(allocator, part);
                }
                _ = try getOrCreateAtPath(allocator, &root_obj, current_path.items, true);
            } else {
                const start_tok = try tok.scanTableHeader();
                current_path.clearRetainingCapacity();
                var it = std.mem.tokenizeScalar(u8, start_tok.slice, '.');
                while (it.next()) |part| {
                    try current_path.append(allocator, part);
                }
                _ = try getOrCreateAtPath(allocator, &root_obj, current_path.items, false);
            }
            continue;
        }

        const start_tok = try tok.next() orelse break;
        switch (start_tok.tag) {
            .newline => continue,
            .key, .string => {
                var parts: std.ArrayListUnmanaged([]const u8) = .{ .items = &.{}, .capacity = 0 };
                defer parts.deinit(allocator);
                try parts.append(allocator, if (start_tok.tag == .key)
                    try allocator.dupe(u8, start_tok.slice)
                else
                    try allocDecodeBasicString(allocator, start_tok.slice));
                while (true) {
                    const sep = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (sep.tag == .dot) {
                        const part_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                        switch (part_tok.tag) {
                            .key => try parts.append(allocator, try allocator.dupe(u8, part_tok.slice)),
                            .string => try parts.append(allocator, try allocDecodeBasicString(allocator, part_tok.slice)),
                            else => return error.UnexpectedToken,
                        }
                    } else if (sep.tag == .equals) {
                        break;
                    } else {
                        return error.UnexpectedToken;
                    }
                }
                const val = try parseValueInner(allocator, tok, 0);
                var consumed: [64]bool = .{false} ** 64;
                errdefer {
                    for (parts.items, 0..) |part_str, idx| {
                        if (idx >= consumed.len or !consumed[idx]) allocator.free(part_str);
                    }
                }
                if (current_path.items.len == 0) {
                    const gop = try root_obj.getOrPut(allocator, parts.items[0]);
                    if (parts.items.len == 1) {
                        if (gop.found_existing) {
                            gop.value_ptr.deinit(allocator);
                        } else {
                            consumed[0] = true;
                        }
                        gop.value_ptr.* = val;
                    } else {
                        if (!gop.found_existing) {
                            consumed[0] = true;
                            gop.value_ptr.* = Value{ .object = ObjectMap{} };
                        }
                        if (gop.value_ptr.* != .object) return error.TypeMismatch;
                        var depth = &gop.value_ptr.object;
                        for (parts.items[1 .. parts.items.len - 1], 1..) |part, idx| {
                            const entry = try depth.getOrPut(allocator, part);
                            if (!entry.found_existing) {
                                if (idx < consumed.len) consumed[idx] = true;
                                entry.value_ptr.* = Value{ .object = ObjectMap{} };
                            }
                            if (entry.value_ptr.* != .object) return error.TypeMismatch;
                            depth = &entry.value_ptr.object;
                        }
                        const last_idx = parts.items.len - 1;
                        const last = parts.items[last_idx];
                        const entry = try depth.getOrPut(allocator, last);
                        if (entry.found_existing) {
                            entry.value_ptr.deinit(allocator);
                        } else {
                            if (last_idx < consumed.len) consumed[last_idx] = true;
                        }
                        entry.value_ptr.* = val;
                    }
                } else {
                    const parent_val = try getOrCreateTable(allocator, &root_obj, current_path.items);
                    var parent: *ObjectMap = undefined;
                    if (parent_val.* == .object) {
                        parent = &parent_val.object;
                    } else if (parent_val.* == .array) {
                        parent = &parent_val.array.items[parent_val.array.items.len - 1].object;
                    } else {
                        return error.TypeMismatch;
                    }
                    const gop = try parent.getOrPut(allocator, parts.items[0]);
                    if (parts.items.len == 1) {
                        if (gop.found_existing) {
                            gop.value_ptr.deinit(allocator);
                        } else {
                            consumed[0] = true;
                        }
                        gop.value_ptr.* = val;
                    } else {
                        if (!gop.found_existing) {
                            consumed[0] = true;
                            gop.value_ptr.* = Value{ .object = ObjectMap{} };
                        }
                        if (gop.value_ptr.* != .object) return error.TypeMismatch;
                        var depth = &gop.value_ptr.object;
                        for (parts.items[1 .. parts.items.len - 1], 1..) |part, idx| {
                            const entry = try depth.getOrPut(allocator, part);
                            if (!entry.found_existing) {
                                if (idx < consumed.len) consumed[idx] = true;
                                entry.value_ptr.* = Value{ .object = ObjectMap{} };
                            }
                            if (entry.value_ptr.* != .object) return error.TypeMismatch;
                            depth = &entry.value_ptr.object;
                        }
                        const last_idx = parts.items.len - 1;
                        const last = parts.items[last_idx];
                        const entry = try depth.getOrPut(allocator, last);
                        if (entry.found_existing) {
                            entry.value_ptr.deinit(allocator);
                        } else {
                            if (last_idx < consumed.len) consumed[last_idx] = true;
                        }
                        entry.value_ptr.* = val;
                    }
                }
                for (parts.items, 0..) |part_str, idx| {
                    if (idx >= consumed.len or !consumed[idx]) allocator.free(part_str);
                }
            },
            else => return error.UnexpectedToken,
        }
    }

    return Value{ .object = root_obj };
}

fn getOrCreateTable(allocator: Allocator, root: *ObjectMap, path: [][]const u8) Error!*Value {
    var current = root;
    for (path, 0..) |part, i| {
        const is_last = i == path.len - 1;
        const entry = current.getPtr(part) orelse {
            const key = try allocator.dupe(u8, part);
            errdefer allocator.free(key);
            try current.put(allocator, key, Value{ .object = ObjectMap{} });
            return getOrCreateTable(allocator, root, path);
        };
        if (is_last) return entry;
        if (entry.* != .object) return error.TypeMismatch;
        current = &entry.object;
    }
    return error.UnexpectedToken;
}

fn getOrCreateAtPath(allocator: Allocator, root: *ObjectMap, path: [][]const u8, is_array_table: bool) Error!*Value {
    var current = root;
    for (path, 0..) |part, i| {
        const is_last = i == path.len - 1;
        const entry = current.getPtr(part) orelse {
            if (is_last and is_array_table) {
                var arr = Array{ .items = &.{}, .capacity = 0 };
                errdefer {
                    for (arr.items) |*item| item.deinit(allocator);
                    arr.deinit(allocator);
                }
                try arr.ensureTotalCapacity(allocator, 4);
                try arr.append(allocator, Value{ .object = ObjectMap{} });
                const key = try allocator.dupe(u8, part);
                errdefer allocator.free(key);
                try current.put(allocator, key, Value{ .array = arr });
                return current.getPtr(part).?;
            }
            const key = try allocator.dupe(u8, part);
            errdefer allocator.free(key);
            try current.put(allocator, key, Value{ .object = ObjectMap{} });
            return getOrCreateAtPath(allocator, root, path, is_array_table);
        };
        if (is_last) {
            if (is_array_table) {
                if (entry.* != .array) {
                    // Convert to array
                    const old = entry.*;
                    var arr = Array{ .items = &.{}, .capacity = 0 };
                    errdefer {
                        for (arr.items) |*item| item.deinit(allocator);
                        arr.deinit(allocator);
                    }
                    try arr.ensureTotalCapacity(allocator, 4);
                    try arr.append(allocator, old);
                    try arr.append(allocator, Value{ .object = ObjectMap{} });
                    entry.* = Value{ .array = arr };
                } else {
                    try entry.array.append(allocator, Value{ .object = ObjectMap{} });
                }
            }
            return entry;
        }
        if (entry.* == .array) {
            current = &entry.array.items[entry.array.items.len - 1].object;
        } else if (entry.* == .object) {
            current = &entry.object;
        } else return error.TypeMismatch;
    }
    return error.UnexpectedToken;
}

fn parseValueInner(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    const t = try tok.next() orelse return error.UnexpectedEndOfInput;
    return switch (t.tag) {
        .true_lit => Value{ .bool = true },
        .false_lit => Value{ .bool = false },
        .integer => Value{ .integer = try parseInt(t.slice) },
        .float => Value{ .float = try std.fmt.parseFloat(f64, t.slice) },
        .string => Value{ .string = try allocDecodeBasicString(allocator, t.slice) },
        .literal_string => Value{ .string = try allocator.dupe(u8, t.slice[1 .. t.slice.len - 1]) },
        .multiline_string => Value{ .string = try allocDecodeMultilineString(allocator, t.slice) },
        .multiline_literal_string => Value{ .string = try allocator.dupe(u8, t.slice) },
        .offset_datetime, .local_datetime, .local_date, .local_time => Value{ .string = try allocator.dupe(u8, t.slice) },
        .array_begin => try parseArray(allocator, tok, depth + 1),
        .inline_table_begin => try parseInlineTable(allocator, tok, depth + 1),
        else => error.UnexpectedToken,
    };
}

fn parseInt(s: []const u8) Error!i64 {
    var raw = s;
    var neg = false;
    if (raw.len == 0) return error.InvalidNumber;
    if (raw[0] == '+') {
        raw = raw[1..];
    } else if (raw[0] == '-') {
        neg = true;
        raw = raw[1..];
    }
    if (raw.len == 0) return error.InvalidNumber;

    const base: u8 = if (raw.len > 2) switch (raw[1]) {
        'x', 'X' => 16,
        'o', 'O' => 8,
        'b', 'B' => 2,
        else => 10,
    } else 10;

    const digits_start: usize = if (base != 10) 2 else 0;

    // Strip underscores
    var buf: [64]u8 = undefined;
    var buf_len: usize = 0;
    for (raw[digits_start..]) |c| {
        if (c != '_') {
            if (buf_len >= buf.len) return error.Overflow;
            buf[buf_len] = c;
            buf_len += 1;
        }
    }

    const u = if (base == 10) blk: {
        if (simdParseU64Decimal(buf[0..buf_len])) |u| break :blk u;
        break :blk std.fmt.parseUnsigned(u64, buf[0..buf_len], 10) catch return error.InvalidNumber;
    } else std.fmt.parseUnsigned(u64, buf[0..buf_len], base) catch return error.InvalidNumber;

    if (neg) {
        if (u > @as(u64, @intCast(std.math.maxInt(i64))) + 1) return error.Overflow;
        return -@as(i64, @intCast(u));
    }
    if (u > std.math.maxInt(i64)) return error.Overflow;
    return @as(i64, @intCast(u));
}

fn parseArray(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    var arr = Array{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (arr.items) |*item| item.deinit(allocator);
        arr.deinit(allocator);
    }
    try arr.ensureTotalCapacity(allocator, 32);
    while (true) {
        const p = tok.peek();
        if (p == null or p.? == ']') {
            if (p) |_| tok.pos += 1;
            return Value{ .array = arr };
        }
        if (p.? == '\n') {
            _ = try tok.next();
            continue;
        }
        if (p.? == ',') {
            tok.pos += 1;
            continue;
        }
        try arr.append(allocator, try parseValueInner(allocator, tok, depth));
    }
}

fn parseInlineTable(allocator: Allocator, tok: *Tokenizer, depth: u32) Error!Value {
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
    try obj.ensureTotalCapacity(allocator, 8);
    while (true) {
        const p = tok.peek();
        if (p == null or p.? == '}') {
            if (p) |_| tok.pos += 1;
            return Value{ .object = obj };
        }
        if (p.? == '\n' or p.? == ',') {
            tok.pos += 1;
            continue;
        }
        const key_tok = try tok.next() orelse return error.UnexpectedEndOfInput;
        if (key_tok.tag != .key and key_tok.tag != .string) return error.UnexpectedToken;
        const key = if (key_tok.tag == .string)
            try allocDecodeBasicString(allocator, key_tok.slice)
        else
            try allocator.dupe(u8, key_tok.slice);
        errdefer allocator.free(key);
        const eq = try tok.next() orelse return error.UnexpectedEndOfInput;
        if (eq.tag != .equals) return error.UnexpectedToken;
        const val = try parseValueInner(allocator, tok, depth);
        const gop = try obj.getOrPut(allocator, key);
        if (gop.found_existing) {
            allocator.free(key);
            gop.value_ptr.deinit(allocator);
        }
        gop.value_ptr.* = val;
    }
}

fn allocDecodeBasicString(allocator: Allocator, raw: []const u8) Error![]u8 {
    assert(raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"');
    const inner = raw[1 .. raw.len - 1];
    const amp = std.mem.indexOfScalar(u8, inner, '\\');
    if (amp == null) {
        return allocator.dupe(u8, inner);
    }
    var buf = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, inner.len);
    var i: usize = 0;
    while (i < inner.len) {
        if (inner[i] == '\\') {
            i += 1;
            if (i >= inner.len) return error.InvalidEscape;
            switch (inner[i]) {
                'b' => try buf.append(allocator, '\x08'),
                't' => try buf.append(allocator, '\t'),
                'n' => try buf.append(allocator, '\n'),
                'f' => try buf.append(allocator, '\x0C'),
                'r' => try buf.append(allocator, '\r'),
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                'u' => {
                    i += 1;
                    if (i + 4 > inner.len) return error.InvalidEscape;
                    const cp = try parseHex4(inner[i..][0..4]);
                    i += 3;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return error.InvalidEscape;
                    try buf.appendSlice(allocator, enc[0..n]);
                },
                'U' => {
                    i += 1;
                    if (i + 8 > inner.len) return error.InvalidEscape;
                    const cp = try parseHex8(inner[i..][0..8]);
                    i += 7;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return error.InvalidEscape;
                    try buf.appendSlice(allocator, enc[0..n]);
                },
                else => return error.InvalidEscape,
            }
        } else {
            try buf.append(allocator, inner[i]);
        }
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
}

fn allocDecodeMultilineString(allocator: Allocator, raw: []const u8) Error![]u8 {
    var buf = std.ArrayListUnmanaged(u8){ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);
    try buf.ensureTotalCapacity(allocator, raw.len);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '\\' and i + 1 < raw.len) {
            if (raw[i + 1] == '\n') {
                i += 2;
                continue;
            }
            if (raw[i + 1] == '\r' and i + 2 < raw.len and raw[i + 2] == '\n') {
                i += 3;
                continue;
            }
            i += 1;
            if (i >= raw.len) return error.InvalidEscape;
            switch (raw[i]) {
                'b' => try buf.append(allocator, '\x08'),
                't' => try buf.append(allocator, '\t'),
                'n' => try buf.append(allocator, '\n'),
                'f' => try buf.append(allocator, '\x0C'),
                'r' => try buf.append(allocator, '\r'),
                '"' => try buf.append(allocator, '"'),
                '\\' => try buf.append(allocator, '\\'),
                'u' => {
                    i += 1;
                    if (i + 4 > raw.len) return error.InvalidEscape;
                    const cp = try parseHex4(raw[i..][0..4]);
                    i += 3;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return error.InvalidEscape;
                    try buf.appendSlice(allocator, enc[0..n]);
                },
                'U' => {
                    i += 1;
                    if (i + 8 > raw.len) return error.InvalidEscape;
                    const cp = try parseHex8(raw[i..][0..8]);
                    i += 7;
                    var enc: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(@intCast(cp), &enc) catch return error.InvalidEscape;
                    try buf.appendSlice(allocator, enc[0..n]);
                },
                else => return error.InvalidEscape,
            }
        } else {
            try buf.append(allocator, raw[i]);
        }
        i += 1;
    }
    return buf.toOwnedSlice(allocator);
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

fn parseHex8(s: []const u8) Error!u32 {
    assert(s.len == 8);
    var v: u32 = 0;
    for (s) |c| {
        v = (v << 4) | switch (c) {
            '0'...'9' => @as(u32, c - '0'),
            'a'...'f' => @as(u32, c - 'a' + 10),
            'A'...'F' => @as(u32, c - 'A' + 10),
            else => return error.InvalidEscape,
        };
    }
    return v;
}

fn populateTyped(comptime T: type, allocator: Allocator, out: *T, val: *const Value, opts: ParseOptions, depth: u32) Error!void {
    if (depth > opts.max_depth) return error.MaxDepthExceeded;
    switch (@typeInfo(T)) {
        .@"struct" => |st| {
            if (val.* != .object) return error.TypeMismatch;
            const obj = val.object;
            inline for (st.fields) |field| {
                const entry_ptr = obj.getPtr(field.name);
                if (entry_ptr) |e| {
                    const ft = field.type;
                    switch (@typeInfo(ft)) {
                        .bool => {
                            if (e.* != .bool) return error.TypeMismatch;
                            @field(out, field.name) = e.bool;
                        },
                        .int => {
                            if (e.* == .integer) {
                                @field(out, field.name) = @intCast(e.integer);
                            } else if (e.* == .string) {
                                @field(out, field.name) = @intCast(try parseInt(e.string));
                            } else return error.TypeMismatch;
                        },
                        .float => {
                            if (e.* == .float) {
                                @field(out, field.name) = @as(ft, @floatCast(e.float));
                            } else if (e.* == .string) {
                                @field(out, field.name) = try std.fmt.parseFloat(ft, e.string);
                            } else return error.TypeMismatch;
                        },
                        .pointer => |ptr| {
                            if (ptr.size == .slice and ptr.child == u8) {
                                if (e.* != .string) return error.TypeMismatch;
                                @field(out, field.name) = try allocator.dupe(u8, e.string);
                            } else if (ptr.size == .slice) {
                                if (e.* != .array) return error.TypeMismatch;
                                var list: std.ArrayListUnmanaged(ptr.child) = .{ .items = &.{}, .capacity = 0 };
                                defer list.deinit(allocator);
                                try list.ensureTotalCapacity(allocator, e.array.items.len);
                                for (e.array.items) |*item| {
                                    var child_val: ptr.child = undefined;
                                    try populateTyped(ptr.child, allocator, &child_val, item, opts, depth + 1);
                                    try list.append(allocator, child_val);
                                }
                                @field(out, field.name) = list.toOwnedSlice(allocator);
                            } else @compileError("unsupported pointer");
                        },
                        .@"struct" => {
                            if (e.* == .object) {
                                var child_val: ft = undefined;
                                try populateTyped(ft, allocator, &child_val, e, opts, depth + 1);
                                @field(out, field.name) = child_val;
                            } else return error.TypeMismatch;
                        },
                        .array => |arr_info| {
                            if (e.* != .array) return error.TypeMismatch;
                            if (e.array.items.len != arr_info.len) return error.TypeMismatch;
                            var result: ft = undefined;
                            for (&result, e.array.items) |*elem, *item| {
                                try populateTyped(arr_info.child, allocator, elem, item, opts, depth + 1);
                            }
                            @field(out, field.name) = result;
                        },
                        .optional => {
                            if (e.* == .string and std.mem.eql(u8, e.string, "")) {
                                @field(out, field.name) = @as(ft, null);
                            } else {
                                var child_val: std.meta.Child(ft) = undefined;
                                try populateTyped(std.meta.Child(ft), allocator, &child_val, e, opts, depth + 1);
                                @field(out, field.name) = child_val;
                            }
                        },
                        else => return error.TypeMismatch,
                    }
                } else if (field.default_value_ptr) |dvp| {
                    @field(out, field.name) = @as(*const field.type, @ptrCast(@alignCast(dvp))).*;
                } else if (opts.require_all_fields) {
                    return error.MissingField;
                } else if (@typeInfo(field.type) == .optional) {
                    @field(out, field.name) = null;
                }
            }
        },
        else => return error.TypeMismatch,
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
