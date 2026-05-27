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
    try registry.registerOperation(allocator, "say",   Operation.fromFn(sayOp));
    try registry.registerOperation(allocator, "error", Operation.fromFn(errorOp));
}

fn sayOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stdout orelse return null;
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str)  catch return args.env.fail("Failed to write to stdout");
    }
    writer.writeByte('\n')    catch return args.env.fail("Failed to write to stdout");
    writer.flush()            catch return args.env.fail("Failed to write to stdout");
    return null;
}

fn errorOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stderr orelse return null;
    writer.writeAll("\x1b[31m") catch return args.env.fail("Failed to write to stderr");
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str)    catch return args.env.fail("Failed to write to stderr");
    }
    writer.writeAll("\x1b[0m\n") catch return args.env.fail("Failed to write to stderr");
    writer.flush()              catch return args.env.fail("Failed to write to stderr");
    return null;
}
