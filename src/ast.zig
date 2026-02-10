const std = @import("std");
const val = @import("value.zig");
const tok = @import("token.zig");

const Value = val.Value;
const Allocator = std.mem.Allocator;

/// AST node - the intermediate representation produced by parsing.
/// Validated into executable Thunks before evaluation.
pub const AstNode = union(enum) {
    expression: AstExpression,
    value_literal: Value,
    scope_thunk: *const AstNode, // the id node to look up
    err: AstError,

    pub fn isErr(self: AstNode) bool {
        return self == .err;
    }
};

pub const AstExpression = struct {
    id: *const AstNode,
    args: []const *const AstNode,
    open_err: ?AstBracketError = null,
    close_err: ?AstBracketError = null,
    meta: MetaData,

    pub const MetaType = enum {
        standard,
        top_level,
        single_term,
        list_literal,
        block_literal,
    };

    pub const MetaData = struct {
        meta_type: MetaType,
    };
};

pub const AstErrorType = enum {
    syntax,
    logical,
};

pub const AstError = struct {
    message: []const u8,
    token_line: usize,
    token_column: usize,
    token_start: usize,
    token_end: usize,
    err_type: AstErrorType,
};

pub const AstBracketError = struct {
    message: []const u8,
    token_line: usize,
    token_column: usize,
    token_start: usize,
    token_end: usize,
};

// ── AST construction helpers ──

pub fn makeValueLiteral(allocator: Allocator, v: Value) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .value_literal = v };
    return node;
}

pub fn makeScopeThunk(allocator: Allocator, id: *const AstNode) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .scope_thunk = id };
    return node;
}

pub fn makeExpression(
    allocator: Allocator,
    id: *const AstNode,
    args: []const *const AstNode,
    open_err: ?AstBracketError,
    close_err: ?AstBracketError,
    meta: AstExpression.MetaData,
) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .expression = .{
        .id = id,
        .args = args,
        .open_err = open_err,
        .close_err = close_err,
        .meta = meta,
    } };
    return node;
}

pub fn makeSyntaxErr(allocator: Allocator, message: []const u8, line: usize, column: usize, start: usize, end: usize) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .err = .{
        .message = message,
        .token_line = line,
        .token_column = column,
        .token_start = start,
        .token_end = end,
        .err_type = .syntax,
    } };
    return node;
}

pub fn makeLogicalErr(allocator: Allocator, message: []const u8, line: usize, column: usize, start: usize, end: usize) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .err = .{
        .message = message,
        .token_line = line,
        .token_column = column,
        .token_start = start,
        .token_end = end,
        .err_type = .logical,
    } };
    return node;
}

// ── Tests ──

test "ast value literal" {
    const node = AstNode{ .value_literal = .{ .int = 42 } };
    try std.testing.expect(!node.isErr());
    try std.testing.expectEqual(@as(i32, 42), node.value_literal.int);
}

test "ast error node" {
    const node = AstNode{ .err = .{
        .message = "test error",
        .token_line = 1,
        .token_column = 5,
        .token_start = 4,
        .token_end = 10,
        .err_type = .syntax,
    } };
    try std.testing.expect(node.isErr());
}
