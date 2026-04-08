const std = @import("std");
const exec = @import("exec.zig");
const val = @import("value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Operation = exec.Operation;
const Allocator = std.mem.Allocator;

// ── Registration ──

pub fn registerAll(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    try registry.registerOperation(allocator, "?",  Operation.fromFn(randInclusiveOp));
    try registry.registerOperation(allocator, "?<", Operation.fromFn(randExclusiveOp));
    try registry.registerOperation(allocator, "??", Operation.fromFn(randPickOp));
}

// ── Operations ──

/// `? x y` — random value in [x, y] (both inclusive).
/// For integers, both endpoints are reachable.
/// For floats, [x, y) is used internally; hitting exactly y is not representable.
fn randInclusiveOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const x = try args.at(0).resolve();
    const y = try args.at(1).resolve();
    if (!x.isNumber()) return args.env.fail("'?' expects numbers");
    if (!y.isNumber()) return args.env.fail("'?' expects numbers");

    if (x == .float or y == .float) {
        const xf = x.getF() catch unreachable;
        const yf = y.getF() catch unreachable;
        if (xf > yf) return args.env.fail("'?' expects x <= y");
        return .{ .float = xf + std.crypto.random.float(f64) * (yf - xf) };
    } else {
        const xi = x.getI() catch unreachable;
        const yi = y.getI() catch unreachable;
        if (xi > yi) return args.env.fail("'?' expects x <= y");
        return .{ .int = std.crypto.random.intRangeAtMost(i64, xi, yi) };
    }
}

/// `?< x y` — random value in [x, y) (upper-exclusive).
/// For integers, y is never returned.
/// For floats, standard [x, y) semantics.
fn randExclusiveOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const x = try args.at(0).resolve();
    const y = try args.at(1).resolve();
    if (!x.isNumber()) return args.env.fail("'?<' expects numbers");
    if (!y.isNumber()) return args.env.fail("'?<' expects numbers");

    if (x == .float or y == .float) {
        const xf = x.getF() catch unreachable;
        const yf = y.getF() catch unreachable;
        if (xf >= yf) return args.env.fail("'?<' expects x < y");
        return .{ .float = xf + std.crypto.random.float(f64) * (yf - xf) };
    } else {
        const xi = x.getI() catch unreachable;
        const yi = y.getI() catch unreachable;
        if (xi >= yi) return args.env.fail("'?<' expects x < y");
        return .{ .int = std.crypto.random.intRangeLessThan(i64, xi, yi) };
    }
}

/// `?? a b c ...` — pick one argument at random. Only the chosen argument is evaluated.
fn randPickOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const index = std.crypto.random.intRangeLessThan(usize, 0, args.count());
    return args.at(index).get();
}

// ── Tests ──

const builtins = @import("builtins.zig");
const process = @import("process.zig");

test "?: integer inclusive range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "? 1 6", null);
        const value = result.ok.?;
        try std.testing.expect(value == .int);
        try std.testing.expect(value.int >= 1 and value.int <= 6);
    }
}

test "?<: integer exclusive upper" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "?< 0 5", null);
        const value = result.ok.?;
        try std.testing.expect(value == .int);
        try std.testing.expect(value.int >= 0 and value.int <= 4);
    }
}

test "?: same value returns that value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc };

    const result = try process.processRaw(&env, "? 7 7", null);
    try std.testing.expectEqual(@as(i64, 7), result.ok.?.int);
}

test "??: picks from provided values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry.init(alloc);
    try builtins.registerAll(&registry, alloc);
    try registerAll(&registry, alloc);
    var env = exec.Env{ .registry = &registry, .allocator = alloc };

    for (0..100) |_| {
        const result = try process.processRaw(&env, "?? 10 20 30", null);
        const value = result.ok.?.int;
        try std.testing.expect(value == 10 or value == 20 or value == 30);
    }
}
