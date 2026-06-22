const std = @import("std");
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

const XmlTokenizer = tokenizer_mod.XmlTokenizer;
const TokenTag = tokenizer_mod.TokenTag;

const MAX_FIELD_NAME: usize = 4096;

pub fn parseValue(allocator: Allocator, input: []const u8) Error!Value {
    var tok = try XmlTokenizer.init(input);
    skipProlog(&tok);
    const v = try parseElement(allocator, &tok, 0);
    tok.skipWhitespace();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

pub fn parseFromSlice(comptime T: type, allocator: Allocator, input: []const u8, opts: ParseOptions) Error!T {
    var tok = try XmlTokenizer.init(input);
    skipProlog(&tok);
    const v = try parseTyped(T, allocator, &tok, opts, 0);
    tok.skipWhitespace();
    if (!tok.atEnd()) return error.UnexpectedToken;
    return v;
}

pub fn parseFree(comptime T: type, allocator: Allocator, value: T) void {
    freeTyped(T, allocator, value);
}

fn skipProlog(tok: *XmlTokenizer) void {
    while (true) {
        tok.skipWhitespace();
        if (tok.atEnd() or tok.peek() != '<') return;
        const saved = tok.pos;
        const t = (tok.next() catch return) orelse return;
        switch (t.tag) {
            .pi, .comment => continue,
            else => {
                tok.pos = saved;
                tok.in_tag = false;
                return;
            },
        }
    }
}

fn parseElement(allocator: Allocator, tok: *XmlTokenizer, depth: u32) Error!Value {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;

    tok.in_tag = false;
    const name_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (name_tok.tag != .open_tag) return error.UnexpectedToken;
    const name = name_tok.slice;

    var attrs = ObjectMap{};
    errdefer {
        var it = attrs.iterator();
        while (it.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        attrs.deinit(allocator);
    }
    try attrs.ensureTotalCapacity(allocator, 8);

    while (true) {
        const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        switch (t.tag) {
            .attr_name => {
                const attr_name = try allocator.dupe(u8, t.slice);
                tok.skipWhitespace();
                if (tok.peek() == '=') {
                    tok.pos += 1;
                    tok.skipWhitespace();
                    const val_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (val_tok.tag != .attr_value) return error.UnexpectedToken;
                    const decoded = try allocDecodeEntities(allocator, val_tok.slice);
                    const gop = try attrs.getOrPut(allocator, attr_name);
                    if (gop.found_existing) {
                        allocator.free(attr_name);
                        gop.value_ptr.deinit(allocator);
                    }
                    gop.value_ptr.* = Value{ .string = decoded };
                } else {
                    const gop = try attrs.getOrPut(allocator, attr_name);
                    if (gop.found_existing) {
                        allocator.free(attr_name);
                    } else {
                        gop.value_ptr.* = Value{ .string = try allocator.dupe(u8, "") };
                    }
                }
            },
            .tag_end => {
                tok.in_tag = false;
                break;
            },
            .self_close => {
                tok.in_tag = false;
                const name_alloc = try allocator.dupe(u8, name);
                var node = ObjectMap{};
                errdefer {
                    allocator.free(name_alloc);
                    var it2 = node.iterator();
                    while (it2.next()) |e| {
                        allocator.free(e.key_ptr.*);
                        e.value_ptr.deinit(allocator);
                    }
                    node.deinit(allocator);
                }
                try node.ensureTotalCapacity(allocator, 3);
                node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "name"), Value{ .string = name_alloc });
                node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "attrs"), Value{ .object = attrs });
                var empty_children = Array{ .items = &.{}, .capacity = 0 };
                try empty_children.ensureTotalCapacity(allocator, 0);
                node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "children"), Value{ .array = empty_children });
                return Value{ .object = node };
            },
            else => return error.UnexpectedToken,
        }
    }

    var children = Array{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (children.items) |*c| c.deinit(allocator);
        children.deinit(allocator);
    }
    try children.ensureTotalCapacity(allocator, 16);

    while (true) {
        const saved_pos = tok.pos;
        const saved_tag = tok.in_tag;
        const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
        switch (t.tag) {
            .close_tag => {
                if (!std.mem.eql(u8, t.slice, name)) return error.UnexpectedToken;
                break;
            },
            .text => {
                const decoded = try allocDecodeEntities(allocator, t.slice);
                children.appendAssumeCapacity(Value{ .string = decoded });
            },
            .open_tag => {
                tok.pos = saved_pos;
                tok.in_tag = saved_tag;
                const child = try parseElement(allocator, tok, depth + 1);
                children.appendAssumeCapacity(child);
            },
            .cdata => {
                const content = try allocator.dupe(u8, t.slice);
                children.appendAssumeCapacity(Value{ .string = content });
            },
            .comment, .pi => continue,
            else => return error.UnexpectedToken,
        }
    }

    const name_alloc = try allocator.dupe(u8, name);
    var node = ObjectMap{};
    errdefer {
        allocator.free(name_alloc);
        var it2 = node.iterator();
        while (it2.next()) |e| {
            allocator.free(e.key_ptr.*);
            e.value_ptr.deinit(allocator);
        }
        node.deinit(allocator);
    }
    try node.ensureTotalCapacity(allocator, 3);
    node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "name"), Value{ .string = name_alloc });
    node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "attrs"), Value{ .object = attrs });
    node.putAssumeCapacityNoClobber(try allocator.dupe(u8, "children"), Value{ .array = children });
    return Value{ .object = node };
}

