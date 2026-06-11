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
    try registry.registerOperation(allocator, "if",     Operation.fromFn(ifElseOp));
    try registry.registerOperation(allocator, "when",   Operation.fromFn(whenOp));
    try registry.registerOperation(allocator, "match",  Operation.fromFn(matchOp));
    try registry.registerOperation(allocator, "assert", Operation.fromFn(assertOp));
}

fn ifElseOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 2 and count != 3) return args.env.fail(.arity_mismatch, "'if' expects  or 3 arguments");

    const condition = try args.at(0).get();

    if (count == 2) {
        return if (condition != null) try args.at(1).get() else null;
    }

    return if (condition != null) try args.at(1).get() else try args.at(2).get();
}

fn whenOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count % 2 != 0) {
        return args.env.fail(.arity_mismatch, "'when' expects an even number of arguments (condition/result pairs)");
    }

    var i: usize = 0;
    while (i < count) : (i += 2) {
        const condition = try args.at(i).get();
        if (condition != null) {
            return args.at(i + 1).get();
        }
    }

    return null;
}

fn matchOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 3 or count % 2 == 0) {
        return args.env.fail(.arity_mismatch, "'match' expects an odd number of arguments (target + pattern/result pairs)");
    }

    const target = try args.at(0).get();

    var i: usize = 1;
    while (i < count) : (i += 2) {
        const pattern = try args.at(i).get();

        const matches = if (target == null and pattern == null)
            true
        else if (target != null and pattern != null)
            target.?.eql(pattern.?)
        else
            false;

        if (matches) {
            return args.at(i + 1).get();
        }
    }

    return null;
}

fn assertOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 1 or count > 2) return args.env.fail(.arity_mismatch, "'assert' expects  or 2 arguments");
    const condition = try args.at(0).get();
    if (condition != null) return condition;
    if (count == 2) {
        var msg_buf: [512]u8 = undefined;
        const message = try args.at(1).resolveString(&msg_buf);
        return args.env.failFmt(.user, "Assertion failed: {s}", .{message});
    }
    return args.env.fail(.user, "Assertion failed");
}


const testing = @import("testing.zig");

test "control flow: if-then" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try testing.evalWithBuiltins(arena.allocator(), "if $some 42");
    try std.testing.expectEqual(@as(i64, 42), truthy.?.int);
    const falsy = try testing.evalWithBuiltins(arena.allocator(), "if $none 42");
    try std.testing.expect(falsy == null);
}

test "control flow: if-then-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try testing.evalWithBuiltins(arena.allocator(), "if $some 1 2");
    try std.testing.expectEqual(@as(i64, 1), truthy.?.int);
    const falsy = try testing.evalWithBuiltins(arena.allocator(), "if $none 1 2");
    try std.testing.expectEqual(@as(i64, 2), falsy.?.int);
}

test "control flow: when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // First condition is false (none), second is true (some) → returns 2
    const result = try testing.evalWithBuiltins(arena.allocator(), "when $none 1 $some 2");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "control flow: match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "match 2 1 10 2 20 3 30");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "control flow: assert truthy passes through" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "assert 42");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "control flow: assert falsy errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "assert $none");
    try std.testing.expectError(error.RuntimeError, result);
}

test "control flow: assert falsy with message errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = testing.evalWithBuiltins(arena.allocator(), "assert $none \"expected a value\"");
    try std.testing.expectError(error.RuntimeError, result);
}

