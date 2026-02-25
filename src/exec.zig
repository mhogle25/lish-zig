const std = @import("std");
const val = @import("value.zig");

const Value = val.Value;
const Allocator = std.mem.Allocator;

// ── Error types ──

pub const ExecError = Allocator.Error || error{RuntimeError};

// ── Thunk — Core deferred computation ──

pub const Thunk = union(enum) {
    value_literal: ?Value,
    scope_thunk: *const Thunk,
    expression: Expression,

    /// Evaluate this thunk in the given environment and scope.
    pub fn proc(self: *const Thunk, env: *Env, scope: *const Scope) ExecError!?Value {
        return switch (self.*) {
            .value_literal => |stored_value| stored_value,
            .scope_thunk => |id_thunk| {
                const id_value = try id_thunk.proc(env, scope) orelse
                    return env.fail("Scope thunk ID resolved to none");

                var id_buf: [256]u8 = undefined;
                const id_string = id_value.getS(&id_buf);

                const entry = scope.get(id_string) orelse
                    return env.fail("Scope entry not found");

                return entry.run(env);
            },
            .expression => |expression| env.processExpression(expression, scope),
        };
    }
};

// ── Expression ──

pub const Expression = struct {
    id: *const Thunk,
    args: []const *const Thunk,
};

// ── Scope ──

pub const ScopeEntry = struct {
    thunk: *const Thunk,
    scope: *const Scope,

    /// Evaluate the thunk using the captured scope (closure semantics).
    pub fn run(self: ScopeEntry, env: *Env) ExecError!?Value {
        return self.thunk.proc(env, self.scope);
    }
};

pub const Scope = struct {
    entries: std.StringHashMapUnmanaged(ScopeEntry) = .{},

    pub fn get(self: *const Scope, key: []const u8) ?ScopeEntry {
        return self.entries.get(key);
    }

    /// Bind an arbitrary thunk to a name with an explicit evaluation scope.
    /// setValue and setExpression are convenience wrappers around this.
    pub fn setEntry(self: *Scope, allocator: Allocator, key: []const u8, thunk: *const Thunk, thunk_scope: *const Scope) Allocator.Error!void {
        try self.entries.put(allocator, key, .{ .thunk = thunk, .scope = thunk_scope });
    }

    /// Bind a static value to a name. The value is returned as-is on every access.
    pub fn setValue(self: *Scope, allocator: Allocator, key: []const u8, value: ?Value) Allocator.Error!void {
        const thunk = try allocator.create(Thunk);
        thunk.* = .{ .value_literal = value };
        try self.setEntry(allocator, key, thunk, &Scope.EMPTY);
    }

    /// Bind a lazily-evaluated expression to a name. The expression is
    /// re-evaluated in this scope each time the name is referenced.
    pub fn setExpression(self: *Scope, allocator: Allocator, key: []const u8, expr: Expression) Allocator.Error!void {
        const thunk = try allocator.create(Thunk);
        thunk.* = .{ .expression = expr };
        try self.setEntry(allocator, key, thunk, self);
    }

    pub const EMPTY: Scope = .{};
};

// ── Arg — Deferred argument wrapper ──

pub const Arg = struct {
    thunk: *const Thunk,
    env: *Env,
    scope: *const Scope,

    /// Evaluate the argument thunk lazily.
    pub fn get(self: Arg) ExecError!?Value {
        return self.thunk.proc(self.env, self.scope);
    }

    /// Evaluate and require a non-null value.
    pub fn resolve(self: Arg) ExecError!Value {
        return try self.get() orelse
            return self.env.fail("Expected a value but got none");
    }

    /// Evaluate and get as string.
    pub fn resolveString(self: Arg, buf: []u8) ExecError![]const u8 {
        const result = try self.resolve();
        return result.getS(buf);
    }

    /// Evaluate and get as integer.
    pub fn resolveInt(self: Arg) ExecError!i64 {
        const result = try self.resolve();
        return result.getI() catch
            return self.env.fail("Expected a number");
    }

    /// Evaluate and get as float.
    pub fn resolveFloat(self: Arg) ExecError!f64 {
        const result = try self.resolve();
        return result.getF() catch
            return self.env.fail("Expected a number");
    }

    /// Evaluate and get as list.
    pub fn resolveList(self: Arg) ExecError![]const ?Value {
        const result = try self.resolve();
        return result.getL() catch
            return self.env.fail("Expected a list");
    }
};

