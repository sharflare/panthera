const std = @import("std");

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");
const writeInt = @import("../../format.zig").writeInt;
const writeFloat = @import("../../format.zig").writeFloat;

const StringifyOptions = types.StringifyOptions;
const Value = types.Value;
const MAX_DEPTH = types.MAX_DEPTH;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var s = Stringifier(*std.Io.Writer){
        .writer = writer,
        .opts = opts,
        .depth = 0,
        .buf = undefined,
        .bpos = 0,
    };
    try s.write(value);
    try s.flush();
}

pub fn Stringifier(comptime Writer: type) type {
    return struct {
        writer: Writer,
        opts: StringifyOptions,
        depth: u32,
        buf: [256]u8,
        bpos: usize,

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

        pub inline fn wb(self: *Self, b: u8) !void {
            if (self.bpos >= self.buf.len) try self.flush();
            self.buf[self.bpos] = b;
            self.bpos += 1;
        }

        pub inline fn wa(self: *Self, s: []const u8) !void {
            if (s.len >= self.buf.len) {
                try self.flush();
                try self.writer.writeAll(s);
                return;
            }
            if (self.bpos + s.len > self.buf.len) try self.flush();
            @memcpy(self.buf[self.bpos .. self.bpos + s.len], s);
            self.bpos += s.len;
        }

        pub inline fn writeAll(self: *Self, s: []const u8) !void {
            try self.wa(s);
        }

        pub inline fn writeByte(self: *Self, b: u8) !void {
            try self.wb(b);
        }

        fn flush(self: *Self) !void {
            if (self.bpos > 0) {
                try self.writer.writeAll(self.buf[0..self.bpos]);
                self.bpos = 0;
            }
        }

        pub fn write(self: *Self, value: anytype) !void {
            const T = @TypeOf(value);
            switch (@typeInfo(T)) {
                .null => try self.wa("null"),
                .bool => try self.wa(if (value) "true" else "false"),
                .int, .comptime_int => try writeInt(self, @as(i64, @intCast(value))),
                .float, .comptime_float => try writeFloat(self, @as(f64, @floatCast(value))),
                .optional => if (value) |v| try self.write(v) else try self.wa("null"),
                .@"enum" => {
                    try self.wb('"');
                    try self.writeEscaped(@tagName(value));
                    try self.wb('"');
                },
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8) {
                        try self.wb('"');
                        try self.writeEscaped(value);
                        try self.wb('"');
                    } else try self.writeArray(value),
                    .one => try self.write(value.*),
                    .many => {
                        if (ptr.child == u8) {
                            const slice = std.mem.span(value);
                            try self.wb('"');
                            try self.writeEscaped(slice);
                            try self.wb('"');
                        } else {
                            @compileError("panthera stringify: unsupported many pointer");
                        }
                    },
                    .c => {
                        const slice = std.mem.span(value);
                        try self.wb('"');
                        try self.writeEscaped(slice);
                        try self.wb('"');
                    },
                },
                .array => |arr| if (arr.child == u8) {
                    try self.wb('"');
                    try self.writeEscaped(&value);
                    try self.wb('"');
                } else try self.writeArray(&value),
                .@"struct" => |st| {
                    const pretty = self.opts.whitespace != null;
                    try self.wb('{');
                    self.depth += 1;
                    var first = true;
                    inline for (st.fields) |field| {
                        const fv = @field(value, field.name);
                        if (!self.opts.emit_null_optional_fields) {
                            if (comptime @typeInfo(field.type) == .optional) {
                                if (fv == null) continue;
                            }
                        }
                        if (!first) try self.wb(',');
                        first = false;
                        if (pretty) {
                            try self.indentPretty();
                            try self.wa("\"" ++ field.name ++ "\": ");
                        } else {
                            try self.wa("\"" ++ field.name ++ "\":");
                        }
                        try self.write(fv);
                    }
                    self.depth -= 1;
                    if (!first and pretty) try self.indentPretty();
                    try self.wb('}');
                },
                .@"union" => |un| {
                    if (T == Value) {
                        try self.writeValue(value);
                        return;
                    }
                    if (un.tag_type == null) @compileError("panthera: bare union not supported");
                    const pretty = self.opts.whitespace != null;
                    try self.wb('{');
                    self.depth += 1;
                    if (pretty) try self.indentPretty();
                    try self.wb('"');
                    try self.writeEscaped(@tagName(value));
                    if (pretty) try self.wa("\": ") else try self.wa("\":");
                    switch (value) {
                        inline else => |pl| try self.write(pl),
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.wb('}');
                },
                .void => try self.wa("null"),
                else => @compileError("panthera stringify: unsupported type " ++ @typeName(T)),
            }
        }

        fn writeValue(self: *Self, v: Value) !void {
            const pretty = self.opts.whitespace != null;
            switch (v) {
                .null => try self.wa("null"),
                .bool => |b| try self.wa(if (b) "true" else "false"),
                .integer => |i| try writeInt(self, i),
                .float => |f| try writeFloat(self, f),
                .number_string => |s| try self.wa(s),
                .string => |s| {
                    try self.wb('"');
                    try self.writeEscaped(s);
                    try self.wb('"');
                },
                .array => |a| {
                    if (a.items.len == 0) {
                        try self.wa("[]");
                        return;
                    }
                    try self.wb('[');
                    self.depth += 1;
                    try self.writeValue(a.items[0]);
                    for (a.items[1..]) |item| {
                        try self.wb(',');
                        if (pretty) try self.indentPretty();
                        try self.writeValue(item);
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.wb(']');
                },
                .object => |o| {
                    if (o.count() == 0) {
                        try self.wa("{}");
                        return;
                    }
                    try self.wb('{');
                    self.depth += 1;
                    const keys = o.keys();
                    const vals = o.values();
                    var i: usize = 0;
                    while (i < keys.len) : (i += 1) {
                        if (i > 0) try self.wb(',');
                        if (pretty) try self.indentPretty();
                        try self.wb('"');
                        try self.writeEscaped(keys[i]);
                        if (pretty) try self.wa("\": ") else try self.wa("\":");
                        try self.writeValue(vals[i]);
                    }
                    self.depth -= 1;
                    if (pretty) try self.indentPretty();
                    try self.wb('}');
                },
            }
        }

        fn writeArray(self: *Self, slice: anytype) !void {
            if (slice.len == 0) {
                try self.wa("[]");
                return;
            }
            const pretty = self.opts.whitespace != null;
            try self.wb('[');
            self.depth += 1;
            try self.write(slice[0]);
            for (slice[1..]) |item| {
                try self.wb(',');
                if (pretty) try self.indentPretty();
                try self.write(item);
            }
            self.depth -= 1;
            if (pretty) try self.indentPretty();
            try self.wb(']');
        }

        fn indentPretty(self: *Self) !void {
            const sp = self.opts.whitespace.?;
            try self.wb('\n');
            const total: usize = @as(usize, self.depth) * @as(usize, sp);
            const spaces = " " ** (MAX_DEPTH * 8);
            try self.wa(spaces[0..@min(total, spaces.len)]);
        }

        fn writeEscaped(self: *Self, s: []const u8) !void {
            const N = comptime laneN();
            const ctrl_splat: LaneVec() = @splat(@as(u8, 0x20));
            const dq_splat: LaneVec() = @splat(@as(u8, '"'));
            const bs_splat: LaneVec() = @splat(@as(u8, '\\'));
            const hi_splat: LaneVec() = @splat(@as(u8, 0x7E));
            const escape_unicode = self.opts.escape_unicode;
            const hex = "0123456789ABCDEF";

            var pos: usize = 0;

            while (pos + N <= s.len) {
                if (self.bpos > self.buf.len - N - 6) try self.flush();

                const chunk: LaneVec() = s[pos..][0..N].*;
                var bad = (chunk < ctrl_splat) | (chunk == dq_splat) | (chunk == bs_splat);
                if (escape_unicode) bad = bad | (chunk > hi_splat);
                const mask = @as(LaneMask(), @bitCast(@intFromBool(bad)));

                if (mask == 0) {
                    @memcpy(self.buf[self.bpos .. self.bpos + N], s[pos .. pos + N]);
                    self.bpos += N;
                    pos += N;
                } else {
                    const hit: usize = @ctz(mask);
                    if (hit > 0) {
                        @memcpy(self.buf[self.bpos .. self.bpos + hit], s[pos .. pos + hit]);
                        self.bpos += hit;
                    }
                    const b = s[pos + hit];
                    const e = ESC_TABLE[b];
                    if (e == 0 and !(escape_unicode and b > 0x7E)) {
                        self.buf[self.bpos] = b;
                        self.bpos += 1;
                    } else if (e != 0 and e != 0xFF) {
                        self.buf[self.bpos] = '\\';
                        self.buf[self.bpos + 1] = e;
                        self.bpos += 2;
                    } else {
                        self.buf[self.bpos] = '\\';
                        self.buf[self.bpos + 1] = 'u';
                        self.buf[self.bpos + 2] = '0';
                        self.buf[self.bpos + 3] = '0';
                        self.buf[self.bpos + 4] = hex[b >> 4];
                        self.buf[self.bpos + 5] = hex[b & 0xF];
                        self.bpos += 6;
                    }
                    pos += hit + 1;
                }
            }

            if (pos < s.len) {
                if (self.bpos > self.buf.len - N - 6) try self.flush();
                const rem = s.len - pos;
                var pad: [32]u8 = @splat(' ');
                @memcpy(pad[0..rem], s[pos..]);
                const pchunk: LaneVec() = pad[0..N].*;
                var pbad = (pchunk < ctrl_splat) | (pchunk == dq_splat) | (pchunk == bs_splat);
                if (escape_unicode) pbad = pbad | (pchunk > hi_splat);
                const pmask = @as(LaneMask(), @bitCast(@intFromBool(pbad)));

                if (pmask == 0) {
                    @memcpy(self.buf[self.bpos .. self.bpos + rem], s[pos..]);
                    self.bpos += rem;
                    return;
                }

                const hit: usize = @ctz(pmask);
                if (hit < rem) {
                    if (hit > 0) {
                        @memcpy(self.buf[self.bpos .. self.bpos + hit], s[pos .. pos + hit]);
                        self.bpos += hit;
                    }
                    const b = s[pos + hit];
                    const e = ESC_TABLE[b];
                    if (e == 0 and !(escape_unicode and b > 0x7E)) {
                        self.buf[self.bpos] = b;
                        self.bpos += 1;
                    } else if (e != 0 and e != 0xFF) {
                        self.buf[self.bpos] = '\\';
                        self.buf[self.bpos + 1] = e;
                        self.bpos += 2;
                    } else {
                        self.buf[self.bpos] = '\\';
                        self.buf[self.bpos + 1] = 'u';
                        self.buf[self.bpos + 2] = '0';
                        self.buf[self.bpos + 3] = '0';
                        self.buf[self.bpos + 4] = hex[b >> 4];
                        self.buf[self.bpos + 5] = hex[b & 0xF];
                        self.bpos += 6;
                    }
                    pos += hit + 1;
                    while (pos < s.len) {
                        if (self.bpos > self.buf.len - 6) try self.flush();
                        const b2 = s[pos];
                        const e2 = ESC_TABLE[b2];
                        if (e2 == 0 and !(escape_unicode and b2 > 0x7E)) {
                            self.buf[self.bpos] = b2;
                            self.bpos += 1;
                        } else if (e2 != 0 and e2 != 0xFF) {
                            self.buf[self.bpos] = '\\';
                            self.buf[self.bpos + 1] = e2;
                            self.bpos += 2;
                        } else {
                            self.buf[self.bpos] = '\\';
                            self.buf[self.bpos + 1] = 'u';
                            self.buf[self.bpos + 2] = '0';
                            self.buf[self.bpos + 3] = '0';
                            self.buf[self.bpos + 4] = hex[b2 >> 4];
                            self.buf[self.bpos + 5] = hex[b2 & 0xF];
                            self.bpos += 6;
                        }
                        pos += 1;
                    }
                } else {
                    @memcpy(self.buf[self.bpos .. self.bpos + rem], s[pos..]);
                    self.bpos += rem;
                }
            }
        }
    };
}
