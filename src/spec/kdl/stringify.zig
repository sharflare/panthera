const std = @import("std");

const types = @import("../../types.zig");
const writeInt = @import("../../format.zig").writeInt;
const writeFloat = @import("../../format.zig").writeFloat;
const simd = @import("../../simd.zig");

const Error = types.Error;
const StringifyOptions = types.StringifyOptions;
const Value = types.Value;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var w = Writer{ .writer = writer.*, .opts = opts };
    try w.writeAny(value);
}

pub const Stringifier = struct {
    writer: std.Io.Writer,
    opts: StringifyOptions,
    indent: u32 = 0,

    pub fn init(writer: std.Io.Writer, opts: StringifyOptions) Stringifier {
        return .{ .writer = writer, .opts = opts };
    }

    pub fn writeAll(self: *Stringifier, s: []const u8) !void {
        try self.writer.writeAll(s);
    }

    pub fn writeByte(self: *Stringifier, b: u8) !void {
        try self.writer.writeByte(b);
    }
};

const Writer = struct {
    writer: std.Io.Writer,
    opts: StringifyOptions,
    indent: u32 = 0,

    pub fn writeAll(self: *Writer, s: []const u8) !void {
        try self.writer.writeAll(s);
    }

    pub fn writeByte(self: *Writer, b: u8) !void {
        try self.writer.writeByte(b);
    }

    fn writeIndent(self: *Writer) !void {
        if (self.opts.whitespace) |ws| {
            var i: u32 = 0;
            while (i < self.indent) : (i += 1) {
                try self.writeByte(ws);
            }
        }
    }

    fn writeNewline(self: *Writer) !void {
        if (self.opts.whitespace) |_| {
            try self.writeByte('\n');
        }
    }

    fn writeEscapedString(self: *Writer, s: []const u8) !void {
        try self.writeByte('"');
        const N = comptime laneN();
        const dq: LaneVec() = @splat(@as(u8, '"'));
        const bs: LaneVec() = @splat(@as(u8, '\\'));
        const nl: LaneVec() = @splat(@as(u8, '\n'));
        const cr: LaneVec() = @splat(@as(u8, '\r'));
        const tb: LaneVec() = @splat(@as(u8, '\t'));

        var i: usize = 0;
        while (i + N <= s.len) {
            const chunk: LaneVec() = s[i..][0..N].*;
            const need_escape = (chunk == dq) | (chunk == bs) | (chunk == nl) | (chunk == cr) | (chunk == tb);
            const mask = @as(LaneMask(), @bitCast(@intFromBool(need_escape)));
            if (mask == 0) {
                try self.writeAll(s[i..][0..N]);
                i += N;
                continue;
            }
            const first_escape = @ctz(mask);
            if (first_escape > 0) {
                try self.writeAll(s[i..][0..first_escape]);
                i += first_escape;
            }
            switch (s[i]) {
                '"' => try self.writeAll("\\\""),
                '\\' => try self.writeAll("\\\\"),
                '\n' => try self.writeAll("\\n"),
                '\r' => try self.writeAll("\\r"),
                '\t' => try self.writeAll("\\t"),
                else => unreachable,
            }
            i += 1;
        }
        while (i < s.len) {
            switch (s[i]) {
                '"' => try self.writeAll("\\\""),
                '\\' => try self.writeAll("\\\\"),
                '\n' => try self.writeAll("\\n"),
                '\r' => try self.writeAll("\\r"),
                '\t' => try self.writeAll("\\t"),
                else => try self.writeByte(s[i]),
            }
            i += 1;
        }
        try self.writeByte('"');
    }

    fn writeAny(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try self.writeAll(if (v) "#true" else "#false"),
            .int => try writeInt(self, v),
            .float => try writeFloat(self, v),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.writeEscapedString(v);
                } else {
                    @compileError("panthera kdl: unsupported type " ++ @typeName(T));
                }
            },
            .@"struct" => try self.writeStruct(v),
            .@"union" => {
                if (T == Value) return writeValue(self, &v);
                @compileError("panthera kdl: unsupported union type " ++ @typeName(T));
            },
            .optional => {
                if (v) |val| try self.writeAny(val) else try self.writeAll("#null");
            },
            else => @compileError("panthera kdl: unsupported type " ++ @typeName(T)),
        }
    }

    fn writeStruct(self: *Writer, v: anytype) !void {
        const fields = @typeInfo(@TypeOf(v)).@"struct".fields;
        inline for (fields) |field| {
            try self.writeAny(@field(v, field.name));
            try self.writeByte(' ');
        }
    }

    fn writeValue(self: *Writer, v: *const Value) !void {
        switch (v.*) {
            .null => try self.writeAll("#null"),
            .bool => |b| try self.writeAll(if (b) "#true" else "#false"),
            .integer => |i| try writeInt(self, i),
            .float => |f| try writeFloat(self, f),
            .number_string => |s| try self.writeAll(s),
            .string => |s| try self.writeEscapedString(s),
            .array => |a| {
                for (a.items, 0..) |*item, idx| {
                    try self.writeValue(item);
                    if (idx + 1 < a.items.len) try self.writeByte(' ');
                }
            },
            .object => |o| {
                const name = o.get("name") orelse return error.UnexpectedToken;
                try self.writeValue(&name);
                if (o.get("args")) |args_v| {
                    if (args_v == .array and args_v.array.items.len > 0) {
                        try self.writeByte(' ');
                        try self.writeValue(&args_v);
                    }
                }
                if (o.get("props")) |props_v| {
                    if (props_v == .object) {
                        var it = props_v.object.iterator();
                        while (it.next()) |entry| {
                            try self.writeByte(' ');
                            try self.writeEscapedString(entry.key_ptr.*);
                            try self.writeByte('=');
                            try self.writeValue(entry.value_ptr);
                        }
                    }
                }
                if (o.get("children")) |children_v| {
                    if (children_v == .array and children_v.array.items.len > 0) {
                        try self.writeAll(" {\n");
                        self.indent += 1;
                        for (children_v.array.items) |*child| {
                            try self.writeIndent();
                            try self.writeValue(child);
                            try self.writeAll(";\n");
                        }
                        self.indent -= 1;
                        try self.writeIndent();
                        try self.writeAll("}");
                    }
                }
            },
        }
    }
};
