const std = @import("std");

const types = @import("../../types.zig");
const format = @import("../../format.zig");
const simd = @import("../../simd.zig");

const Error = types.Error;
const StringifyOptions = types.StringifyOptions;
const Value = types.Value;

const LaneVec = simd.LaneVec;
const LaneMask = simd.LaneMask;
const laneN = simd.laneN;

pub fn stringify(value: anytype, opts: StringifyOptions, writer: *std.Io.Writer) !void {
    var w = Writer{ .writer = writer, .opts = opts };
    try w.writeAny(value);
}

pub const Stringifier = struct {
    writer: *std.Io.Writer,
    opts: StringifyOptions,
    indent: u32 = 0,

    pub fn init(writer: *std.Io.Writer, opts: StringifyOptions) Stringifier {
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
    writer: *std.Io.Writer,
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

    fn writeEscapedAttr(self: *Writer, s: []const u8) !void {
        const N = comptime laneN();
        const amp: LaneVec() = @splat(@as(u8, '&'));
        const lt: LaneVec() = @splat(@as(u8, '<'));
        const gt: LaneVec() = @splat(@as(u8, '>'));
        const dq: LaneVec() = @splat(@as(u8, '"'));

        var i: usize = 0;
        while (i + N <= s.len) {
            const chunk: LaneVec() = s[i..][0..N].*;
            const need = (chunk == amp) | (chunk == lt) | (chunk == gt) | (chunk == dq);
            const mask = @as(LaneMask(), @bitCast(@intFromBool(need)));
            if (mask == 0) {
                try self.writeAll(s[i..][0..N]);
                i += N;
                continue;
            }
            const first = @ctz(mask);
            if (first > 0) {
                try self.writeAll(s[i..][0..first]);
                i += first;
            }
            switch (s[i]) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                '"' => try self.writeAll("&quot;"),
                else => unreachable,
            }
            i += 1;
        }
        while (i < s.len) {
            switch (s[i]) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                '"' => try self.writeAll("&quot;"),
                else => try self.writeByte(s[i]),
            }
            i += 1;
        }
    }

    fn writeEscapedText(self: *Writer, s: []const u8) !void {
        const N = comptime laneN();
        const amp: LaneVec() = @splat(@as(u8, '&'));
        const lt: LaneVec() = @splat(@as(u8, '<'));
        const gt: LaneVec() = @splat(@as(u8, '>'));

        var i: usize = 0;
        while (i + N <= s.len) {
            const chunk: LaneVec() = s[i..][0..N].*;
            const need = (chunk == amp) | (chunk == lt) | (chunk == gt);
            const mask = @as(LaneMask(), @bitCast(@intFromBool(need)));
            if (mask == 0) {
                try self.writeAll(s[i..][0..N]);
                i += N;
                continue;
            }
            const first = @ctz(mask);
            if (first > 0) {
                try self.writeAll(s[i..][0..first]);
                i += first;
            }
            switch (s[i]) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                else => unreachable,
            }
            i += 1;
        }
        while (i < s.len) {
            switch (s[i]) {
                '&' => try self.writeAll("&amp;"),
                '<' => try self.writeAll("&lt;"),
                '>' => try self.writeAll("&gt;"),
                else => try self.writeByte(s[i]),
            }
            i += 1;
        }
    }

    fn writeAny(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try self.writeAll(if (v) "true" else "false"),
            .int => try format.writeInt(self, v),
            .float => try format.writeFloat(self, v),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.writeEscapedText(v);
                } else {
                    @compileError("panthera xml: unsupported type " ++ @typeName(T));
                }
            },
            .@"struct" => try self.writeStruct(v),
            .@"union" => {
                if (T == Value) return writeValue(self, &v);
                @compileError("panthera xml: unsupported union type " ++ @typeName(T));
            },
            .optional => {
                if (v) |val| try self.writeAny(val);
            },
            else => @compileError("panthera xml: unsupported type " ++ @typeName(T)),
        }
    }

    fn writeStruct(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        const name = comptime blk: {
            const full = @typeName(T);
            const dot = std.mem.lastIndexOfScalar(u8, full, '.') orelse 0;
            break :blk full[dot + if (dot > 0) 1 else 0 ..];
        };
        try self.writeStructAs(name, v);
    }

    fn writeStructAs(self: *Writer, name: []const u8, v: anytype) !void {
        const T = @TypeOf(v);
        const fields = @typeInfo(T).@"struct".fields;

        try self.writeByte('<');
        try self.writeAll(name);

        inline for (fields) |field| {
            const is_attr = comptime @typeInfo(field.type) == .@"struct" and
                @hasDecl(field.type, "is_xml_attr");
            if (is_attr) {
                try self.writeByte(' ');
                try self.writeAll(field.name);
                try self.writeAll("=\"");
                try self.writeValueAsAttr(@field(v, field.name).value);
                try self.writeByte('"');
            }
        }

        var has_children = false;
        inline for (fields) |field| {
            const is_attr = comptime @typeInfo(field.type) == .@"struct" and
                @hasDecl(field.type, "is_xml_attr");
            if (!is_attr) {
                has_children = true;
            }
        }

        if (!has_children) {
            try self.writeAll("/>");
            return;
        }

        try self.writeByte('>');

        inline for (fields) |field| {
            const is_attr = comptime @typeInfo(field.type) == .@"struct" and
                @hasDecl(field.type, "is_xml_attr");
            if (is_attr) continue;
            try self.writeFieldElement(field.name, @field(v, field.name));
        }

        try self.writeAll("</");
        try self.writeAll(name);
        try self.writeByte('>');
    }

    fn writeValueAsAttr(self: *Writer, v: anytype) !void {
        const T = @TypeOf(v);
        switch (@typeInfo(T)) {
            .bool => try self.writeAll(if (v) "true" else "false"),
            .int => try format.writeInt(self, v),
            .float => try format.writeFloat(self, v),
            .pointer => |ptr| {
                if (ptr.size == .slice and ptr.child == u8) {
                    try self.writeEscapedAttr(v);
                }
            },
            else => {},
        }
    }

    fn writeFieldElement(self: *Writer, name: []const u8, value: anytype) !void {
        const T = @TypeOf(value);
        switch (@typeInfo(T)) {
            .pointer => |ptr| {
                if (ptr.size == .slice) {
                    if (ptr.child == u8) {
                        try self.writeByte('<');
                        try self.writeAll(name);
                        try self.writeByte('>');
                        try self.writeEscapedText(value);
                        try self.writeAll("</");
                        try self.writeAll(name);
                        try self.writeByte('>');
                        return;
                    }
                    // Slice of elements
                    for (value) |*item| {
                        try self.writeByte('<');
                        try self.writeAll(name);
                        try self.writeByte('>');
                        try self.writeAny(item.*);
                        try self.writeAll("</");
                        try self.writeAll(name);
                        try self.writeByte('>');
                    }
                    return;
                }
            },
            .@"struct" => {
                try self.writeStructAs(name, value);
                return;
            },
            else => {},
        }
        // Default: wrap in element
        try self.writeByte('<');
        try self.writeAll(name);
        try self.writeByte('>');
        try self.writeAny(value);
        try self.writeAll("</");
        try self.writeAll(name);
        try self.writeByte('>');
    }

    fn writeValue(self: *Writer, v: *const Value) !void {
        switch (v.*) {
            .null => {},
            .bool => |b| try self.writeAll(if (b) "true" else "false"),
            .integer => |i| try format.writeInt(self, i),
            .float => |f| try format.writeFloat(self, f),
            .number_string => |s| try self.writeAll(s),
            .string => |s| try self.writeEscapedText(s),
            .array => |a| {
                for (a.items) |*item| try self.writeValue(item);
            },
            .object => |o| {
                const name = o.get("name") orelse return error.UnexpectedToken;
                const name_str = if (name == .string) name.string else return error.UnexpectedToken;
                const attrs = o.get("attrs") orelse return error.UnexpectedToken;
                const children = o.get("children") orelse return error.UnexpectedToken;

                try self.writeByte('<');
                try self.writeAll(name_str);

                if (attrs == .object) {
                    var ait = attrs.object.iterator();
                    while (ait.next()) |entry| {
                        try self.writeByte(' ');
                        try self.writeAll(entry.key_ptr.*);
                        try self.writeAll("=\"");
                        switch (entry.value_ptr.*) {
                            .string => |s| try self.writeEscapedAttr(s),
                            else => {},
                        }
                        try self.writeByte('"');
                    }
                }

                if (children == .array and children.array.items.len > 0) {
                    try self.writeByte('>');
                    for (children.array.items) |*child| {
                        if (child.* == .string) {
                            try self.writeEscapedText(child.string);
                        } else {
                            try self.writeValue(child);
                        }
                    }
                    try self.writeAll("</");
                    try self.writeAll(name_str);
                    try self.writeByte('>');
                } else {
                    try self.writeAll("/>");
                }
            },
        }
    }
};
