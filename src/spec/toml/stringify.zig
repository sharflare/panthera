const std = @import("std");

const types = @import("../../types.zig");
const simd = @import("../../simd.zig");
const writeInt = @import("../../format.zig").writeInt;
const writeFloat = @import("../../format.zig").writeFloat;

const StringifyOptions = types.StringifyOptions;
const Value = types.Value;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var w = Writer{ .writer = writer, .opts = opts };
    try w.writeAny(value);
}

pub const Writer = struct {
    writer: *std.Io.Writer,
    opts: StringifyOptions,
    indent: u32 = 0,
    first_in_table: bool = true,

    pub fn writeAll(self: *Writer, s: []const u8) !void {
        try self.writer.writeAll(s);
    }

    pub fn writeByte(self: *Writer, b: u8) !void {
        try self.writer.writeByte(b);
    }

    fn writeNewline(self: *Writer) !void {
        try self.writeByte('\n');
    }

    fn writeIndent(self: *Writer) !void {
        if (self.opts.whitespace) |ws| {
            var i: u32 = 0;
            while (i < self.indent) : (i += 1) {
                try self.writeByte(ws);
            }
        }
    }

    pub fn writeAny(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try self.writeAll(if (v) "true" else "false"),
            .int, .comptime_int => try writeInt(self, @as(i64, @intCast(v))),
            .float, .comptime_float => try writeFloat(self, @as(f64, @floatCast(v))),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.writeQuotedString(v);
                } else if (ptr.size == .slice) {
                    try self.writeArrayLike(v);
                } else @compileError("unsupported");
            },
            .@"struct" => try self.writeStruct(v),
            .@"union" => {
                if (T == Value) return writeValue(self, &v);
                @compileError("unsupported");
            },
            .optional => if (v) |val| try self.writeAny(val),
            else => @compileError("unsupported type " ++ @typeName(T)),
        }
    }

    fn writeValue(self: *Writer, v: *const Value) !void {
        switch (v.*) {
            .null => {},
            .bool => |b| try self.writeAll(if (b) "true" else "false"),
            .integer => |i| try writeInt(self, i),
            .float => |f| try writeFloat(self, f),
            .number_string => |s| try self.writeAll(s),
            .string => |s| try self.writeQuotedString(s),
            .array => |a| {
                if (a.items.len == 0) {
                    try self.writeAll("[]");
                    return;
                }
                // Check if all items are scalars
                var all_scalar = true;
                for (a.items) |*item| {
                    if (item.* == .object or item.* == .array) {
                        all_scalar = false;
                        break;
                    }
                }
                if (all_scalar) {
                    try self.writeAll("[");
                    for (a.items, 0..) |*item, i| {
                        if (i > 0) try self.writeAll(", ");
                        try self.writeValue(item);
                    }
                    try self.writeAll("]");
                } else {
                    for (a.items) |*item| {
                        try self.writeValue(item);
                        try self.writeNewline();
                    }
                }
            },
            .object => |o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    if (!self.first_in_table) try self.writeNewline();
                    self.first_in_table = false;
                    try self.writeAll(entry.key_ptr.*);
                    try self.writeAll(" = ");
                    try self.writeValue(entry.value_ptr);
                }
            },
        }
    }

    fn writeStruct(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        const fields = @typeInfo(T).@"struct".fields;
        inline for (fields) |field| {
            try self.writeAll(field.name);
            try self.writeAll(" = ");
            try self.writeAny(@field(v, field.name));
            try self.writeNewline();
        }
    }

    fn writeQuotedString(self: *Writer, s: []const u8) !void {
        if (isBareKey(s)) {
            try self.writeAll(s);
            return;
        }

        const needs_escape = hasEscapeChar(s);

        if (needs_escape) {
            try self.writeAll("\"");
            try self.writeEscaped(s);
            try self.writeAll("\"");
        } else {
            try self.writeAll("\"");
            try self.writeAll(s);
            try self.writeAll("\"");
        }
    }

    fn hasEscapeChar(s: []const u8) bool {
        const N = comptime laneN();
        const dq: LaneVec() = @splat(@as(u8, '"'));
        const bs: LaneVec() = @splat(@as(u8, '\\'));
        const nl: LaneVec() = @splat(@as(u8, '\n'));
        const cr: LaneVec() = @splat(@as(u8, '\r'));
        const tb: LaneVec() = @splat(@as(u8, '\t'));
        var pos: usize = 0;
        while (pos + 64 <= s.len) {
            const block: *const [64]u8 = s[pos..][0..64];
            const iters = 64 / N;
            var mask: u64 = 0;
            comptime var lane: usize = 0;
            inline while (lane < iters) : (lane += 1) {
                const chunk: LaneVec() = block[lane * N ..][0..N].*;
                const hit = (chunk == dq) | (chunk == bs) | (chunk == nl) | (chunk == cr) | (chunk == tb);
                const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(hit)));
                mask |= lm << @as(u6, @intCast(lane * N));
            }
            if (mask != 0) return true;
            pos += 64;
        }
        while (pos < s.len) : (pos += 1) {
            switch (s[pos]) {
                '"', '\\', '\n', '\r', '\t' => return true,
                else => {},
            }
        }
        return false;
    }

    fn writeEscaped(self: *Writer, s: []const u8) !void {
        const N = comptime laneN();
        const bs_splat: LaneVec() = @splat(@as(u8, '\\'));
        const dq_splat: LaneVec() = @splat(@as(u8, '"'));
        const nl_splat: LaneVec() = @splat(@as(u8, '\n'));

        var pos: usize = 0;
        while (pos + N <= s.len) {
            const chunk: LaneVec() = s[pos..][0..N].*;
            const hit = (chunk == bs_splat) | (chunk == dq_splat) | (chunk == nl_splat);
            const mask = @as(LaneMask(), @bitCast(@intFromBool(hit)));
            if (mask == 0) {
                try self.writeAll(s[pos..][0..N]);
                pos += N;
                continue;
            }
            const first = @ctz(mask);
            if (first > 0) {
                try self.writeAll(s[pos..][0..first]);
                pos += first;
            }
            switch (s[pos]) {
                '\\' => try self.writeAll("\\\\"),
                '"' => try self.writeAll("\\\""),
                '\n' => try self.writeAll("\\n"),
                else => try self.writeByte(s[pos]),
            }
            pos += 1;
        }
        while (pos < s.len) {
            switch (s[pos]) {
                '\\' => try self.writeAll("\\\\"),
                '"' => try self.writeAll("\\\""),
                '\n' => try self.writeAll("\\n"),
                else => try self.writeByte(s[pos]),
            }
            pos += 1;
        }
    }

    fn writeArrayLike(self: *Writer, slice: anytype) !void {
        if (slice.len == 0) {
            try self.writeAll("[]");
            return;
        }
        try self.writeAll("[");
        for (slice, 0..) |item, i| {
            if (i > 0) try self.writeAll(", ");
            try self.writeAny(item);
        }
        try self.writeAll("]");
    }
};

