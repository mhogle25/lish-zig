const std = @import("std");
const ast_mod = @import("ast.zig");
const macro_parser_mod = @import("macro_parser.zig");
const val_mod = @import("value.zig");

const Allocator = std.mem.Allocator;
const AstNode = ast_mod.AstNode;
const AstExpression = ast_mod.AstExpression;
const AstMacro = macro_parser_mod.AstMacro;
const AstMacroParam = macro_parser_mod.AstMacroParam;
const Value = val_mod.Value;

/// Fluent builder for AST nodes. Backed by an allocator (typically an arena).
/// All produced nodes are owned by that allocator.
pub const AstBuilder = struct {
    allocator: Allocator,

    pub fn init(allocator: Allocator) AstBuilder {
        return .{ .allocator = allocator };
    }

    // ── Leaf node constructors ──

    pub fn int(self: AstBuilder, value: i64) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, .{ .int = value });
    }

    pub fn float(self: AstBuilder, value: f64) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, .{ .float = value });
    }

    pub fn string(self: AstBuilder, value: []const u8) Allocator.Error!*const AstNode {
        return ast_mod.makeValueLiteral(self.allocator, .{ .string = value });
    }

    /// Produces a `:name` scope thunk.
    pub fn scope(self: AstBuilder, name: []const u8) Allocator.Error!*const AstNode {
        const id_node = try ast_mod.makeValueLiteral(self.allocator, .{ .string = name });
        return ast_mod.makeScopeThunk(self.allocator, id_node);
    }

    /// Produces a `$name` zero-argument call expression.
    pub fn call(self: AstBuilder, name: []const u8) Allocator.Error!*const AstNode {
        const id_node = try ast_mod.makeValueLiteral(self.allocator, .{ .string = name });
        return ast_mod.makeExpression(self.allocator, id_node, &.{}, null, null,
            .{ .meta_type = .single_term });
    }

    // ── Builder factories ──

    /// Start building an expression with the given operation name as its ID.
    /// Call `.arg()` to add arguments, then `.build()` to finish.
    pub fn expr(self: AstBuilder, id: []const u8) ExprBuilder {
        return .{
            .builder = self,
            .id = id,
            .args = .{},
            .sticky_err = null,
        };
    }

    /// Start building a macro definition with the given name.
    /// Call `.param()` / `.deferredParam()` to add parameters, then `.body()` to finish.
    pub fn macro(self: AstBuilder, name: []const u8) MacroBuilder {
        return .{
            .builder = self,
            .name = name,
            .params = .{},
            .sticky_err = null,
        };
    }
};

pub const BuildOptions = struct {
    meta_type: AstExpression.MetaType = .standard,
};

