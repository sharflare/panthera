const std = @import("std");
const Allocator = std.mem.Allocator;

pub const MAX_DEPTH: u32 = 128;
pub const MAX_TOKEN_LEN: usize = 1 << 20;
pub const MAX_INPUT_BYTES: usize = 1 << 30;

pub const Error = error{
    UnexpectedToken,
    InvalidCharacter,
    InvalidEscape,
    InvalidUtf8,
    InvalidNumber,
    MaxDepthExceeded,
    TokenTooLong,
    InputTooLarge,
    UnexpectedEndOfInput,
    DuplicateField,
    UnknownField,
    MissingField,
    TypeMismatch,
    Overflow,
    OutOfMemory,
};

pub const StringifyOptions = struct {
    whitespace: ?u8 = null,
    emit_null_optional_fields: bool = true,
    escape_unicode: bool = false,
};

pub const ParseOptions = struct {
    reject_unknown_fields: bool = false,
    require_all_fields: bool = false,
    max_depth: u32 = MAX_DEPTH,
    duplicate_field_behavior: enum { use_last, reject } = .use_last,
};

pub const ObjectMap = std.StringArrayHashMapUnmanaged(Value);
pub const Array = std.ArrayListUnmanaged(Value);

/// Dynamically-typed JSON value. Use `parseValue` to produce one, `Value.deinit` to free it.
pub const Value = union(enum) {
    null,
    bool: bool,
    integer: i64,
    float: f64,
    number_string: []const u8,
    string: []const u8,
    array: Array,
    object: ObjectMap,

    /// Free a `Value` and all memory it owns.
    pub fn deinit(self: *Value, allocator: Allocator) void {
        switch (self.*) {
            .array => |*a| {
                for (a.items) |*item| item.deinit(allocator);
                a.deinit(allocator);
            },
            .object => |*o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    allocator.free(entry.key_ptr.*);
                    entry.value_ptr.deinit(allocator);
                }
                o.deinit(allocator);
            },
            .string => |s| allocator.free(s),
            .number_string => |s| allocator.free(s),
            else => {},
        }
    }
};
