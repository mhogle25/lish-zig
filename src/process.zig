const std = @import("std");
const expr_parser = @import("parser.zig");
const validation_mod = @import("validation.zig");
const macro_parser_mod = @import("macro_parser.zig");
const exec_mod = @import("exec.zig");
const val = @import("value.zig");
const cache_mod = @import("cache.zig");

const Allocator = std.mem.Allocator;
const Value = val.Value;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const Registry = exec_mod.Registry;
const Expression = exec_mod.Expression;
const ValidationError = validation_mod.ValidationError;
pub const ExpressionCache = cache_mod.ExpressionCache;
pub const LruCache = cache_mod.LruCache;

pub const MACRO_EXTENSION = ".shmacro";

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

/// Result of loading a directory of macro files.
pub const MacroDirResult = struct {
    loaded_count: usize,
    file_errors: []const FileError,

    pub const FileError = struct {
        path: []const u8,
        errors: []const ValidationError,
    };
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
    const ast_root = try expr_parser.parse(env.allocator, source);
    const validation_result = try validation_mod.validate(env.allocator, ast_root);

    switch (validation_result) {
        .ok => |expression| return executeExpression(env, expression, scope),
        .err => |errors| return .{ .validation_err = errors },
    }
}

/// Parse, validate, and execute — with expression caching.
/// On cache hit, skips parsing and validation entirely.
/// The env's allocator should outlive the cache (e.g. a session-scoped arena).
pub fn processRawCached(
    env: *Env,
    expression_cache: *ExpressionCache,
    source: []const u8,
    scope: ?*const Scope,
) (Allocator.Error)!ProcessResult {
    // Cache hit: skip parse + validate
    if (expression_cache.get(source)) |expression| {
        return executeExpression(env, expression, scope);
    }

    // Cache miss: parse, validate, cache, execute
    const ast_root = try expr_parser.parse(env.allocator, source);
    const validation_result = try validation_mod.validate(env.allocator, ast_root);

    switch (validation_result) {
        .ok => |expression| {
            try expression_cache.put(source, expression);
            return executeExpression(env, expression, scope);
        },
        .err => |errors| return .{ .validation_err = errors },
    }
}

fn executeExpression(env: *Env, expression: Expression, scope: ?*const Scope) (Allocator.Error)!ProcessResult {
    const exec_scope = scope orelse &Scope.EMPTY;
    const result = env.processExpression(expression, exec_scope) catch |err| switch (err) {
        error.RuntimeError => return .{ .runtime_err = env.runtime_error orelse "Unknown runtime error" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    return .{ .ok = result };
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

/// Read a .shmacro file from disk, parse, validate, and register macros.
pub fn loadMacroFile(
    allocator: Allocator,
    registry: *Registry,
    file_path: []const u8,
) !MacroLoadResult {
    const file = std.fs.cwd().openFile(file_path, .{}) catch |err| {
        return loadMacroFileError(allocator, file_path, err);
    };
    defer file.close();

    const source = file.readToEndAlloc(allocator, 1024 * 1024) catch |err| {
        return loadMacroFileError(allocator, file_path, err);
    };

    return loadMacroModule(allocator, registry, source);
}

fn loadMacroFileError(allocator: Allocator, file_path: []const u8, err: anytype) Allocator.Error!MacroLoadResult {
    const message = std.fmt.allocPrint(allocator, "Failed to load '{s}': {}", .{ file_path, err }) catch
        return .{ .validation_err = &.{} };
    const errors = try allocator.alloc(ValidationError, 1);
    errors[0] = .{ .message = message };
    return .{ .validation_err = errors };
}

/// Scan a directory for .shmacro files and load each one.
pub fn loadMacroDir(
    allocator: Allocator,
    registry: *Registry,
    dir_path: []const u8,
) !MacroDirResult {
    var dir = std.fs.cwd().openDir(dir_path, .{ .iterate = true }) catch |err| {
        const message = std.fmt.allocPrint(allocator, "Failed to open directory '{s}': {}", .{ dir_path, err }) catch
            return .{ .loaded_count = 0, .file_errors = &.{} };
        const errors = try allocator.alloc(ValidationError, 1);
        errors[0] = .{ .message = message };
        const file_errors = try allocator.alloc(MacroDirResult.FileError, 1);
        file_errors[0] = .{ .path = dir_path, .errors = errors };
        return .{ .loaded_count = 0, .file_errors = file_errors };
    };
    defer dir.close();

    var loaded_count: usize = 0;
    var file_errors: std.ArrayListUnmanaged(MacroDirResult.FileError) = .{};

    var iter = dir.iterate();
    while (try iter.next()) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, MACRO_EXTENSION)) continue;

        const full_path = try std.fs.path.join(allocator, &.{ dir_path, entry.name });

        const result = try loadMacroFile(allocator, registry, full_path);
        switch (result) {
            .ok => |count| loaded_count += count,
            .validation_err => |errors| {
                try file_errors.append(allocator, .{ .path = full_path, .errors = errors });
            },
        }
    }

    return .{
        .loaded_count = loaded_count,
        .file_errors = try file_errors.toOwnedSlice(allocator),
    };
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

test "processRawCached: cache hit skips parsing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    // First call: cache miss (parse + validate + cache + execute)
    const result1 = try processRawCached(&env, &expression_cache, "+ 1 2", null);
    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i32, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 1), expression_cache.count());

    // Second call: cache hit (execute only)
    const result2 = try processRawCached(&env, &expression_cache, "+ 1 2", null);
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i32, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "processRawCached: different expressions get separate cache entries" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try builtins.registerAll(&registry, alloc);
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    const result1 = try processRawCached(&env, &expression_cache, "+ 1 2", null);
    const result2 = try processRawCached(&env, &expression_cache, "* 3 4", null);

    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i32, 3), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i32, 12), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 2), expression_cache.count());
}

test "processRawCached: validation errors are not cached" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };

    var expression_cache = try ExpressionCache.init(std.testing.allocator, 16);
    defer expression_cache.deinit();

    const result = try processRawCached(&env, &expression_cache, "", null);
    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .validation_err => |errors| try std.testing.expect(errors.len > 0),
        .runtime_err => return error.TestUnexpectedResult,
    }
    try std.testing.expectEqual(@as(usize, 0), expression_cache.count());
}