// ── Args — Collection of deferred arguments ──

pub const Args = struct {
    items: []const Arg,
    env: *Env,
    scope: *const Scope,

    pub fn count(self: Args) usize {
        return self.items.len;
    }

    pub fn at(self: Args, index: usize) Arg {
        return self.items[index];
    }

    /// Get a single argument, asserting exactly one was provided.
    pub fn single(self: Args) ExecError!Arg {
        if (self.items.len != 1) {
            return self.env.fail(
                if (self.items.len == 0) "Expected 1 argument but got 0" else "Expected 1 argument but got multiple",
            );
        }
        return self.items[0];
    }

    /// Resolve single argument to a value.
    pub fn resolveSingle(self: Args) ExecError!Value {
        const arg = try self.single();
        return arg.resolve();
    }

    /// Evaluate all arguments, returning their optional values.
    pub fn getAll(self: Args) ExecError![]const ?Value {
        const results = try self.env.allocator.alloc(?Value, self.items.len);
        for (self.items, 0..) |arg, i| {
            results[i] = try arg.get();
        }
        return results;
    }

    /// Resolve all arguments (require non-null values).
    pub fn resolveAll(self: Args) ExecError![]const Value {
        const results = try self.env.allocator.alloc(Value, self.items.len);
        for (self.items, 0..) |arg, i| {
            results[i] = try arg.resolve();
        }
        return results;
    }

    /// Validate that exactly the expected number of arguments was provided.
    pub fn expectCount(self: Args, expected: usize) ExecError!void {
        if (self.items.len != expected) {
            return self.env.failFmt("Expected {d} argument(s) but got {d}", .{ expected, self.items.len });
        }
    }

    /// Validate at least the minimum number of arguments was provided.
    pub fn expectMinCount(self: Args, minimum: usize) ExecError!void {
        if (self.items.len < minimum) {
            return self.env.failFmt("Expected at least {d} argument(s) but got {d}", .{ minimum, self.items.len });
        }
    }
};

// ── Operation — Callable with optional bound context ──

pub const Operation = struct {
    context: ?*anyopaque,
    callFn: *const fn (?*anyopaque, Args) ExecError!?Value,

    pub fn call(self: Operation, args: Args) ExecError!?Value {
        return self.callFn(self.context, args);
    }

    /// Wrap a stateless function as an Operation.
    pub fn fromFn(comptime func: fn (Args) ExecError!?Value) Operation {
        return .{
            .context = null,
            .callFn = struct {
                fn call(_: ?*anyopaque, args: Args) ExecError!?Value {
                    return func(args);
                }
            }.call,
        };
    }

    /// Wrap a context-bound function as an Operation.
    /// The cast from anyopaque to *Context is generated once here at comptime.
    pub fn fromBoundFn(
        comptime Context: type,
        comptime func: fn (*Context, Args) ExecError!?Value,
        context: *Context,
    ) Operation {
        return .{
            .context = context,
            .callFn = struct {
                fn call(ctx: ?*anyopaque, args: Args) ExecError!?Value {
                    const typed: *Context = @ptrCast(@alignCast(ctx.?));
                    return func(typed, args);
                }
            }.call,
        };
    }
};

// ── Macro — User-defined function ──

pub const MacroParameterType = enum {
    value,
    deferred,
};

pub const MacroParameter = struct {
    id: []const u8,
    param_type: MacroParameterType,
};

