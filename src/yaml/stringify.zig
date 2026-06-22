const std = @import("std");

const types = @import("../types.zig");
const simd = @import("../simd.zig");
const format = @import("../format.zig");

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
                .int, .comptime_int => try format.writeInt(self, @as(i64, @intCast(value))),
                .float, .comptime_float => try format.writeFloat(self, @as(f64, @floatCast(value))),
                .optional => if (value) |v| try self.write(v) else try self.wa("null"),
                .@"enum" => {
                    try self.wb('\'');
                    try self.writeEscaped(@tagName(value));
                    try self.wb('\'');
                },
                .pointer => |ptr| switch (ptr.size) {
                    .slice => if (ptr.child == u8) {
                        try self.writeStringScalar(value);
                    } else try self.writeArray(value),
                    .one => try self.write(value.*),
                    else => @compileError("panthera yaml stringify: unsupported pointer"),
                },
                .array => |arr| if (arr.child == u8) {
                    try self.writeStringScalar(&value);
                } else try self.writeArray(&value),
                .@"struct" => |st| {
                    const pretty = self.opts.whitespace != null;
                    if (!pretty) {
                        try self.wb('{');
                        var first = true;
                        inline for (st.fields) |field| {
                            const fv = @field(value, field.name);
                            if (!first) try self.wa(", ");
                            first = false;
                            try self.wb('"');
                            try self.writeEscaped(field.name);
                            try self.wa("\": ");
                            try self.write(fv);
                        }
                        try self.wb('}');
                        return;
                    }
                    self.depth += 1;
                    inline for (st.fields) |field| {
                        const fv = @field(value, field.name);
                        try self.wb('\n');
                        try self.writeIndent();
                        try self.writeEscaped(field.name);
                        try self.wa(": ");
                        try self.writeBlockValue(fv);
                    }
                    self.depth -= 1;
                },
                .@"union" => |un| {
                    if (T == Value) {
                        try self.writeValue(value);
                        return;
                    }
                    if (un.tag_type == null) @compileError("panthera: bare union not supported");
                    try self.wb('{');
                    try self.wb('"');
                    try self.writeEscaped(@tagName(value));
                    try self.wa("\": ");
                    switch (value) {
                        inline else => |pl| try self.write(pl),
                    }
                    try self.wb('}');
                },
                else => @compileError("panthera yaml stringify: unsupported type " ++ @typeName(T)),
            }
        }

        fn writeBlockValue(self: *Self, value: anytype) !void {
            const T = @TypeOf(value);
            const ti = @typeInfo(T);
            if (ti == .@"struct") {
                const st = ti.@"struct";
                self.depth += 1;
                inline for (st.fields) |field| {
                    const fv = @field(value, field.name);
                    try self.wb('\n');
                    try self.writeIndent();
                    try self.writeEscaped(field.name);
                    try self.wa(": ");
                    try self.writeBlockValue(fv);
                }
                self.depth -= 1;
            } else {
                try self.write(value);
            }
        }

        fn writeStringScalar(self: *Self, s: []const u8) !void {
            const needs_quoting = s.len == 0 or
                s[0] == ' ' or s[0] == '\t' or
                s[s.len - 1] == ' ' or
                std.mem.indexOfAny(u8, s, ":,[]{}#&*!|>'\"%@`") != null;
            if (!needs_quoting) {
                try self.wa(s);
                return;
            }
            const has_single_quote = std.mem.indexOfScalar(u8, s, '\'') != null;
            const has_double_quote = std.mem.indexOfScalar(u8, s, '"') != null;
            const has_escape = std.mem.indexOfAny(u8, s, "\n\r\t\x00\x08\x0C") != null;

            if (has_escape or (has_single_quote and has_double_quote)) {
                try self.wb('"');
                try self.writeEscaped(s);
                try self.wb('"');
            } else if (!has_single_quote) {
                try self.wb('\'');
                try self.wa(s);
                try self.wb('\'');
            } else {
                try self.wb('"');
                try self.writeEscaped(s);
                try self.wb('"');
            }
        }

        fn writeIndent(self: *Self) !void {
            const sp = self.opts.whitespace.?;
            const total: usize = @as(usize, self.depth) * @as(usize, sp);
            const spaces = " " ** (MAX_DEPTH * 8);
            try self.wa(spaces[0..@min(total, spaces.len)]);
        }

        fn writeArray(self: *Self, slice: anytype) !void {
            if (slice.len == 0) {
                try self.wa("[]");
                return;
            }
            const pretty = self.opts.whitespace != null;
            if (!pretty) {
                try self.wb('[');
                try self.write(slice[0]);
                for (slice[1..]) |item| {
                    try self.wa(", ");
                    try self.write(item);
                }
                try self.wb(']');
                return;
            }
            self.depth += 1;
            for (slice) |item| {
                try self.wb('\n');
                try self.writeIndent();
                try self.wa("- ");
                try self.write(item);
            }
            self.depth -= 1;
        }

        fn writeValue(self: *Self, v: Value) !void {
            switch (v) {
                .null => try self.wa("null"),
                .bool => |b| try self.wa(if (b) "true" else "false"),
                .integer => |i| try format.writeInt(self, i),
                .float => |f| try format.writeFloat(self, f),
                .number_string => |s| try self.wa(s),
                .string => |s| {
                    try self.writeStringScalar(s);
                },
                .array => |a| {
                    if (a.items.len == 0) {
                        try self.wa("[]");
                        return;
                    }
                    const pretty = self.opts.whitespace != null;
                    if (!pretty) {
                        try self.wb('[');
                        try self.writeValue(a.items[0]);
                        for (a.items[1..]) |item| {
                            try self.wa(", ");
                            try self.writeValue(item);
                        }
                        try self.wb(']');
                        return;
                    }
                    self.depth += 1;
                    for (a.items) |item| {
                        try self.wb('\n');
                        try self.writeIndent();
                        try self.wa("- ");
                        try self.writeValue(item);
                    }
                    self.depth -= 1;
                },
                .object => |o| {
                    if (o.count() == 0) {
                        try self.wa("{}");
                        return;
                    }
                    const keys = o.keys();
                    const vals = o.values();
                    const pretty = self.opts.whitespace != null;
                    if (!pretty) {
                        try self.wb('{');
                        var i: usize = 0;
                        while (i < keys.len) : (i += 1) {
                            if (i > 0) try self.wa(", ");
                            try self.wb('"');
                            try self.writeEscaped(keys[i]);
                            try self.wa("\": ");
                            try self.writeValue(vals[i]);
                        }
                        try self.wb('}');
                        return;
                    }
                    self.depth += 1;
                    for (keys, vals) |k, val| {
                        try self.wb('\n');
                        try self.writeIndent();
                        try self.writeEscaped(k);
                        try self.wa(": ");
                        try self.writeValue(val);
                    }
                    self.depth -= 1;
                },
            }
        }

        const YAML_ESC: [256]u8 = blk: {
            var t = [_]u8{0} ** 256;
            t['\\'] = '\\';
            t['"'] = '"';
            t['\n'] = 'n';
            t['\r'] = 'r';
            t['\t'] = 't';
            t[0] = '0';
            break :blk t;
        };

        fn writeEscaped(self: *Self, s: []const u8) !void {
            const N = comptime laneN();
            const bs: LaneVec() = @splat('\\');
            const dq: LaneVec() = @splat('"');
            const nl: LaneVec() = @splat('\n');
            const cr: LaneVec() = @splat('\r');
            const tb: LaneVec() = @splat('\t');
            const nu: LaneVec() = @splat(0);

            var pos: usize = 0;

            while (pos < s.len) {
                if (pos + N <= s.len) {
                    if (self.bpos > self.buf.len - N - 2) try self.flush();

                    const chunk: LaneVec() = s[pos..][0..N].*;
                    const hit = (chunk == bs) | (chunk == dq) | (chunk == nl) | (chunk == cr) | (chunk == tb) | (chunk == nu);
                    const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));

                    if (mask == 0) {
                        @memcpy(self.buf[self.bpos .. self.bpos + N], s[pos .. pos + N]);
                        self.bpos += N;
                        pos += N;
                        continue;
                    }

                    const off = @ctz(mask);
                    if (off > 0) {
                        @memcpy(self.buf[self.bpos .. self.bpos + off], s[pos .. pos + off]);
                        self.bpos += off;
                    }
                    const c = s[pos + off];
                    const e = YAML_ESC[c];
                    self.buf[self.bpos] = '\\';
                    self.buf[self.bpos + 1] = e;
                    self.bpos += 2;
                    pos += off + 1;
                } else {
                    if (self.bpos > self.buf.len - N - 2) try self.flush();

                    const rem = s.len - pos;
                    var pad: [32]u8 = @splat(' ');
                    @memcpy(pad[0..rem], s[pos..]);
                    const pchunk: LaneVec() = pad[0..N].*;
                    const phit = (pchunk == bs) | (pchunk == dq) | (pchunk == nl) | (pchunk == cr) | (pchunk == tb) | (pchunk == nu);
                    const pmask = @as(LaneMask(), @bitCast(@intFromBool(phit)));

                    if (pmask == 0) {
                        @memcpy(self.buf[self.bpos .. self.bpos + rem], s[pos..]);
                        self.bpos += rem;
                        break;
                    }

                    const off = @ctz(pmask);
                    if (off < rem) {
                        if (off > 0) {
                            @memcpy(self.buf[self.bpos .. self.bpos + off], s[pos .. pos + off]);
                            self.bpos += off;
                        }
                        const c = s[pos + off];
                        const e = YAML_ESC[c];
                        self.buf[self.bpos] = '\\';
                        self.buf[self.bpos + 1] = e;
                        self.bpos += 2;
                        pos += off + 1;
                    } else {
                        @memcpy(self.buf[self.bpos .. self.bpos + rem], s[pos..]);
                        self.bpos += rem;
                        break;
                    }
                }
            }
        }
    };
}
