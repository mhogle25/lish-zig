const std = @import("std");
const ast_mod = @import("ast.zig");
const exec_mod = @import("exec.zig");

const Allocator = std.mem.Allocator;
const AstNode = ast_mod.AstNode;
const AstExpression = ast_mod.AstExpression;
const AstBracketError = ast_mod.AstBracketError;
const Thunk = exec_mod.Thunk;
const Expression = exec_mod.Expression;

// ── Validation error ──

pub const ValidationError = struct {
    message: []const u8,
    line: ?usize = null,
    column: ?usize = null,
    start: ?usize = null,
    end: ?usize = null,
};

pub const ValidationErrors = struct {
    items: std.ArrayListUnmanaged(ValidationError) = .{},

    pub fn add(self: *ValidationErrors, allocator: Allocator, validation_error: ValidationError) Allocator.Error!void {
        try self.items.append(allocator, validation_error);
    }

    pub fn count(self: *const ValidationErrors) usize {
        return self.items.items.len;
    }

    pub fn slice(self: *const ValidationErrors) []const ValidationError {
        return self.items.items;
    }
};

// ── Validation result ──

pub const ValidationResult = union(enum) {
    ok: Expression,
    err: []const ValidationError,
};

// ── Top-level validate ──

/// Validate an AST root node into an executable Expression.
/// The root must be an expression node; all errors are accumulated.
pub fn validate(allocator: Allocator, ast_root: *const AstNode) Allocator.Error!ValidationResult {
    var errors = ValidationErrors{};

    const maybe_thunk = try validateStep(allocator, ast_root, &errors);

    if (maybe_thunk == null) {
        if (ast_root.* != .expression) {
            try errors.add(allocator, .{ .message = "Expected the root of the AST to be an expression" });
        }
        return .{ .err = errors.slice() };
    }

    const thunk = maybe_thunk.?;
    if (thunk.* != .expression) {
        try errors.add(allocator, .{ .message = "Expected the root to produce an expression thunk" });
        return .{ .err = errors.slice() };
    }

    if (errors.count() > 0) {
        return .{ .err = errors.slice() };
    }

    return .{ .ok = thunk.expression };
}

// ── Recursive validation step ──

/// Validate a single AST node into a Thunk, accumulating errors.
/// Returns null if the node (or any of its children) is invalid.
pub fn validateStep(allocator: Allocator, node: *const AstNode, errors: *ValidationErrors) Allocator.Error!?*const Thunk {
    return switch (node.*) {
        .value_literal => |value| {
            const thunk = try allocator.create(Thunk);
            // Deep-copy string values so the Thunk is independent of the source allocator.
            const owned_value = switch (value) {
                .string => |s| @as(@TypeOf(value), .{ .string = try allocator.dupe(u8, s) }),
                else => value,
            };
            thunk.* = .{ .value_literal = owned_value };
            return thunk;
        },
        .scope_thunk => |id_node| {
            const id_thunk = try validateStep(allocator, id_node, errors) orelse return null;
            const thunk = try allocator.create(Thunk);
            thunk.* = .{ .scope_thunk = id_thunk };
            return thunk;
        },
        .expression => |expr| try validateExpression(allocator, expr, errors),
        .err => |ast_error| {
            try errors.add(allocator, .{
                .message = ast_error.message,
                .line = ast_error.token_line,
                .column = ast_error.token_column,
                .start = ast_error.token_start,
                .end = ast_error.token_end,
            });
            return null;
        },
    };
}

fn validateExpression(
    allocator: Allocator,
    expr: AstExpression,
    errors: *ValidationErrors,
) Allocator.Error!?*const Thunk {
    const init_error_count = errors.count();

    // Check opening bracket error
    if (expr.open_err) |open_err| {
        try addBracketError(allocator, errors, open_err);
    }

    // Validate ID (continue to args even if ID fails, to accumulate all errors)
    const pre_id_error_count = errors.count();
    const id_thunk = try validateStep(allocator, expr.id, errors);
    if (id_thunk == null and errors.count() == pre_id_error_count) {
        try errors.add(allocator, .{ .message = "An expression must have an ID" });
    }

    // Validate all arguments
    var valid_args = std.ArrayListUnmanaged(*const Thunk){};
    for (expr.args) |arg_node| {
        if (try validateStep(allocator, arg_node, errors)) |arg_thunk| {
            try valid_args.append(allocator, arg_thunk);
        }
    }

    // Check closing bracket error
    if (expr.close_err) |close_err| {
        try addBracketError(allocator, errors, close_err);
    }

    // If ID was missing, the expression cannot be constructed
    if (id_thunk == null) return null;

    // If any errors were introduced during this expression's validation, return null
    if (errors.count() > init_error_count) return null;

    // Success
    const thunk = try allocator.create(Thunk);
    thunk.* = .{ .expression = .{
        .id = id_thunk.?,
        .args = valid_args.items,
    } };
    return thunk;
}

