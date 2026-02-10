const std = @import("std");
const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");
const macro_parser_mod = @import("macro_parser.zig");
const exec_mod = @import("exec.zig");
const val = @import("value.zig");

const Allocator = std.mem.Allocator;
const Value = val.Value;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const Registry = exec_mod.Registry;
const Expression = exec_mod.Expression;
const ValidationError = validation_mod.ValidationError;

// ── Result types ──

/// Result of processing a raw expression string.
pub const ProcessResult = union(enum) {
    ok: ?Value,
    validation_err: []const ValidationError,
    runtime_err: []const u8,
};

/// Result of loading a macro module from source.
pub const MacroLoadResult = union(enum) {
    ok: usize,
    validation_err: []const ValidationError,
};

/// A function that registers operations into a Registry.
/// Allows modular operation registration.
pub const RegistryFragment = *const fn (*Registry, Allocator) Allocator.Error!void;

// ── Convenience API ──

/// Parse, validate, and execute a raw expression string in one call.
pub fn processRaw(
    env: *Env,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    // 1. Parse
    const ast_root = try expr_parser.parse(env.allocator, source);

    // 2. Validate
    const validation_result = try validation_mod.validate(env.allocator, ast_root);

    switch (validation_result) {
        .ok => |expression| {
            // 3. Execute
            const exec_scope = scope orelse &Scope.EMPTY;
            const result = env.processExpression(expression, exec_scope) catch |err| switch (err) {
                error.RuntimeError => return .{ .runtime_err = env.runtime_error orelse "Unknown runtime error" },
                error.OutOfMemory => return error.OutOfMemory,
            };
            return .{ .ok = result };
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

/// Parse a macro module source string, validate it, and register all macros
/// into the provided registry.
pub fn loadMacroModule(
    allocator: Allocator,
    registry: *Registry,
    source: []const u8,
) Allocator.Error!MacroLoadResult {
    // 1. Parse macro module
    const module = try macro_parser_mod.parseMacroModule(allocator, source);

    // 2. Validate
    const validation_result = try macro_parser_mod.validateMacroModule(allocator, module);

    switch (validation_result) {
        .ok => |macros| {
            // 3. Register all macros
            for (macros) |*macro| {
                try registry.registerMacro(allocator, macro.id, macro);
            }
            return .{ .ok = macros.len };
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

/// Load multiple registry fragments into a registry.
pub fn loadFragments(
    registry: *Registry,
    allocator: Allocator,
    fragments: []const RegistryFragment,
) Allocator.Error!void {
    for (fragments) |fragment| {
        try fragment(registry, allocator);
    }
}

// ── Tests ──

const builtins = @import("builtins.zig");

test "processRaw: simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: nested expressions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "+ (+ 1 2) (* 3 4)", null);
    switch (result) {
        .ok => |maybe_value| {
            // (1+2) + (3*4) = 3 + 12 = 15
            try std.testing.expectEqual(@as(i32, 15), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: returns none for none operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "none", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expect(maybe_value == null);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: validation error for empty input" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "", null);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: runtime error for unknown operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };

    const result = try processRaw(&env, "nonexistent 1 2", null);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => |message| {
            try std.testing.expect(std.mem.indexOf(u8, message, "nonexistent") != null);
        },
    }
}

test "processRaw: with scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    // Set up a scope with "x" = 10
    const value_thunk = try exec_mod.makeValueLiteral(alloc, .{ .int = 10 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.entries.put(alloc, "x", .{ .thunk = value_thunk, .scope = empty_scope });

    const result = try processRaw(&env, "+ :x 5", &scope);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 15), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: load and execute macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);

    // Load a macro module
    const load_result = try loadMacroModule(alloc, &registry, "| double x | * :x 2");
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 1), count),
        .validation_err => return error.TestUnexpectedResult,
    }

    // Execute using the loaded macro
    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "double 21", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 42), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: multiple macros" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);

    const load_result = try loadMacroModule(
        alloc,
        &registry,
        "| double x | * :x 2 | quadruple x | double (double :x)",
    );
    switch (load_result) {
        .ok => |count| try std.testing.expectEqual(@as(usize, 2), count),
        .validation_err => return error.TestUnexpectedResult,
    }

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "quadruple 3", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 12), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "loadMacroModule: validation errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};

    // Duplicate macro IDs should produce validation errors
    const load_result = try loadMacroModule(alloc, &registry, "| foo x | + :x 1 | foo y | + :y 2");
    switch (load_result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
    }
}

test "loadFragments: load multiple registry fragments" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try loadFragments(&registry, alloc, &.{&builtins.registerAll});

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "+ 1 2", null);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRaw: full pipeline with macros and scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Set up registry with builtins + macros
    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    const load_result = try loadMacroModule(
        alloc,
        &registry,
        "| add-to-x x amount | + :x :amount",
    );
    try std.testing.expectEqual(MacroLoadResult{ .ok = 1 }, load_result);

    // Set up scope with x = 100
    const value_thunk = try exec_mod.makeValueLiteral(alloc, .{ .int = 100 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.entries.put(alloc, "x", .{ .thunk = value_thunk, .scope = empty_scope });

    var env = Env{ .registry = &registry, .allocator = alloc };
    const result = try processRaw(&env, "add-to-x :x 50", &scope);
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i32, 150), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}
