const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try registry.registerOperation(allocator, "type",   Operation.fromFn(typeOp));
    try registry.registerOperation(allocator, "int",    Operation.fromFn(intOp));
    try registry.registerOperation(allocator, "float",  Operation.fromFn(floatOp));
    try registry.registerOperation(allocator, "string", Operation.fromFn(stringOp));
}

fn intOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(float_val) },
        .string => |str| {
            const parsed = std.fmt.parseInt(i64, str, 10) catch return null;
            return .{ .int = parsed };
        },
        .list => null,
    };
}

fn floatOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .float => value,
        .int => |int_val| .{ .float = @floatFromInt(int_val) },
        .string => |str| {
            const parsed = std.fmt.parseFloat(f64, str) catch return null;
            return .{ .float = parsed };
        },
        .list => null,
    };
}

fn stringOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .string => value,
        .int, .float, .list => {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            const owned = try args.env.allocator.dupe(u8, str);
            return .{ .string = owned };
        },
    };
}

fn typeOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return .{ .string = switch (value) {
        .int => "int",
        .float => "float",
        .string => "string",
        .list => "list",
    } };
}

// ── Tests ──

const testing = @import("testing.zig");

test "type conversion: int from float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int 3.14");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "type conversion: int from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int \"42\"");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "type conversion: int from invalid string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int \"hello\"");
    try std.testing.expect(result == null);
}

test "type conversion: int from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "int $none");
    try std.testing.expect(result == null);
}

test "type conversion: float from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "float 5");
    try std.testing.expectEqual(@as(f64, 5.0), result.?.float);
}

test "type conversion: float from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "float \"3.14\"");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.?.float, 0.001);
}

test "type conversion: string from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "string 42");
    try std.testing.expectEqualStrings("42", result.?.string);
}

test "type conversion: string from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "string $none");
    try std.testing.expect(result == null);
}

test "type inspection: int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type 42");
    try std.testing.expectEqualStrings("int", result.?.string);
}

test "type inspection: float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type 3.14");
    try std.testing.expectEqualStrings("float", result.?.string);
}

test "type inspection: string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type \"hello\"");
    try std.testing.expectEqualStrings("string", result.?.string);
}

test "type inspection: list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type [1 2]");
    try std.testing.expectEqualStrings("list", result.?.string);
}

test "type inspection: none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "type $none");
    try std.testing.expect(result == null);
}