var empty_array: Array = .{ .items = &.{}, .capacity = 0 };

fn allocDecodeEntities(allocator: Allocator, raw: []const u8) Error![]const u8 {
    const amp_idx = std.mem.indexOfScalar(u8, raw, '&');
    if (amp_idx == null) return allocator.dupe(u8, raw);

    var buf: std.ArrayListUnmanaged(u8) = .{ .items = &.{}, .capacity = 0 };
    errdefer buf.deinit(allocator);
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            const semi = std.mem.indexOfScalarPos(u8, raw, i + 1, ';') orelse return error.InvalidEscape;
            const entity = raw[i + 1 .. semi];
            if (entity.len == 0) return error.InvalidEscape;
            if (entity[0] == '#') {
                const cp = if (entity.len > 1 and (entity[1] == 'x' or entity[1] == 'X'))
                    std.fmt.parseInt(u21, entity[2..], 16)
                else
                    std.fmt.parseInt(u21, entity[1..], 10);
                const codepoint = cp catch return error.InvalidEscape;
                if (codepoint > 0x10FFFF) return error.InvalidEscape;
                var enc: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(@intCast(codepoint), &enc) catch return error.InvalidEscape;
                try buf.appendSlice(allocator, enc[0..n]);
            } else if (std.mem.eql(u8, entity, "amp")) {
                try buf.append(allocator, '&');
            } else if (std.mem.eql(u8, entity, "lt")) {
                try buf.append(allocator, '<');
            } else if (std.mem.eql(u8, entity, "gt")) {
                try buf.append(allocator, '>');
            } else if (std.mem.eql(u8, entity, "quot")) {
                try buf.append(allocator, '"');
            } else if (std.mem.eql(u8, entity, "apos")) {
                try buf.append(allocator, '\'');
            } else {
                return error.InvalidEscape;
            }
            i = semi + 1;
        } else {
            try buf.append(allocator, raw[i]);
            i += 1;
        }
    }
    return buf.toOwnedSlice(allocator);
}

fn parseTypedString(allocator: Allocator, tok: *XmlTokenizer) Error![]const u8 {
    const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    switch (t.tag) {
        .text => return allocDecodeEntities(allocator, t.slice),
        .cdata => return allocator.dupe(u8, t.slice),
        .open_tag => {
            while (true) {
                const at = try tok.next() orelse return error.UnexpectedEndOfInput;
                switch (at.tag) {
                    .attr_name => {
                        tok.skipWhitespace();
                        if (tok.peek() == '=') {
                            tok.pos += 1;
                            tok.skipWhitespace();
                            _ = try tok.next();
                        }
                    },
                    .tag_end => break,
                    .self_close => return allocator.dupe(u8, ""),
                    else => return error.TypeMismatch,
                }
            }
            const content = try tok.next() orelse return error.UnexpectedEndOfInput;
            const result = switch (content.tag) {
                .text => try allocDecodeEntities(allocator, content.slice),
                .cdata => try allocator.dupe(u8, content.slice),
                .close_tag => try allocator.dupe(u8, ""),
                else => return error.TypeMismatch,
            };
            if (content.tag == .text or content.tag == .cdata) {
                const cl = try tok.next() orelse return error.UnexpectedEndOfInput;
                if (cl.tag != .close_tag) return error.TypeMismatch;
            }
            return result;
        },
        else => return error.TypeMismatch,
    }
}

