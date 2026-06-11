const std = @import("std");
const exec = @import("../exec.zig");
const val = @import("../value.zig");
const parser = @import("../parser.zig");
const validation = @import("../validation.zig");
const builtins = @import("../builtins.zig");

const Value = val.Value;
const ExecError = exec.ExecError;
const Registry = exec.Registry;
const Allocator = std.mem.Allocator;

pub fn makeTestEnv(alloc: Allocator, registry: *Registry) exec.Env {
    return .{ .registry = registry, .allocator = alloc };
}

pub fn evalWithBuiltins(alloc: Allocator, source: []const u8) ExecError!?Value {
    var registry = Registry.init(alloc);
    builtins.registerAll(&registry, alloc) catch return error.OutOfMemory;

    var env = makeTestEnv(alloc, &registry);
    const scope = exec.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, source);
    const result = try validation.validate(alloc, ast_root);

    return switch (result) {
        .ok => |expression| try env.processExpression(expression, &scope),
        .err => error.RuntimeError,
    };
}

/// Like `evalWithBuiltins` but also loads the bundled stdlib macros. Used by
/// tests that exercise stdlib macros built on top of the builtin ops.
pub fn evalWithStdlib(alloc: Allocator, source: []const u8) ExecError!?Value {
    const process_mod = @import("../process.zig");
    var registry = Registry.init(alloc);
    builtins.registerAll(&registry, alloc) catch return error.OutOfMemory;
    _ = process_mod.loadStdlib(&registry) catch return error.OutOfMemory;

    var env = makeTestEnv(alloc, &registry);
    const scope = exec.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, source);
    const result = try validation.validate(alloc, ast_root);

    return switch (result) {
        .ok => |expression| try env.processExpression(expression, &scope),
        .err => error.RuntimeError,
    };
}