fn addBracketError(allocator: Allocator, errors: *ValidationErrors, bracket_error: AstBracketError) Allocator.Error!void {
    try errors.add(allocator, .{
        .message = bracket_error.message,
        .line = bracket_error.token_line,
        .column = bracket_error.token_column,
        .start = bracket_error.token_start,
        .end = bracket_error.token_end,
    });
}

// ── Tests ──

const parser = @import("parser.zig");
const ast = ast_mod;
const val = @import("value.zig");

test "validate simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse "say hello"
    const ast_root = try parser.parse(alloc, "say \"hello\"");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |expression| {
            // ID should be a value literal "say"
            try std.testing.expect(expression.id.* == .value_literal);
            try std.testing.expectEqualStrings("say", expression.id.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);
        },
        .err => |errors| {
            std.debug.print("Unexpected validation errors:\n", .{});
            for (errors) |validation_error| {
                std.debug.print("  {s}\n", .{validation_error.message});
            }
            return error.TestUnexpectedResult;
        },
    }
}

test "validate nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse "add (add 1 2) 3"
    const ast_root = try parser.parse(alloc, "add (add 1 2) 3");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |expression| {
            try std.testing.expectEqualStrings("add", expression.id.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 2), expression.args.len);
            // First arg should be a nested expression
            try std.testing.expect(expression.args[0].* == .expression);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "validate scope thunk" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse "say :myVar"
    const ast_root = try parser.parse(alloc, "say :myVar");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |expression| {
            try std.testing.expectEqualStrings("say", expression.id.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);
            try std.testing.expect(expression.args[0].* == .scope_thunk);
        },
        .err => return error.TestUnexpectedResult,
    }
}

test "validate empty input produces errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Empty input produces an AST with an error ID
    const ast_root = try parser.parse(alloc, "");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            try std.testing.expect(errors.len > 0);
        },
    }
}

test "validate accumulates multiple errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Construct an AST with multiple error nodes manually
    const err_node_1 = try ast.makeSyntaxErr(alloc, "first error", 1, 1, 0, 5);
    const err_node_2 = try ast.makeSyntaxErr(alloc, "second error", 1, 6, 5, 10);

    const expr_node = try ast.makeExpression(
        alloc,
        err_node_1,
        &.{err_node_2},
        null,
        null,
        .{ .meta_type = .top_level },
    );

    const result = try validate(alloc, expr_node);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            // Should have at least the two error nodes plus "must have an ID"
            try std.testing.expect(errors.len >= 2);
        },
    }
}

test "validate with bracket errors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Construct an expression with a bracket error
    const id_node = try ast.makeValueLiteral(alloc, .{ .string = "say" });

    const expr_node = try ast.makeExpression(
        alloc,
        id_node,
        &.{},
        .{
            .message = "Missing closing bracket",
            .token_line = 1,
            .token_column = 1,
            .token_start = 0,
            .token_end = 1,
        },
        null,
        .{ .meta_type = .standard },
    );

    const result = try validate(alloc, expr_node);

    switch (result) {
        .ok => return error.TestUnexpectedResult,
        .err => |errors| {
            try std.testing.expect(errors.len >= 1);
            try std.testing.expectEqualStrings("Missing closing bracket", errors[0].message);
        },
    }
}

test "validate end-to-end with execution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Register an "echo" operation that returns its argument
    var registry = exec_mod.Registry{};
    try registry.registerOperation(alloc, "echo", exec_mod.Operation.fromFn(testEchoOp));

    var env = exec_mod.Env{ .registry = &registry, .allocator = alloc };
    const scope = exec_mod.Scope.EMPTY;

    // Parse and validate: echo 42
    const ast_root = try parser.parse(alloc, "echo 42");
    const validation_result = try validate(alloc, ast_root);

    switch (validation_result) {
        .ok => |expression| {
            const exec_result = try env.processExpression(expression, &scope);
            try std.testing.expectEqual(@as(i64, 42), exec_result.?.int);
        },
        .err => return error.TestUnexpectedResult,
    }
}

fn testEchoOp(args: exec_mod.Args) exec_mod.ExecError!?val.Value {
    return args.at(0).get();
}

test "validate list literal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Parse "say [1 2 3]"
    const ast_root = try parser.parse(alloc, "say [1 2 3]");
    const result = try validate(alloc, ast_root);

    switch (result) {
        .ok => |expression| {
            // Top level: say with one arg (the list expression)
            try std.testing.expectEqualStrings("say", expression.id.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 1), expression.args.len);

            // The list arg should be an expression with id "list"
            const list_expr = expression.args[0].expression;
            try std.testing.expectEqualStrings("list", list_expr.id.value_literal.?.string);
            try std.testing.expectEqual(@as(usize, 3), list_expr.args.len);
        },
        .err => return error.TestUnexpectedResult,
    }
}