fn parseAttrInner(comptime T: type, allocator: Allocator, decoded: []const u8) Error!T {
    switch (@typeInfo(T)) {
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return allocator.dupe(u8, decoded);
            }
        },
        .int => return std.fmt.parseInt(T, decoded, 0) catch error.TypeMismatch,
        .float => return std.fmt.parseFloat(T, decoded),
        .bool => {
            if (std.mem.eql(u8, decoded, "true")) return true;
            if (std.mem.eql(u8, decoded, "false")) return false;
            if (std.mem.eql(u8, decoded, "1")) return true;
            if (std.mem.eql(u8, decoded, "0")) return false;
            return error.TypeMismatch;
        },
        else => {},
    }
    return error.TypeMismatch;
}

fn parseTyped(comptime T: type, allocator: Allocator, tok: *XmlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    if (depth > opts.max_depth) return error.MaxDepthExceeded;
    switch (@typeInfo(T)) {
        .bool => {
            _ = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            return true;
        },
        .int => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            _ = t;
            return 0;
        },
        .float => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            _ = t;
            return 0.0;
        },
        .optional => |opt| {
            const t = try tok.next();
            if (t == null) return null;
            tok.pos = 0;
            return try parseTyped(opt.child, allocator, tok, opts, depth);
        },
        .pointer => |ptr| {
            if (ptr.size == .slice and ptr.child == u8) {
                return parseTypedString(allocator, tok);
            }
            if (ptr.size == .slice) return parseTypedSlice(ptr.child, allocator, tok, opts, depth);
            @compileError("panthera: unsupported pointer type " ++ @typeName(T));
        },
        .@"struct" => |st| return parseTypedStruct(T, st, allocator, tok, opts, depth),
        .@"union" => return parseTypedUnion(T, allocator, tok, opts, depth),
        .@"enum" => {
            const t = (try tok.next()) orelse return error.UnexpectedEndOfInput;
            const name = switch (t.tag) {
                .open_tag => t.slice,
                .text => t.slice,
                else => return error.TypeMismatch,
            };
            return std.meta.stringToEnum(T, name) orelse error.TypeMismatch;
        },
        else => @compileError("panthera: unsupported type " ++ @typeName(T)),
    }
}

fn parseTypedSlice(comptime Child: type, allocator: Allocator, tok: *XmlTokenizer, opts: ParseOptions, depth: u32) Error![]Child {
    var list: std.ArrayListUnmanaged(Child) = .{ .items = &.{}, .capacity = 0 };
    errdefer {
        for (list.items) |*i| freeTyped(Child, allocator, i.*);
        list.deinit(allocator);
    }
    try list.ensureTotalCapacity(allocator, 32);
    while (true) {
        const t = try tok.next() orelse break;
        switch (t.tag) {
            .close_tag => break,
            .text => {
                if (Child == u8) {
                    list.appendAssumeCapacity(@as(u8, 0));
                }
            },
            .open_tag => {
                try list.append(allocator, try parseTyped(Child, allocator, tok, opts, depth + 1));
            },
            .comment, .pi => continue,
            else => {},
        }
    }
    return list.toOwnedSlice(allocator);
}