fn isBareKey(s: []const u8) bool {
    if (s.len == 0) return false;
    const N = comptime laneN();
    const lo_az: LaneVec() = @splat(@as(u8, 'A'));
    const hi_az: LaneVec() = @splat(@as(u8, 'Z'));
    const lo_lc: LaneVec() = @splat(@as(u8, 'a'));
    const hi_lc: LaneVec() = @splat(@as(u8, 'z'));
    const lo_d: LaneVec() = @splat(@as(u8, '0'));
    const hi_d: LaneVec() = @splat(@as(u8, '9'));
    const da: LaneVec() = @splat(@as(u8, '-'));
    const us: LaneVec() = @splat(@as(u8, '_'));
    var pos: usize = 0;
    while (pos + 64 <= s.len) {
        const block: *const [64]u8 = s[pos..][0..64];
        const iters = 64 / N;
        var mask: u64 = 0;
        comptime var lane: usize = 0;
        inline while (lane < iters) : (lane += 1) {
            const chunk: LaneVec() = block[lane * N ..][0..N].*;
            const valid = ((chunk >= lo_az) & (chunk <= hi_az)) |
                ((chunk >= lo_lc) & (chunk <= hi_lc)) |
                ((chunk >= lo_d) & (chunk <= hi_d)) |
                (chunk == da) | (chunk == us);
            const lm: u64 = @as(LaneMask(), @bitCast(@intFromBool(~valid)));
            mask |= lm << @as(u6, @intCast(lane * N));
        }
        if (mask != 0) return false;
        pos += 64;
    }
    while (pos < s.len) : (pos += 1) {
        switch (s[pos]) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_' => {},
            else => return false,
        }
    }
    return true;
}
