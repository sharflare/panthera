const std = @import("std");

const types = @import("types.zig");
const simd = @import("simd.zig");

const StringifyOptions = types.StringifyOptions;
const Value = types.Value;
const MAX_DEPTH = types.MAX_DEPTH;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

/// Serialize `value` as JSON into `writer`.
/// Supports structs, unions, slices, optionals, enums, `Value`, and scalar types.
/// Set `opts.whitespace` to a non-null indent width for pretty-printing.
pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var s = Stringifier(*std.Io.Writer){ .writer = writer, .opts = opts, .depth = 0 };
    try s.write(value);
}

pub fn Stringifier(comptime Writer: type) type {
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

        pub fn write(self: *Self, value: anytype) !void {
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