fn parseTypedStruct(
    comptime T: type,
    comptime st: std.builtin.Type.Struct,
    allocator: Allocator,
    tok: *XmlTokenizer,
    opts: ParseOptions,
    depth: u32,
) Error!T {
    var result: T = undefined;
    var filled = [_]bool{false} ** st.fields.len;

    tok.in_tag = false;
    const name_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    if (name_tok.tag != .open_tag) return error.UnexpectedToken;

    while (true) {
        const at = try tok.next() orelse break;
        switch (at.tag) {
            .attr_name => {
                const key = at.slice;
                tok.skipWhitespace();
                if (tok.peek() == '=') {
                    tok.pos += 1;
                    tok.skipWhitespace();
                    const val_tok = (try tok.next()) orelse return error.UnexpectedEndOfInput;
                    if (val_tok.tag != .attr_value) return error.UnexpectedToken;
                    const decoded = try allocDecodeEntities(allocator, val_tok.slice);
                    defer allocator.free(decoded);
                    const fi = fieldIndexHash(st.fields, key);
                    if (fi) |idx| {
                        inline for (st.fields, 0..) |field, i| {
                            if (i == idx) {
                                if (@typeInfo(field.type) == .@"struct" and @hasDecl(field.type, "is_xml_attr")) {
                                    const inner = @typeInfo(field.type).@"struct".fields[0].type;
                                    @field(result, field.name) = .{ .value = try parseAttrInner(inner, allocator, decoded) };
                                    filled[idx] = true;
                                }
                            }
                        }
                    }
                }
            },
            .tag_end => {
                tok.in_tag = false;
                break;
            },
            .self_close => {
                tok.in_tag = false;
                inline for (st.fields, 0..) |field, fi2| {
                    if (!filled[fi2]) {
                        if (field.default_value_ptr) |dvp| {
                            @field(result, field.name) = @as(*const field.type, @ptrCast(@alignCast(dvp))).*;
                        } else if (@typeInfo(field.type) == .optional) {
                            @field(result, field.name) = null;
                        }
                    }
                }
                return result;
            },
            else => return error.UnexpectedToken,
        }
    }

    while (true) {
        const saved_pos = tok.pos;
        const saved_tag = tok.in_tag;
        const t = try tok.next() orelse break;
        switch (t.tag) {
            .close_tag => break,
            .open_tag => {
                const child_name = t.slice;
                const fi = fieldIndexHash(st.fields, child_name);
                if (fi) |idx| {
                    tok.pos = saved_pos;
                    tok.in_tag = saved_tag;
                    inline for (st.fields, 0..) |field, i| {
                        if (i == idx) {
                            @field(result, field.name) = try parseTyped(field.type, allocator, tok, opts, depth + 1);
                            filled[idx] = true;
                        }
                    }
                } else {
                    if (opts.reject_unknown_fields) return error.UnknownField;
                    try skipElement(tok, depth + 1);
                }
            },
            .text, .cdata => {},
            .comment, .pi => continue,
            else => return error.UnexpectedToken,
        }
    }

    inline for (st.fields, 0..) |field, fi2| {
        if (!filled[fi2]) {
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

fn parseTypedUnion(comptime T: type, allocator: Allocator, tok: *XmlTokenizer, opts: ParseOptions, depth: u32) Error!T {
    const kt = (try tok.next()) orelse return error.UnexpectedEndOfInput;
    const key = switch (kt.tag) {
        .open_tag => kt.slice,
        .text => kt.slice,
        else => return error.UnexpectedToken,
    };

    inline for (@typeInfo(T).@"union".fields) |field| {
        if (std.mem.eql(u8, key, field.name)) {
            const v = try parseTyped(field.type, allocator, tok, opts, depth + 1);
            return @unionInit(T, field.name, v);
        }
    }
    return error.UnknownField;
}

fn skipElement(tok: *XmlTokenizer, depth: u32) Error!void {
    if (depth > MAX_DEPTH) return error.MaxDepthExceeded;
    const t = (try tok.next()) orelse return;
    switch (t.tag) {
        .tag_end => {
            var nest: u32 = 1;
            while (nest > 0) {
                const ct = (try tok.next()) orelse return;
                switch (ct.tag) {
                    .open_tag => nest += 1,
                    .close_tag => nest -= 1,
                    else => {},
                }
            }
        },
        .self_close => {},
        else => {},
    }
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
    // Fallback: XML hyphens match Zig underscores in field names
    if (std.mem.indexOfScalar(u8, key, '-') != null) {
        inline for (fields, 0..) |field, i| {
            if (field.name.len == key.len) {
                var match = true;
                for (field.name, 0..) |c, j| {
                    if (c != key[j] and !(c == '_' and key[j] == '-')) {
                        match = false;
                        break;
                    }
                }
                if (match) return i;
            }
        }
    }
    return null;
}

fn freeTyped(comptime T: type, allocator: Allocator, value: T) void {
    switch (@typeInfo(T)) {
        .pointer => |ptr| if (ptr.size == .slice) {
            if (ptr.child != u8) for (value) |item| freeTyped(ptr.child, allocator, item);
            allocator.free(value);
        },
        .optional => if (value) |v| freeTyped(@typeInfo(T).optional.child, allocator, v),
        .@"struct" => |st| {
            if (@hasDecl(T, "is_xml_attr")) {
                inline for (st.fields) |f| {
                    if (std.mem.eql(u8, f.name, "value")) {
                        freeTyped(f.type, allocator, @field(value, f.name));
                    }
                }
            } else {
                inline for (st.fields) |f| freeTyped(f.type, allocator, @field(value, f.name));
            }
        },
        .array => |arr| for (value) |item| freeTyped(arr.child, allocator, item),
        else => {},
    }
}