pub const Macro = struct {
    id: []const u8,
    parameters: []const MacroParameter,
    body: Expression,

    /// Execute the macro: bind arguments to parameters, evaluate body.
    pub fn run(
        self: *const Macro,
        arg_thunks: []const *const Thunk,
        env: *Env,
        caller_scope: *const Scope,
    ) ExecError!?Value {
        if (self.parameters.len != arg_thunks.len) {
            return env.failFmt(
                "Macro '{s}' expected {d} argument(s) but got {d}",
                .{ self.id, self.parameters.len, arg_thunks.len },
            );
        }

        // Build a new scope with parameter bindings (arena-allocated for safety)
        const macro_scope = try env.allocator.create(Scope);
        macro_scope.* = .{};

        for (self.parameters, arg_thunks) |param, arg_thunk| {
            switch (param.param_type) {
                .value => {
                    // Eagerly evaluate the argument in the caller's scope, then bind as a static value.
                    const evaluated = try arg_thunk.proc(env, caller_scope);
                    try macro_scope.setValue(env.allocator, param.id, evaluated);
                },
                .deferred => {
                    // Bind the unevaluated thunk with the caller's scope so it re-evaluates there.
                    try macro_scope.setEntry(env.allocator, param.id, arg_thunk, caller_scope);
                },
            }
        }

        return env.processExpression(self.body, macro_scope);
    }
};

// ── Registry — Operation and macro namespace ──

pub const Registry = struct {
    operations: std.StringHashMapUnmanaged(Operation) = .{},
    macros: std.StringHashMapUnmanaged(*const Macro) = .{},

    pub fn getOperation(self: *const Registry, id: []const u8) ?Operation {
        return self.operations.get(id);
    }

    pub fn getMacro(self: *const Registry, id: []const u8) ?*const Macro {
        return self.macros.get(id);
    }

    pub fn registerOperation(self: *Registry, allocator: Allocator, id: []const u8, operation: Operation) Allocator.Error!void {
        try self.operations.put(allocator, id, operation);
    }

    pub fn registerMacro(self: *Registry, allocator: Allocator, id: []const u8, macro: *const Macro) Allocator.Error!void {
        try self.macros.put(allocator, id, macro);
    }

    pub fn deinit(self: *Registry, allocator: Allocator) void {
        self.operations.deinit(allocator);
        self.macros.deinit(allocator);
    }
};

// ── Env — Execution environment ──

pub const Env = struct {
    registry: *const Registry,
    allocator: Allocator,
    runtime_error: ?[]const u8 = null,
    stdout: ?std.io.AnyWriter = null,
    stderr: ?std.io.AnyWriter = null,

    /// Evaluate an expression: resolve ID, look up in registry, execute.
    pub fn processExpression(self: *Env, expression: Expression, scope: *const Scope) ExecError!?Value {
        // 1. Evaluate the ID thunk
        const id_value = try expression.id.proc(self, scope) orelse
            return self.fail("Expression ID resolved to none");

        // 2. Convert to string for registry lookup
        var id_buf: [256]u8 = undefined;
        const id_string = id_value.getS(&id_buf);

        // 3. Try operation first, then macro
        if (self.registry.getOperation(id_string)) |operation| {
            const args = try self.packageArgs(expression.args, scope);
            return operation.call(args);
        }

        if (self.registry.getMacro(id_string)) |macro| {
            return macro.run(expression.args, self, scope);
        }

        return self.failFmt("Unknown operation or macro: '{s}'", .{id_string});
    }

    fn packageArgs(self: *Env, thunks: []const *const Thunk, scope: *const Scope) ExecError!Args {
        const items = try self.allocator.alloc(Arg, thunks.len);
        for (thunks, 0..) |thunk, i| {
            items[i] = .{ .thunk = thunk, .env = self, .scope = scope };
        }
        return .{ .items = items, .env = self, .scope = scope };
    }

    /// Set an error message and return RuntimeError.
    pub fn fail(self: *Env, message: []const u8) error{RuntimeError} {
        self.runtime_error = message;
        return error.RuntimeError;
    }

    /// Set a formatted error message and return RuntimeError.
    pub fn failFmt(self: *Env, comptime fmt: []const u8, args: anytype) error{RuntimeError} {
        self.runtime_error = std.fmt.allocPrint(self.allocator, fmt, args) catch "error (allocation failed)";
        return error.RuntimeError;
    }
};

// ── Thunk construction helpers ──

pub fn makeValueLiteral(allocator: Allocator, value: ?Value) Allocator.Error!*Thunk {
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .value_literal = value };
    return thunk;
}

pub fn makeScopeThunk(allocator: Allocator, id_thunk: *const Thunk) Allocator.Error!*Thunk {
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .scope_thunk = id_thunk };
    return thunk;
}

