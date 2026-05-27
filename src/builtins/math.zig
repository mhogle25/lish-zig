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
    try registry.registerOperation(allocator, "min",   Operation.fromFn(minOp));
    try registry.registerOperation(allocator, "max",   Operation.fromFn(maxOp));
    try registry.registerOperation(allocator, "clamp", Operation.fromFn(clampOp));
    try registry.registerOperation(allocator, "abs",   Operation.fromFn(absOp));
    try registry.registerOperation(allocator, "floor", Operation.fromFn(floorOp));
    try registry.registerOperation(allocator, "ceil",  Operation.fromFn(ceilOp));
    try registry.registerOperation(allocator, "round", Operation.fromFn(roundOp));
    try registry.registerOperation(allocator, "even",  Operation.fromFn(evenOp));
    try registry.registerOperation(allocator, "odd",   Operation.fromFn(oddOp));
    try registry.registerOperation(allocator, "sign",  Operation.fromFn(signOp));
    try registry.registerOperation(allocator, "pi",    Operation.fromFn(piOp));
    try registry.registerOperation(allocator, "sqrt",  Operation.fromFn(sqrtOp));
    try registry.registerOperation(allocator, "sin",   Operation.fromFn(sinOp));
    try registry.registerOperation(allocator, "cos",   Operation.fromFn(cosOp));
    try registry.registerOperation(allocator, "atan2", Operation.fromFn(atan2Op));
    try registry.registerOperation(allocator, "log",   Operation.fromFn(logOp));
    try registry.registerOperation(allocator, "exp",   Operation.fromFn(expOp));
}

fn minOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @min(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @min(left, right) };
        }
    }
    return result;
}

fn maxOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @max(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @max(left, right) };
        }
    }
    return result;
}

fn clampOp(args: Args) ExecError!?Value {
    try args.expectCount(3);
    const value = try args.at(0).resolve();
    const min_val = try args.at(1).resolve();
    const max_val = try args.at(2).resolve();
    if (!value.isNumber() or !min_val.isNumber() or !max_val.isNumber())
        return args.env.fail("Expected a number");

    if (value == .float or min_val == .float or max_val == .float) {
        const val_f = value.getF() catch unreachable;
        const min_f = min_val.getF() catch unreachable;
        const max_f = max_val.getF() catch unreachable;
        return .{ .float = @max(min_f, @min(val_f, max_f)) };
    } else {
        const val_i = value.getI() catch unreachable;
        const min_i = min_val.getI() catch unreachable;
        const max_i = max_val.getI() catch unreachable;
        return .{ .int = @max(min_i, @min(val_i, max_i)) };
    }
}

fn absOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => |int_val| .{ .int = if (int_val < 0) -%int_val else int_val },
        .float => |float_val| .{ .float = @abs(float_val) },
        else => args.env.fail("Expected a number"),
    };
}

fn floorOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@floor(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

fn ceilOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@ceil(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

fn roundOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@round(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

fn evenOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const n = value.getI() catch return args.env.fail("'even' expects an integer");
    return val.toCondition(@mod(n, 2) == 0);
}

fn oddOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const n = value.getI() catch return args.env.fail("'odd' expects an integer");
    return val.toCondition(@mod(n, 2) != 0);
}

fn signOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    if (value == .int) {
        const n = value.int;
        return .{ .int = if (n < 0) -1 else if (n > 0) 1 else 0 };
    }
    if (value == .float) {
        const f = value.float;
        return .{ .int = if (f < 0) -1 else if (f > 0) 1 else 0 };
    }
    return args.env.fail("'sign' expects a number");
}

fn piOp(_: Args) ExecError!?Value {
    return .{ .float = std.math.pi };
}

fn sqrtOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @sqrt(x) };
}

fn sinOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @sin(x) };
}

fn cosOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @cos(x) };
}

fn atan2Op(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const y = try args.at(0).resolveFloat();
    const x = try args.at(1).resolveFloat();
    return .{ .float = std.math.atan2(y, x) };
}

fn logOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @log(x) };
}

fn expOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const x = try args.at(0).resolveFloat();
    return .{ .float = @exp(x) };
}

// ── Tests ──

const testing = @import("testing.zig");

test "math: min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "min 3 1 2");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "math: min float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "min 3 1.5 2");
    try std.testing.expectEqual(@as(f64, 1.5), result.?.float);
}

test "math: max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "max 3 1 2");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: clamp within range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "clamp 5 0 10");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: clamp above max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "clamp 15 0 10");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "math: clamp below min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "clamp (- 0 5) 0 10");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "math: abs positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs (- 0 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "abs -3.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "math: floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "floor 3.7");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: floor int identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "floor 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: ceil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "ceil 3.2");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "round 3.5");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "round 3.4");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: even true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even 4");
    try std.testing.expect(result != null);
}

test "math: even false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even 3");
    try std.testing.expect(result == null);
}

test "math: even negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "even (- 0 4)");
    try std.testing.expect(result != null);
}

test "math: odd true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "odd 3");
    try std.testing.expect(result != null);
}

test "math: odd false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "odd 4");
    try std.testing.expect(result == null);
}

test "math: sign positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sign 42");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "math: sign negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sign (- 0 5)");
    try std.testing.expectEqual(@as(i64, -1), result.?.int);
}

test "math: sign zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sign 0");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "math: sign float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sign -3.5");
    try std.testing.expectEqual(@as(i64, -1), result.?.int);
}

test "math: pi constant" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "pi");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi), result.?.float, 1e-12);
}

test "math: sqrt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sqrt 9");
    try std.testing.expectApproxEqAbs(@as(f64, 3.0), result.?.float, 1e-12);
}

test "math: sin of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sin 0");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: cos of zero" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "cos 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-12);
}

test "math: sin of pi" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "sin (pi)");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: atan2 quadrants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "atan2 1 0");
    try std.testing.expectApproxEqAbs(@as(f64, std.math.pi / 2.0), result.?.float, 1e-12);
}

test "math: log natural" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "log 1");
    try std.testing.expectApproxEqAbs(@as(f64, 0.0), result.?.float, 1e-12);
}

test "math: exp" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "exp 0");
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), result.?.float, 1e-12);
}

test "math: exp/log inverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "log (exp 2.5)");
    try std.testing.expectApproxEqAbs(@as(f64, 2.5), result.?.float, 1e-12);
}