/// Builds an expression node incrementally. Stores OOM errors and surfaces them
/// at `.build()` time, allowing uninterrupted method chaining.
pub const ExprBuilder = struct {
    builder: AstBuilder,
    id: []const u8,
    args: std.ArrayListUnmanaged(*const AstNode),
    sticky_err: ?Allocator.Error,

    /// Append an argument node. Returns self for chaining.
    /// If allocation fails, the error is held and returned by `.build()`.
    pub fn arg(self: *ExprBuilder, node: *const AstNode) *ExprBuilder {
        self.args.append(self.builder.allocator, node) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Finish building the expression. Defaults to `.standard` meta type.
    pub fn build(self: *ExprBuilder, options: BuildOptions) Allocator.Error!*const AstNode {
        if (self.sticky_err) |err| return err;
        const id_node = try ast_mod.makeValueLiteral(self.builder.allocator, .{ .string = self.id });
        const args_slice = try self.args.toOwnedSlice(self.builder.allocator);
        return ast_mod.makeExpression(self.builder.allocator, id_node, args_slice, null, null,
            .{ .meta_type = options.meta_type });
    }
};

/// Builds a macro definition incrementally.
pub const MacroBuilder = struct {
    builder: AstBuilder,
    name: []const u8,
    params: std.ArrayListUnmanaged(AstMacroParam),
    sticky_err: ?Allocator.Error,

    /// Append a value parameter (`:name` in macro body). Returns self for chaining.
    pub fn param(self: *MacroBuilder, name: []const u8) *MacroBuilder {
        self.params.append(self.builder.allocator, .{ .valid = .{
            .id = name,
            .param_type = .value,
        } }) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Append a deferred parameter (`~name` in macro definition). Returns self for chaining.
    pub fn deferredParam(self: *MacroBuilder, name: []const u8) *MacroBuilder {
        self.params.append(self.builder.allocator, .{ .valid = .{
            .id = name,
            .param_type = .deferred,
        } }) catch |err| {
            self.sticky_err = err;
        };
        return self;
    }

    /// Finish building by providing the body expression node. Returns the completed AstMacro.
    pub fn body(self: *MacroBuilder, body_node: *const AstNode) Allocator.Error!AstMacro {
        if (self.sticky_err) |err| return err;
        const params_slice = try self.params.toOwnedSlice(self.builder.allocator);
        return AstMacro{
            .id = .{ .valid = self.name },
            .parameters = params_slice,
            .body = body_node,
        };
    }
};

// ── Tests ──

const serializer_mod = @import("serializer.zig");

fn expectExpr(node: *const AstNode, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try serializer_mod.serializeExpression(node, stream.writer());
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

fn expectMacro(macro_def: AstMacro, expected: []const u8) !void {
    var buf: [256]u8 = undefined;
    var stream = std.io.fixedBufferStream(&buf);
    try serializer_mod.serializeMacro(macro_def, stream.writer());
    try std.testing.expectEqualStrings(expected, stream.getWritten());
}

test "builder: leaf nodes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    try expectExpr(try b.int(42), "42");
    try expectExpr(try b.float(3.14), "3.14");
    try expectExpr(try b.string("hello"), "hello");
    try expectExpr(try b.string("hello world"), "\"hello world\"");
    try expectExpr(try b.scope("x"), ":x");
    try expectExpr(try b.call("none"), "$none");
}

test "builder: call vs string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    try expectExpr(try b.call("some"), "$some");
    try expectExpr(try b.string("some"), "some");
}

test "builder: simple expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var eb = b.expr("+");
    const node = try eb.arg(try b.int(1)).arg(try b.int(2)).build(.{});
    try expectExpr(node, "+ 1 2");
}

test "builder: nested expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // + (+ 1 2) 3
    var inner = b.expr("+");
    const inner_node = try inner.arg(try b.int(1)).arg(try b.int(2)).build(.{});

    var outer = b.expr("+");
    const root = try outer.arg(inner_node).arg(try b.int(3)).build(.{});
    try expectExpr(root, "+ (+ 1 2) 3");
}

test "builder: scope thunk arg" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // * :x 2
    var eb = b.expr("*");
    const node = try eb.arg(try b.scope("x")).arg(try b.int(2)).build(.{});
    try expectExpr(node, "* :x 2");
}

test "builder: meta_type override" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    var eb = b.expr("+");
    const node = try eb.arg(try b.int(1)).build(.{ .meta_type = .top_level });
    try std.testing.expectEqual(
        AstExpression.MetaType.top_level,
        node.expression.meta.meta_type,
    );
}

test "builder: macro with value param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // |double x| * :x 2
    var body_eb = b.expr("*");
    const body_node = try body_eb.arg(try b.scope("x")).arg(try b.int(2)).build(.{});

    var mb = b.macro("double");
    const macro_def = try mb.param("x").body(body_node);
    try expectMacro(macro_def, "|double x| * :x 2");
}

test "builder: macro with deferred param" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // |do-twice ~action| proc :action :action
    var body_eb = b.expr("proc");
    const body_node = try body_eb
        .arg(try b.scope("action"))
        .arg(try b.scope("action"))
        .build(.{});

    var mb = b.macro("do-twice");
    const macro_def = try mb.deferredParam("action").body(body_node);
    try expectMacro(macro_def, "|do-twice ~action| proc :action :action");
}

test "builder: macro with no params" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // |greet| say hello
    var body_eb = b.expr("say");
    const body_node = try body_eb.arg(try b.string("hello")).build(.{});

    var mb = b.macro("greet");
    const macro_def = try mb.body(body_node);
    try expectMacro(macro_def, "|greet| say hello");
}

test "builder: complex macro" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const b = AstBuilder.init(arena.allocator());

    // |greet name| say (concat "hello " :name)
    var concat_eb = b.expr("concat");
    const concat_node = try concat_eb
        .arg(try b.string("hello "))
        .arg(try b.scope("name"))
        .build(.{});

    var say_eb = b.expr("say");
    const say_node = try say_eb.arg(concat_node).build(.{});

    var mb = b.macro("greet");
    const macro_def = try mb.param("name").body(say_node);
    try expectMacro(macro_def, "|greet name| say (concat \"hello \" :name)");
}