pub fn makeExpression(allocator: Allocator, id: *const Thunk, args: []const *const Thunk) Allocator.Error!*Thunk {
    const duped_args = try allocator.dupe(*const Thunk, args);
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .expression = .{ .id = id, .args = duped_args } };
    return thunk;
}

// ── Tests ──

test "value literal thunk returns stored value" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk = try makeValueLiteral(alloc, .{ .int = 42 });
    const result = try thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "value literal none thunk returns null" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk = try makeValueLiteral(alloc, null);
    const result = try thunk.proc(&env, &scope);
    try std.testing.expect(result == null);
}

test "scope thunk resolves entry from scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };

    // Create a scope with "x" bound to 99
    const value_thunk = try makeValueLiteral(alloc, .{ .int = 99 });
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    var scope = Scope{};
    try scope.entries.put(alloc, "x", .{ .thunk = value_thunk, .scope = empty_scope });

    // Create :x (scope thunk that looks up "x")
    const id_thunk = try makeValueLiteral(alloc, .{ .string = "x" });
    const lookup_thunk = try makeScopeThunk(alloc, id_thunk);

    const result = try lookup_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 99), result.?.int);
}

test "scope thunk fails for missing entry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id_thunk = try makeValueLiteral(alloc, .{ .string = "missing" });
    const lookup_thunk = try makeScopeThunk(alloc, id_thunk);

    const result = lookup_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
    try std.testing.expectEqualStrings("Scope entry not found", env.runtime_error.?);
}

test "expression evaluates operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try registry.registerOperation(alloc, "double", Operation.fromFn(testDoubleOp));

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, .{ .string = "double" });
    const arg = try makeValueLiteral(alloc, .{ .int = 21 });
    const expr_thunk = try makeExpression(alloc, id, &.{arg});

    const result = try expr_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

fn testDoubleOp(args: Args) ExecError!?Value {
    const arg_value = try args.at(0).resolveInt();
    return .{ .int = arg_value * 2 };
}

test "expression fails for unknown operation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const id = try makeValueLiteral(alloc, .{ .string = "nonexistent" });
    const expr_thunk = try makeExpression(alloc, id, &.{});

    const result = expr_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
}

test "nested expression evaluation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp));

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Build: add (add 1 2) 3 → expects 6
    const add_id_inner = try makeValueLiteral(alloc, .{ .string = "add" });
    const one = try makeValueLiteral(alloc, .{ .int = 1 });
    const two = try makeValueLiteral(alloc, .{ .int = 2 });
    const inner_expr = try makeExpression(alloc, add_id_inner, &.{ one, two });

    const add_id_outer = try makeValueLiteral(alloc, .{ .string = "add" });
    const three = try makeValueLiteral(alloc, .{ .int = 3 });
    const outer_expr = try makeExpression(alloc, add_id_outer, &.{ inner_expr, three });

    const result = try outer_expr.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

fn testAddOp(args: Args) ExecError!?Value {
    const left = try args.at(0).resolveInt();
    const right = try args.at(1).resolveInt();
    return .{ .int = left + right };
}

