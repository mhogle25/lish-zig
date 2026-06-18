const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const helpers = @import("helpers.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Param = exec.Param;
const Allocator = std.mem.Allocator;

const number_fold = [_]Param{ Param.value("a"), Param.variadic("b") };

pub fn register(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    const g = registry.group(allocator, "arithmetic");
    try g.register("+", Operation.fromFn(addOp, .{
        .signature = .{ .params = &number_fold, .returns = "number" },
        .description = "Sum all arguments.",
    }));

    try g.register("-", Operation.fromFn(subtractOp, .{
        .signature = .{ .params = &number_fold, .returns = "number" },
        .description = "Subtract the remaining arguments from the first.",
    }));

    try g.register("*", Operation.fromFn(multiplyOp, .{
        .signature = .{ .params = &number_fold, .returns = "number" },
        .description = "Multiply all arguments.",
    }));

    try g.register("/", Operation.fromFn(divideOp, .{
        .signature = .{ .params = &number_fold, .returns = "number" },
        .description = "Divide the first argument by the rest; integer division truncates and division by zero yields 0.",
    }));

    try g.register("%", Operation.fromFn(moduloOp, .{
        .signature = .{ .params = &number_fold, .returns = "number" },
        .description = "Modulo of the first argument by the rest; modulo by zero yields 0.",
    }));

    try g.register("^", Operation.fromFn(powerOp, .{
        .signature = .{ .params = comptime &.{ Param.value("base"), Param.variadic("exp") }, .returns = "number" },
        .description = "Raise the first argument to each subsequent power, left to right.",
    }));
}

fn addOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, addInt, addFloat);
}
fn addInt(left: i64, right: i64) i64 {
    return left +% right;
}
fn addFloat(left: f64, right: f64) f64 {
    return left + right;
}

fn subtractOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, subInt, subFloat);
}
fn subInt(left: i64, right: i64) i64 {
    return left -% right;
}
fn subFloat(left: f64, right: f64) f64 {
    return left - right;
}

fn multiplyOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, mulInt, mulFloat);
}
fn mulInt(left: i64, right: i64) i64 {
    return left *% right;
}
fn mulFloat(left: f64, right: f64) f64 {
    return left * right;
}

fn divideOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, divInt, divFloat);
}
fn divInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @divTrunc(left, right);
}
fn divFloat(left: f64, right: f64) f64 {
    return left / right;
}

fn moduloOp(args: Args) ExecError!?Value {
    return helpers.numericFold(args, modInt, modFloat);
}
fn modInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @mod(left, right);
}
fn modFloat(left: f64, right: f64) f64 {
    return @mod(left, right);
}

fn powerOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (!accumulator.isNumber()) return args.env.failFmt(.type_mismatch, "'^' expects numbers, got {s}", .{accumulator.typeName()});

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.failFmt(.type_mismatch, "'^' expects numbers, got {s}", .{operand.typeName()});

        if (accumulator == .float or operand == .float) {
            const base = accumulator.getF() catch unreachable;
            const exponent = operand.getF() catch unreachable;
            accumulator = .{ .float = std.math.pow(f64, base, exponent) };
        } else {
            const base: f64 = @floatFromInt(accumulator.getI() catch unreachable);
            const exponent: f64 = @floatFromInt(operand.getI() catch unreachable);
            accumulator = .{ .int = @intFromFloat(std.math.pow(f64, base, exponent)) };
        }
    }
    return accumulator;
}


const testing = @import("testing.zig");

test "arithmetic: add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "+ 1 2 3");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "arithmetic: subtract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "- 10 3");
    try std.testing.expectEqual(@as(i64, 7), result.?.int);
}

test "arithmetic: multiply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "* 4 5");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "arithmetic: divide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "/ 10 3");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "arithmetic: float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "+ 1 2.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "arithmetic: power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "^ 2 10");
    try std.testing.expectEqual(@as(i64, 1024), result.?.int);
}

