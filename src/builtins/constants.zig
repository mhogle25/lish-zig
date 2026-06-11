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
    try registry.registerOperation(allocator, "some", Operation.fromFn(someOp));
    try registry.registerOperation(allocator, "none", Operation.fromFn(noneOp));
}

fn someOp(_: Args) ExecError!?Value {
    return val.some();
}

fn noneOp(_: Args) ExecError!?Value {
    return null;
}



const testing = @import("testing.zig");

test "constants: some and none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const some_result = try testing.evalWithBuiltins(arena.allocator(), "some");
    try std.testing.expect(some_result != null);
    const none_result = try testing.evalWithBuiltins(arena.allocator(), "none");
    try std.testing.expect(none_result == null);
}

test "comment: inline comment in expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try testing.evalWithBuiltins(arena.allocator(), "+ 1 ## comment ## 2");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

