const std = @import("std");

/// The core value type for the shell language.
/// Represents one of four types: string, integer, float, or list.
pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    list: []const ?Value,

    pub fn isNumber(self: Value) bool {
        return self == .int or self == .float;
    }

    pub fn getI(self: Value) error{TypeMismatch}!i64 {
        return switch (self) {
            .int => |int_val| int_val,
            .float => |float_val| @intFromFloat(float_val),
            else => error.TypeMismatch,
        };
    }

    pub fn getF(self: Value) error{TypeMismatch}!f64 {
        return switch (self) {
            .float => |float_val| float_val,
            .int => |int_val| @floatFromInt(int_val),
            else => error.TypeMismatch,
        };
    }

    pub fn getS(self: Value, buf: []u8) []const u8 {
        return switch (self) {
            .string => |str| str,
            .int => |int_val| std.fmt.bufPrint(buf, "{d}", .{int_val}) catch "?",
            .float => |float_val| std.fmt.bufPrint(buf, "{d}", .{float_val}) catch "?",
            .list => |items| {
                var writer = std.io.fixedBufferStream(buf);
                writer.writer().writeAll("[ ") catch return "?";
                for (items, 0..) |item, i| {
                    if (i > 0) writer.writer().writeAll(", ") catch return "?";
                    if (item) |inner_val| {
                        var inner_buf: [64]u8 = undefined;
                        const rendered = inner_val.getS(&inner_buf);
                        writer.writer().writeAll(rendered) catch return "?";
                    } else {
                        writer.writer().writeAll("none") catch return "?";
                    }
                }
                writer.writer().writeAll(" ]") catch return "?";
                return writer.getWritten();
            },
        };
    }

    pub fn getL(self: Value) error{TypeMismatch}![]const ?Value {
        return switch (self) {
            .list => |items| items,
            else => error.TypeMismatch,
        };
    }

    pub fn eql(lhs: Value, rhs: Value) bool {
        const Tag = std.meta.Tag(Value);
        const lhs_tag: Tag = lhs;
        const rhs_tag: Tag = rhs;

        if (lhs_tag != rhs_tag) return false;

        return switch (lhs) {
            .string => |lhs_str| std.mem.eql(u8, lhs_str, rhs.string),
            .int => |lhs_int| lhs_int == rhs.int,
            .float => |lhs_float| lhs_float == rhs.float,
            .list => |lhs_items| {
                const rhs_items = rhs.list;
                if (lhs_items.len != rhs_items.len) return false;
                for (lhs_items, rhs_items) |lhs_item, rhs_item| {
                    const lhs_exists = lhs_item != null;
                    const rhs_exists = rhs_item != null;
                    if (lhs_exists != rhs_exists) return false;
                    if (lhs_exists and rhs_exists) {
                        if (!eql(lhs_item.?, rhs_item.?)) return false;
                    }
                }
                return true;
            },
        };
    }

    pub fn format(self: Value, comptime _: []const u8, _: std.fmt.FormatOptions, writer: anytype) !void {
        switch (self) {
            .string => |str| try writer.writeAll(str),
            .int => |int_val| try writer.print("{d}", .{int_val}),
            .float => |float_val| try writer.print("{d}", .{float_val}),
            .list => |items| {
                try writer.writeAll("[ ");
                for (items, 0..) |item, i| {
                    if (i > 0) try writer.writeAll(", ");
                    if (item) |inner_val| {
                        try inner_val.format("", .{}, writer);
                    } else {
                        try writer.writeAll("none");
                    }
                }
                try writer.writeAll(" ]");
            },
        }
    }
};

/// Truthy/falsy convention: "some" is truthy, null is falsy.
pub const SOME: Value = .{ .string = "some" };
pub const NONE: ?Value = null;

pub fn some() ?Value {
    return SOME;
}

pub fn toCondition(condition: bool) ?Value {
    return if (condition) some() else NONE;
}

// ── Tests ──

test "value int" {
    const val: Value = .{ .int = 42 };
    try std.testing.expectEqual(@as(i64, 42), try val.getI());
    try std.testing.expectEqual(@as(f64, 42.0), try val.getF());
}

test "value float" {
    const val: Value = .{ .float = 3.14 };
    try std.testing.expectEqual(@as(f64, 3.14), try val.getF());
    try std.testing.expectEqual(@as(i64, 3), try val.getI());
}

test "value string" {
    const val: Value = .{ .string = "hello" };
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("hello", val.getS(&buf));
    try std.testing.expectError(error.TypeMismatch, val.getI());
}

test "value list" {
    const items = [_]?Value{
        .{ .int = 1 },
        .{ .int = 2 },
        null,
    };
    const val: Value = .{ .list = &items };
    const list = try val.getL();
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqual(@as(i64, 1), list[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), list[1].?.int);
    try std.testing.expect(list[2] == null);
}

test "value equality" {
    const first: Value = .{ .int = 5 };
    const same: Value = .{ .int = 5 };
    const different: Value = .{ .int = 6 };
    const different_type: Value = .{ .string = "5" };

    try std.testing.expect(first.eql(same));
    try std.testing.expect(!first.eql(different));
    try std.testing.expect(!first.eql(different_type));
}

test "condition" {
    try std.testing.expect(toCondition(true) != null);
    try std.testing.expect(toCondition(false) == null);
}
