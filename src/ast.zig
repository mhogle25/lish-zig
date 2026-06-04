const std = @import("std");
const val = @import("value.zig");
const tok = @import("token.zig");
const exec_mod = @import("exec.zig");

const Value = val.Value;
const Allocator = std.mem.Allocator;
pub const Position = exec_mod.Position;

/// AST node, the intermediate representation produced by parsing. Validated
/// into executable Thunks before evaluation. Carries its source position
/// uniformly; the variant in `body` describes what kind of node it is.
pub const AstNode = struct {
    position: Position,
    body:     AstNodeBody,

    pub fn isErr(self: AstNode) bool {
        return self.body == .err;
    }
};

pub const AstNodeBody = union(enum) {
    expression:    AstExpression,
    value_literal: Value,
    scope_thunk:   *const AstNode,
    err:           AstError,
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

/// Error payload attached to an `err`-variant AstNode. The source position is
/// the wrapping AstNode's `position` field; nothing duplicated here.
pub const AstError = struct {
    message:  []const u8,
    err_type: AstErrorType,
};

/// Bracket error nested inside an AstExpression (not wrapped in an AstNode of
/// its own), so it carries its own position.
pub const AstBracketError = struct {
    position: Position,
    message:  []const u8,
};

/// Known operation IDs used as implicit expression IDs for syntactic sugar.
pub const LIST_ID = "list";
pub const BLOCK_ID = "proc";

// AST construction helpers

pub fn makeValueLiteral(allocator: Allocator, position: Position, v: Value) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .position = position, .body = .{ .value_literal = v } };
    return node;
}

pub fn makeScopeThunk(allocator: Allocator, position: Position, id: *const AstNode) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .position = position, .body = .{ .scope_thunk = id } };
    return node;
}

pub fn makeExpression(
    allocator: Allocator,
    position: Position,
    id: *const AstNode,
    args: []const *const AstNode,
    open_err: ?AstBracketError,
    close_err: ?AstBracketError,
    meta: AstExpression.MetaData,
) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .position = position, .body = .{ .expression = .{
        .id = id,
        .args = args,
        .open_err = open_err,
        .close_err = close_err,
        .meta = meta,
    } } };
    return node;
}

pub fn makeSyntaxErr(allocator: Allocator, position: Position, message: []const u8) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .position = position, .body = .{ .err = .{
        .message  = message,
        .err_type = .syntax,
    } } };
    return node;
}

pub fn makeLogicalErr(allocator: Allocator, position: Position, message: []const u8) Allocator.Error!*AstNode {
    const node = try allocator.create(AstNode);
    node.* = .{ .position = position, .body = .{ .err = .{
        .message  = message,
        .err_type = .logical,
    } } };
    return node;
}

// Tests

test "ast value literal" {
    const node = AstNode{ .position = Position.synthetic, .body = .{ .value_literal = .{ .int = 42 } } };
    try std.testing.expect(!node.isErr());
    try std.testing.expectEqual(@as(i64, 42), node.body.value_literal.int);
}

test "ast error node" {
    const node = AstNode{ .position = .{ .start = 4, .end = 10 }, .body = .{ .err = .{
        .message  = "test error",
        .err_type = .syntax,
    } } };
    try std.testing.expect(node.isErr());
}