test "macro with value parameters" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp));

    // Define macro: |add-one x| add :x 1
    const params = [_]MacroParameter{
        .{ .id = "x", .param_type = .value },
    };

    const add_id = try makeValueLiteral(alloc, .{ .string = "add" });
    const x_id = try makeValueLiteral(alloc, .{ .string = "x" });
    const x_ref = try makeScopeThunk(alloc, x_id);
    const one = try makeValueLiteral(alloc, .{ .int = 1 });

    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "add-one",
        .parameters = &params,
        .body = .{
            .id = add_id,
            .args = try alloc.dupe(*const Thunk, &.{ x_ref, one }),
        },
    };
    try registry.registerMacro(alloc, "add-one", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call: add-one 5 → expects 6
    const call_id = try makeValueLiteral(alloc, .{ .string = "add-one" });
    const five = try makeValueLiteral(alloc, .{ .int = 5 });
    const call_thunk = try makeExpression(alloc, call_id, &.{five});

    const result = try call_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "macro with deferred parameter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try registry.registerOperation(alloc, "identity", Operation.fromFn(testIdentityOp));

    // Define macro: |run-deferred ~thunk| identity :thunk
    // The deferred parameter means the thunk is not evaluated until :thunk is referenced
    const params = [_]MacroParameter{
        .{ .id = "thunk", .param_type = .deferred },
    };

    const identity_id = try makeValueLiteral(alloc, .{ .string = "identity" });
    const thunk_id = try makeValueLiteral(alloc, .{ .string = "thunk" });
    const thunk_ref = try makeScopeThunk(alloc, thunk_id);

    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "run-deferred",
        .parameters = &params,
        .body = .{
            .id = identity_id,
            .args = try alloc.dupe(*const Thunk, &.{thunk_ref}),
        },
    };
    try registry.registerMacro(alloc, "run-deferred", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call: run-deferred 42 → the literal 42 is passed deferred, resolved when :thunk is accessed
    const call_id = try makeValueLiteral(alloc, .{ .string = "run-deferred" });
    const forty_two = try makeValueLiteral(alloc, .{ .int = 42 });
    const call_thunk = try makeExpression(alloc, call_id, &.{forty_two});

    const result = try call_thunk.proc(&env, &scope);
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

fn testIdentityOp(args: Args) ExecError!?Value {
    return args.at(0).get();
}

test "macro arity mismatch" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    const params = [_]MacroParameter{
        .{ .id = "x", .param_type = .value },
        .{ .id = "y", .param_type = .value },
    };
    const dummy_id = try makeValueLiteral(alloc, .{ .string = "identity" });
    const macro = try alloc.create(Macro);
    macro.* = .{
        .id = "needs-two",
        .parameters = &params,
        .body = .{ .id = dummy_id, .args = &.{} },
    };
    try registry.registerMacro(alloc, "needs-two", macro);

    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    // Call with wrong arity: needs-two 1 (missing second arg)
    const call_id = try makeValueLiteral(alloc, .{ .string = "needs-two" });
    const one = try makeValueLiteral(alloc, .{ .int = 1 });
    const call_thunk = try makeExpression(alloc, call_id, &.{one});

    const result = call_thunk.proc(&env, &scope);
    try std.testing.expectError(error.RuntimeError, result);
}

test "args validation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    var env = Env{ .registry = &registry, .allocator = alloc };
    const scope = Scope.EMPTY;

    const thunk_a = try makeValueLiteral(alloc, .{ .int = 10 });
    const thunk_b = try makeValueLiteral(alloc, .{ .int = 20 });
    const items = try alloc.alloc(Arg, 2);
    items[0] = .{ .thunk = thunk_a, .env = &env, .scope = &scope };
    items[1] = .{ .thunk = thunk_b, .env = &env, .scope = &scope };

    const args = Args{ .items = items, .env = &env, .scope = &scope };

    try std.testing.expectEqual(@as(usize, 2), args.count());
    try std.testing.expectEqual(@as(i64, 10), try args.at(0).resolveInt());
    try std.testing.expectEqual(@as(i64, 20), try args.at(1).resolveInt());

    // single() should fail with 2 args
    try std.testing.expectError(error.RuntimeError, args.single());
}

test "scope entry closure captures scope" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    var registry = Registry{};
    try registry.registerOperation(alloc, "add", Operation.fromFn(testAddOp));

    var env = Env{ .registry = &registry, .allocator = alloc };

    // Create an inner scope where "y" = 10
    const y_value = try makeValueLiteral(alloc, .{ .int = 10 });
    const inner_scope = try alloc.create(Scope);
    inner_scope.* = .{};
    const empty_scope = try alloc.create(Scope);
    empty_scope.* = Scope.EMPTY;
    try inner_scope.entries.put(alloc, "y", .{ .thunk = y_value, .scope = empty_scope });

    // Create a thunk that references :y — captured with inner_scope
    const y_id = try makeValueLiteral(alloc, .{ .string = "y" });
    const y_ref = try makeScopeThunk(alloc, y_id);

    // Create an outer scope where "my-val" is bound to :y with inner_scope as the captured scope
    var outer_scope = Scope{};
    try outer_scope.entries.put(alloc, "my-val", .{ .thunk = y_ref, .scope = inner_scope });

    // Resolving "my-val" should evaluate :y in inner_scope, finding y=10
    const entry = outer_scope.get("my-val").?;
    const result = try entry.run(&env);
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}
