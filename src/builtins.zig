const std = @import("std");
const exec = @import("exec.zig");
const val = @import("value.zig");

const Value = val.Value;
const Args = exec.Args;
const ExecError = exec.ExecError;
const Expression = exec.Expression;
const Thunk = exec.Thunk;
const Registry = exec.Registry;
const Allocator = std.mem.Allocator;

// ── Registration ──

pub fn registerAll(registry: *Registry, allocator: Allocator) Allocator.Error!void {
    // Constants
    try registry.registerOperation(allocator, "some", &someOp);
    try registry.registerOperation(allocator, "none", &noneOp);

    // Arithmetic
    try registry.registerOperation(allocator, "+", &addOp);
    try registry.registerOperation(allocator, "-", &subtractOp);
    try registry.registerOperation(allocator, "*", &multiplyOp);
    try registry.registerOperation(allocator, "/", &divideOp);
    try registry.registerOperation(allocator, "%", &moduloOp);
    try registry.registerOperation(allocator, "^", &powerOp);

    // Comparison
    try registry.registerOperation(allocator, "<", &lessThanOp);
    try registry.registerOperation(allocator, "<=", &lessThanOrEqualOp);
    try registry.registerOperation(allocator, ">", &greaterThanOp);
    try registry.registerOperation(allocator, ">=", &greaterThanOrEqualOp);
    try registry.registerOperation(allocator, "is", &isOp);
    try registry.registerOperation(allocator, "isnt", &isntOp);
    try registry.registerOperation(allocator, "compare", &compareOp);

    // Logic
    try registry.registerOperation(allocator, "and", &andOp);
    try registry.registerOperation(allocator, "or", &orOp);
    try registry.registerOperation(allocator, "not", &notOp);
    // Control flow
    try registry.registerOperation(allocator, "if", &ifElseOp);
    try registry.registerOperation(allocator, "when", &whenOp);
    try registry.registerOperation(allocator, "match", &matchOp);

    // String
    try registry.registerOperation(allocator, "concat", &concatOp);
    try registry.registerOperation(allocator, "join", &joinOp);
    try registry.registerOperation(allocator, "say", &sayOp);
    try registry.registerOperation(allocator, "error", &errorOp);

    // List
    try registry.registerOperation(allocator, "list", &listOp);
    try registry.registerOperation(allocator, "flat", &flatOp);
    try registry.registerOperation(allocator, "length", &lengthOp);
    try registry.registerOperation(allocator, "first", &firstOp);
    try registry.registerOperation(allocator, "rest", &restOp);
    try registry.registerOperation(allocator, "at", &atOp);
    try registry.registerOperation(allocator, "reverse", &reverseOp);
    try registry.registerOperation(allocator, "range", &rangeOp);
    try registry.registerOperation(allocator, "until", &untilOp);

    // Higher-order
    try registry.registerOperation(allocator, "map", &mapOp);
    try registry.registerOperation(allocator, "foreach", &foreachOp);
    try registry.registerOperation(allocator, "apply", &applyOp);
    try registry.registerOperation(allocator, "filter", &filterOp);
    try registry.registerOperation(allocator, "reduce", &reduceOp);

    // Utility
    try registry.registerOperation(allocator, "identity", &identityOp);

    // Sequencing
    try registry.registerOperation(allocator, "proc", &procOp);

    // Type conversion
    try registry.registerOperation(allocator, "int", &intOp);
    try registry.registerOperation(allocator, "float", &floatOp);
    try registry.registerOperation(allocator, "string", &stringOp);

    // Type inspection
    try registry.registerOperation(allocator, "type", &typeOp);

    // String predicates
    try registry.registerOperation(allocator, "prefix", &prefixOp);
    try registry.registerOperation(allocator, "suffix", &suffixOp);
    try registry.registerOperation(allocator, "in", &inOp);

    // Math utilities
    try registry.registerOperation(allocator, "min", &minOp);
    try registry.registerOperation(allocator, "max", &maxOp);
    try registry.registerOperation(allocator, "clamp", &clampOp);
    try registry.registerOperation(allocator, "abs", &absOp);
    try registry.registerOperation(allocator, "floor", &floorOp);
    try registry.registerOperation(allocator, "ceil", &ceilOp);
    try registry.registerOperation(allocator, "round", &roundOp);
}

// ── Constants ──

fn someOp(_: Args) ExecError!?Value {
    return val.some();
}

fn noneOp(_: Args) ExecError!?Value {
    return null;
}

// ── Arithmetic ──

fn addOp(args: Args) ExecError!?Value {
    return numericFold(args, addInt, addFloat);
}
fn addInt(left: i64, right: i64) i64 {
    return left +% right;
}
fn addFloat(left: f64, right: f64) f64 {
    return left + right;
}

fn subtractOp(args: Args) ExecError!?Value {
    return numericFold(args, subInt, subFloat);
}
fn subInt(left: i64, right: i64) i64 {
    return left -% right;
}
fn subFloat(left: f64, right: f64) f64 {
    return left - right;
}

fn multiplyOp(args: Args) ExecError!?Value {
    return numericFold(args, mulInt, mulFloat);
}
fn mulInt(left: i64, right: i64) i64 {
    return left *% right;
}
fn mulFloat(left: f64, right: f64) f64 {
    return left * right;
}

fn divideOp(args: Args) ExecError!?Value {
    return numericFold(args, divInt, divFloat);
}
fn divInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @divTrunc(left, right);
}
fn divFloat(left: f64, right: f64) f64 {
    return left / right;
}

fn moduloOp(args: Args) ExecError!?Value {
    return numericFold(args, modInt, modFloat);
}
fn modInt(left: i64, right: i64) i64 {
    return if (right == 0) 0 else @mod(left, right);
}
fn modFloat(left: f64, right: f64) f64 {
    return @mod(left, right);
}

fn powerOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (!accumulator.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (accumulator == .float or operand == .float) {
            const base = accumulator.getF() catch unreachable;
            const exponent = operand.getF() catch unreachable;
            accumulator = .{ .float = std.math.pow(f64, base, exponent) };
        } else {
            const base: f64 = @floatFromInt(accumulator.getI() catch unreachable);
            const exponent: f64 = @floatFromInt(operand.getI() catch unreachable);
            accumulator = .{ .int = @intFromFloat(std.math.pow(f64, base, exponent)) };
        }
    }
    return accumulator;
}

// ── Comparison ──

fn lessThanOp(args: Args) ExecError!?Value {
    return numericComparison(args, cmpLtInt, cmpLtFloat);
}
fn cmpLtInt(left: i64, right: i64) bool {
    return left < right;
}
fn cmpLtFloat(left: f64, right: f64) bool {
    return left < right;
}

fn lessThanOrEqualOp(args: Args) ExecError!?Value {
    return numericComparison(args, cmpLeInt, cmpLeFloat);
}
fn cmpLeInt(left: i64, right: i64) bool {
    return left <= right;
}
fn cmpLeFloat(left: f64, right: f64) bool {
    return left <= right;
}

fn greaterThanOp(args: Args) ExecError!?Value {
    return numericComparison(args, cmpGtInt, cmpGtFloat);
}
fn cmpGtInt(left: i64, right: i64) bool {
    return left > right;
}
fn cmpGtFloat(left: f64, right: f64) bool {
    return left > right;
}

fn greaterThanOrEqualOp(args: Args) ExecError!?Value {
    return numericComparison(args, cmpGeInt, cmpGeFloat);
}
fn cmpGeInt(left: i64, right: i64) bool {
    return left >= right;
}
fn cmpGeFloat(left: f64, right: f64) bool {
    return left >= right;
}

fn isOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).get();
    const right = try args.at(1).get();

    if (left == null and right == null) return val.some();
    if (left == null or right == null) return null;
    return val.toCondition(left.?.eql(right.?));
}

fn isntOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).get();
    const right = try args.at(1).get();

    if (left == null and right == null) return null;
    if (left == null or right == null) return val.some();
    return val.toCondition(!left.?.eql(right.?));
}

fn compareOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const left = try args.at(0).resolve();
    const right = try args.at(1).resolve();

    if (left.isNumber() and right.isNumber()) {
        const left_f = left.getF() catch unreachable;
        const right_f = right.getF() catch unreachable;
        const result: i64 = if (left_f < right_f) -1 else if (left_f > right_f) @as(i64, 1) else 0;
        return .{ .int = result };
    }

    if (left == .string and right == .string) {
        const order = std.mem.order(u8, left.string, right.string);
        const result: i64 = switch (order) {
            .lt => -1,
            .gt => 1,
            .eq => 0,
        };
        return .{ .int = result };
    }

    return args.env.fail("Cannot compare values of different types");
}

// ── Logic ──

fn andOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var last: ?Value = null;
    for (0..args.count()) |i| {
        last = try args.at(i).get();
        if (last == null) return null;
    }
    return last;
}

fn orOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    for (0..args.count()) |i| {
        const result = try args.at(i).get();
        if (result != null) return result;
    }
    return null;
}

fn notOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const result = try args.at(0).get();
    return if (result != null) null else val.some();
}

// ── Control flow ──

fn ifElseOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count != 2 and count != 4) return args.env.fail("'if' expects 2 or 4 arguments");

    const condition = try args.at(0).get();

    if (count == 2) {
        return if (condition != null) try args.at(1).get() else null;
    }

    // 4-arg form: validate "else" keyword
    var else_buf: [64]u8 = undefined;
    const else_keyword = try args.at(2).resolveString(&else_buf);
    if (!std.mem.eql(u8, else_keyword, "else")) {
        return args.env.fail("Expected 'else' as third argument to 'if'");
    }

    return if (condition != null) try args.at(1).get() else try args.at(3).get();
}

fn whenOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count % 2 != 0) {
        return args.env.fail("'when' expects an even number of arguments (condition/result pairs)");
    }

    var i: usize = 0;
    while (i < count) : (i += 2) {
        const condition = try args.at(i).get();
        if (condition != null) {
            return args.at(i + 1).get();
        }
    }

    return null;
}

fn matchOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 3 or count % 2 == 0) {
        return args.env.fail("'match' expects an odd number of arguments (target + pattern/result pairs)");
    }

    const target = try args.at(0).get();

    var i: usize = 1;
    while (i < count) : (i += 2) {
        const pattern = try args.at(i).get();

        const matches = if (target == null and pattern == null)
            true
        else if (target != null and pattern != null)
            target.?.eql(pattern.?)
        else
            false;

        if (matches) {
            return args.at(i + 1).get();
        }
    }

    return null;
}

// ── String ──

fn concatOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = std.ArrayListUnmanaged(u8){};
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            try result.appendSlice(args.env.allocator, str);
        }
    }
    return .{ .string = result.items };
}

fn joinOp(args: Args) ExecError!?Value {
    try args.expectMinCount(3);
    var sep_buf: [256]u8 = undefined;
    const separator = try args.at(0).resolveString(&sep_buf);
    const separator_owned = try args.env.allocator.dupe(u8, separator);

    var result = std.ArrayListUnmanaged(u8){};
    for (1..args.count()) |i| {
        if (i > 1) {
            try result.appendSlice(args.env.allocator, separator_owned);
        }
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            try result.appendSlice(args.env.allocator, str);
        }
    }
    return .{ .string = result.items };
}

fn sayOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stdout orelse return null;
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str) catch {};
        writer.writeByte('\n') catch {};
    }
    return null;
}

fn errorOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    const writer = args.env.stderr orelse return null;
    for (0..args.count()) |i| {
        var buf: [256]u8 = undefined;
        const str = try args.at(i).resolveString(&buf);
        writer.writeAll(str) catch {};
        writer.writeByte('\n') catch {};
    }
    return null;
}

// ── List ──

fn listOp(args: Args) ExecError!?Value {
    const items = try args.env.allocator.alloc(?Value, args.count());
    for (0..args.count()) |i| {
        items[i] = try args.at(i).get();
    }
    return .{ .list = items };
}

fn flatOp(args: Args) ExecError!?Value {
    var result = std.ArrayListUnmanaged(?Value){};
    for (0..args.count()) |i| {
        const maybe_value = try args.at(i).get();
        if (maybe_value) |value| {
            if (value == .list) {
                for (value.list) |item| {
                    try result.append(args.env.allocator, item);
                }
            } else {
                try result.append(args.env.allocator, value);
            }
        } else {
            try result.append(args.env.allocator, null);
        }
    }
    return .{ .list = result.items };
}

fn lengthOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| .{ .int = @intCast(items.len) },
        .string => |str| .{ .int = @intCast(str.len) },
        else => args.env.fail("'length' expects a list or string"),
    };
}

fn firstOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| if (items.len == 0) null else items[0],
        .string => |str| if (str.len == 0) null else .{ .string = str[0..1] },
        else => args.env.fail("'first' expects a list or string"),
    };
}

fn restOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .list => |items| if (items.len <= 1) .{ .list = &.{} } else .{ .list = items[1..] },
        .string => |str| if (str.len <= 1) .{ .string = "" } else .{ .string = str[1..] },
        else => args.env.fail("'rest' expects a list or string"),
    };
}

fn atOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const index_value = try args.at(0).resolve();
    const index = index_value.getI() catch return args.env.fail("'at' expects an integer index");
    if (index < 0) return null;
    const collection = try args.at(1).resolve();
    return switch (collection) {
        .list => |items| {
            if (index >= @as(i64, @intCast(items.len))) return null;
            return items[@intCast(index)];
        },
        .string => |str| {
            if (index >= @as(i64, @intCast(str.len))) return null;
            const idx: usize = @intCast(index);
            return .{ .string = str[idx .. idx + 1] };
        },
        else => args.env.fail("'at' expects a list or string"),
    };
}

fn reverseOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    const alloc = args.env.allocator;
    return switch (value) {
        .list => |items| {
            const reversed = try alloc.alloc(?Value, items.len);
            for (items, 0..) |item, i| {
                reversed[items.len - 1 - i] = item;
            }
            return .{ .list = reversed };
        },
        .string => |str| {
            const reversed = try alloc.alloc(u8, str.len);
            for (str, 0..) |char, i| {
                reversed[str.len - 1 - i] = char;
            }
            return .{ .string = reversed };
        },
        else => args.env.fail("'reverse' expects a list or string"),
    };
}

fn rangeOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count > 3) return args.env.fail("'range' expects 2 or 3 arguments");

    const start_value = try args.at(0).resolve();
    const end_value = try args.at(1).resolve();
    const start = start_value.getI() catch return args.env.fail("'range' expects integer arguments");
    const end = end_value.getI() catch return args.env.fail("'range' expects integer arguments");

    var step: i64 = if (start <= end) 1 else -1;
    if (count == 3) {
        const step_value = try args.at(2).resolve();
        step = step_value.getI() catch return args.env.fail("'range' expects an integer step");
        if (step == 0) return args.env.fail("'range' step cannot be zero");
    }

    const alloc = args.env.allocator;
    var items = std.ArrayListUnmanaged(?Value){};

    var current = start;
    if (step > 0) {
        while (current <= end) : (current += step) {
            try items.append(alloc, .{ .int = current });
        }
    } else {
        while (current >= end) : (current += step) {
            try items.append(alloc, .{ .int = current });
        }
    }

    return .{ .list = items.items };
}

fn untilOp(args: Args) ExecError!?Value {
    const count = args.count();
    if (count < 2 or count > 3) return args.env.fail("'until' expects 2 or 3 arguments");

    const start_value = try args.at(0).resolve();
    const end_value = try args.at(1).resolve();
    const start = start_value.getI() catch return args.env.fail("'until' expects integer arguments");
    const end = end_value.getI() catch return args.env.fail("'until' expects integer arguments");

    var step: i64 = if (start <= end) 1 else -1;
    if (count == 3) {
        const step_value = try args.at(2).resolve();
        step = step_value.getI() catch return args.env.fail("'until' expects an integer step");
        if (step == 0) return args.env.fail("'until' step cannot be zero");
    }

    const alloc = args.env.allocator;
    var items = std.ArrayListUnmanaged(?Value){};

    var current = start;
    if (step > 0) {
        while (current < end) : (current += step) {
            try items.append(alloc, .{ .int = current });
        }
    } else {
        while (current > end) : (current += step) {
            try items.append(alloc, .{ .int = current });
        }
    }

    return .{ .list = items.items };
}

// ── Higher-order ──

fn mapOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const id_value = try args.at(0).resolve();
    const list = try args.at(1).resolveList();

    const alloc = args.env.allocator;
    const id_thunk = try exec.makeValueLiteral(alloc, id_value);
    const results = try alloc.alloc(?Value, list.len);

    for (list, 0..) |item, i| {
        const item_thunk = try exec.makeValueLiteral(alloc, item);
        const arg_thunks = try alloc.alloc(*const Thunk, 1);
        arg_thunks[0] = item_thunk;
        const expression = Expression{ .id = id_thunk, .args = arg_thunks };
        results[i] = try args.env.processExpression(expression, args.scope);
    }
    return .{ .list = results };
}

fn foreachOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const id_value = try args.at(0).resolve();
    const list = try args.at(1).resolveList();

    const alloc = args.env.allocator;
    const id_thunk = try exec.makeValueLiteral(alloc, id_value);

    for (list) |item| {
        const item_thunk = try exec.makeValueLiteral(alloc, item);
        const arg_thunks = try alloc.alloc(*const Thunk, 1);
        arg_thunks[0] = item_thunk;
        const expression = Expression{ .id = id_thunk, .args = arg_thunks };
        _ = try args.env.processExpression(expression, args.scope);
    }
    return null;
}

fn applyOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const id_value = try args.at(0).resolve();
    const list = try args.at(1).resolveList();

    const alloc = args.env.allocator;
    const id_thunk = try exec.makeValueLiteral(alloc, id_value);
    const thunks = try alloc.alloc(*const Thunk, list.len);
    for (list, 0..) |item, i| {
        thunks[i] = try exec.makeValueLiteral(alloc, item);
    }

    const expression = Expression{ .id = id_thunk, .args = thunks };
    return args.env.processExpression(expression, args.scope);
}

fn filterOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const id_value = try args.at(0).resolve();
    const list = try args.at(1).resolveList();

    const alloc = args.env.allocator;
    const id_thunk = try exec.makeValueLiteral(alloc, id_value);
    var results = std.ArrayListUnmanaged(?Value){};

    for (list) |item| {
        const item_thunk = try exec.makeValueLiteral(alloc, item);
        const arg_thunks = try alloc.alloc(*const Thunk, 1);
        arg_thunks[0] = item_thunk;
        const expression = Expression{ .id = id_thunk, .args = arg_thunks };
        const result = try args.env.processExpression(expression, args.scope);
        if (result != null) {
            try results.append(alloc, item);
        }
    }
    return .{ .list = results.items };
}

fn reduceOp(args: Args) ExecError!?Value {
    try args.expectCount(3);
    const id_value = try args.at(0).resolve();
    var accumulator = try args.at(1).get();
    const list = try args.at(2).resolveList();

    const alloc = args.env.allocator;
    const id_thunk = try exec.makeValueLiteral(alloc, id_value);

    for (list) |item| {
        const acc_thunk = try exec.makeValueLiteral(alloc, accumulator);
        const item_thunk = try exec.makeValueLiteral(alloc, item);
        const arg_thunks = try alloc.alloc(*const Thunk, 2);
        arg_thunks[0] = acc_thunk;
        arg_thunks[1] = item_thunk;
        const expression = Expression{ .id = id_thunk, .args = arg_thunks };
        accumulator = try args.env.processExpression(expression, args.scope);
    }
    return accumulator;
}

// ── Utility ──

fn identityOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    return args.at(0).get();
}

// ── Sequencing ──

fn procOp(args: Args) ExecError!?Value {
    try args.expectMinCount(1);
    var result: ?Value = null;
    for (0..args.count()) |i| {
        result = try args.at(i).get();
    }
    return result;
}

// ── Type conversion ──

fn intOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(float_val) },
        .string => |str| {
            const parsed = std.fmt.parseInt(i64, str, 10) catch return null;
            return .{ .int = parsed };
        },
        .list => null,
    };
}

fn floatOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .float => value,
        .int => |int_val| .{ .float = @floatFromInt(int_val) },
        .string => |str| {
            const parsed = std.fmt.parseFloat(f64, str) catch return null;
            return .{ .float = parsed };
        },
        .list => null,
    };
}

fn stringOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return switch (value) {
        .string => value,
        .int, .float, .list => {
            var buf: [256]u8 = undefined;
            const str = value.getS(&buf);
            const owned = try args.env.allocator.dupe(u8, str);
            return .{ .string = owned };
        },
    };
}

// ── Type inspection ──

fn typeOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const maybe_value = try args.at(0).get();
    const value = maybe_value orelse return null;
    return .{ .string = switch (value) {
        .int => "int",
        .float => "float",
        .string => "string",
        .list => "list",
    } };
}

// ── String predicates ──

fn prefixOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    var pattern_buf: [256]u8 = undefined;
    const pattern = try args.at(0).resolveString(&pattern_buf);
    const pattern_len = pattern.len;
    var target_buf: [256]u8 = undefined;
    const target = try args.at(1).resolveString(&target_buf);
    if (!std.mem.startsWith(u8, target, pattern)) return null;
    const remainder = try args.env.allocator.dupe(u8, target[pattern_len..]);
    return .{ .string = remainder };
}

fn suffixOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    var pattern_buf: [256]u8 = undefined;
    const pattern = try args.at(0).resolveString(&pattern_buf);
    const pattern_len = pattern.len;
    var target_buf: [256]u8 = undefined;
    const target = try args.at(1).resolveString(&target_buf);
    if (!std.mem.endsWith(u8, target, pattern)) return null;
    const remainder = try args.env.allocator.dupe(u8, target[0 .. target.len - pattern_len]);
    return .{ .string = remainder };
}

fn inOp(args: Args) ExecError!?Value {
    try args.expectCount(2);
    const needle = try args.at(0).resolve();
    const haystack = try args.at(1).resolve();
    return switch (haystack) {
        .string => |haystack_str| {
            var needle_buf: [256]u8 = undefined;
            const needle_str = needle.getS(&needle_buf);
            if (std.mem.indexOf(u8, haystack_str, needle_str) != null) return needle;
            return null;
        },
        .list => |items| {
            for (items) |item| {
                if (item != null and needle.eql(item.?)) return needle;
            }
            return null;
        },
        else => args.env.fail("'in' expects a string or list as second argument"),
    };
}

// ── Math utilities ──

fn minOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @min(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @min(left, right) };
        }
    }
    return result;
}

fn maxOp(args: Args) ExecError!?Value {
    try args.expectMinCount(2);
    var result = try args.at(0).resolve();
    if (!result.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (result == .float or operand == .float) {
            const left = result.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            result = .{ .float = @max(left, right) };
        } else {
            const left = result.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            result = .{ .int = @max(left, right) };
        }
    }
    return result;
}

fn clampOp(args: Args) ExecError!?Value {
    try args.expectCount(3);
    const value = try args.at(0).resolve();
    const min_val = try args.at(1).resolve();
    const max_val = try args.at(2).resolve();
    if (!value.isNumber() or !min_val.isNumber() or !max_val.isNumber())
        return args.env.fail("Expected a number");

    if (value == .float or min_val == .float or max_val == .float) {
        const val_f = value.getF() catch unreachable;
        const min_f = min_val.getF() catch unreachable;
        const max_f = max_val.getF() catch unreachable;
        return .{ .float = @max(min_f, @min(val_f, max_f)) };
    } else {
        const val_i = value.getI() catch unreachable;
        const min_i = min_val.getI() catch unreachable;
        const max_i = max_val.getI() catch unreachable;
        return .{ .int = @max(min_i, @min(val_i, max_i)) };
    }
}

fn absOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => |int_val| .{ .int = if (int_val < 0) -%int_val else int_val },
        .float => |float_val| .{ .float = @abs(float_val) },
        else => args.env.fail("Expected a number"),
    };
}

fn floorOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@floor(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

fn ceilOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@ceil(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

fn roundOp(args: Args) ExecError!?Value {
    try args.expectCount(1);
    const value = try args.at(0).resolve();
    return switch (value) {
        .int => value,
        .float => |float_val| .{ .int = @intFromFloat(@round(float_val)) },
        else => args.env.fail("Expected a number"),
    };
}

// ── Numeric helpers ──

fn numericFold(
    args: Args,
    int_op: *const fn (i64, i64) i64,
    float_op: *const fn (f64, f64) f64,
) ExecError!?Value {
    try args.expectMinCount(2);
    var accumulator = try args.at(0).resolve();
    if (!accumulator.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const operand = try args.at(i).resolve();
        if (!operand.isNumber()) return args.env.fail("Expected a number");

        if (accumulator == .float or operand == .float) {
            const left = accumulator.getF() catch unreachable;
            const right = operand.getF() catch unreachable;
            accumulator = .{ .float = float_op(left, right) };
        } else {
            const left = accumulator.getI() catch unreachable;
            const right = operand.getI() catch unreachable;
            accumulator = .{ .int = int_op(left, right) };
        }
    }
    return accumulator;
}

fn numericComparison(
    args: Args,
    int_cmp: *const fn (i64, i64) bool,
    float_cmp: *const fn (f64, f64) bool,
) ExecError!?Value {
    try args.expectMinCount(2);
    var prev = try args.at(0).resolve();
    if (!prev.isNumber()) return args.env.fail("Expected a number");

    for (1..args.count()) |i| {
        const current = try args.at(i).resolve();
        if (!current.isNumber()) return args.env.fail("Expected a number");

        const passes = if (prev == .float or current == .float)
            float_cmp(prev.getF() catch unreachable, current.getF() catch unreachable)
        else
            int_cmp(prev.getI() catch unreachable, current.getI() catch unreachable);

        if (!passes) return null;
        prev = current;
    }
    return val.some();
}

// ── Tests ──

fn makeTestEnv(alloc: Allocator, registry: *Registry) exec.Env {
    return .{ .registry = registry, .allocator = alloc };
}

fn evalWithBuiltins(alloc: Allocator, source: []const u8) ExecError!?Value {
    const parser = @import("parser.zig");
    const validation = @import("validation.zig");

    var registry = Registry{};
    registerAll(&registry, alloc) catch return error.OutOfMemory;

    var env = makeTestEnv(alloc, &registry);
    const scope = exec.Scope.EMPTY;

    const ast_root = try parser.parse(alloc, source);
    const result = try validation.validate(alloc, ast_root);

    return switch (result) {
        .ok => |expression| try env.processExpression(expression, &scope),
        .err => error.RuntimeError,
    };
}

test "arithmetic: add" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "+ 1 2 3");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "arithmetic: subtract" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "- 10 3");
    try std.testing.expectEqual(@as(i64, 7), result.?.int);
}

test "arithmetic: multiply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "* 4 5");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "arithmetic: divide" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "/ 10 3");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "arithmetic: float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "+ 1 2.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "arithmetic: power" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "^ 2 10");
    try std.testing.expectEqual(@as(i64, 1024), result.?.int);
}

test "comparison: less than" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try evalWithBuiltins(arena.allocator(), "< 1 2");
    try std.testing.expect(truthy != null);
    const falsy = try evalWithBuiltins(arena.allocator(), "< 2 1");
    try std.testing.expect(falsy == null);
}

test "comparison: chained" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ascending = try evalWithBuiltins(arena.allocator(), "< 1 2 3");
    try std.testing.expect(ascending != null);
    const not_ascending = try evalWithBuiltins(arena.allocator(), "< 1 3 2");
    try std.testing.expect(not_ascending == null);
}

test "comparison: is and isnt" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const equal = try evalWithBuiltins(arena.allocator(), "is 5 5");
    try std.testing.expect(equal != null);
    const not_equal = try evalWithBuiltins(arena.allocator(), "is 5 6");
    try std.testing.expect(not_equal == null);
    const different = try evalWithBuiltins(arena.allocator(), "isnt 5 6");
    try std.testing.expect(different != null);
}

test "comparison: compare" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const less = try evalWithBuiltins(arena.allocator(), "compare 1 2");
    try std.testing.expectEqual(@as(i64, -1), less.?.int);
    const greater = try evalWithBuiltins(arena.allocator(), "compare 2 1");
    try std.testing.expectEqual(@as(i64, 1), greater.?.int);
    const equal = try evalWithBuiltins(arena.allocator(), "compare 5 5");
    try std.testing.expectEqual(@as(i64, 0), equal.?.int);
}

test "logic: and short-circuits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const both_some = try evalWithBuiltins(arena.allocator(), "and $some $some");
    try std.testing.expect(both_some != null);
    const first_none = try evalWithBuiltins(arena.allocator(), "and $none $some");
    try std.testing.expect(first_none == null);
}

test "logic: or short-circuits" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const first_some = try evalWithBuiltins(arena.allocator(), "or $some $none");
    try std.testing.expect(first_some != null);
    const both_none = try evalWithBuiltins(arena.allocator(), "or $none $none");
    try std.testing.expect(both_none == null);
}

test "logic: not" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const negated_some = try evalWithBuiltins(arena.allocator(), "not $some");
    try std.testing.expect(negated_some == null);
    const negated_none = try evalWithBuiltins(arena.allocator(), "not $none");
    try std.testing.expect(negated_none != null);
}

test "control flow: if-then" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try evalWithBuiltins(arena.allocator(), "if $some 42");
    try std.testing.expectEqual(@as(i64, 42), truthy.?.int);
    const falsy = try evalWithBuiltins(arena.allocator(), "if $none 42");
    try std.testing.expect(falsy == null);
}

test "control flow: if-then-else" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const truthy = try evalWithBuiltins(arena.allocator(), "if $some 1 else 2");
    try std.testing.expectEqual(@as(i64, 1), truthy.?.int);
    const falsy = try evalWithBuiltins(arena.allocator(), "if $none 1 else 2");
    try std.testing.expectEqual(@as(i64, 2), falsy.?.int);
}

test "control flow: when" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // First condition is false (none), second is true (some) → returns 2
    const result = try evalWithBuiltins(arena.allocator(), "when $none 1 $some 2");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "control flow: match" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "match 2 1 10 2 20 3 30");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "string: concat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "concat \"hello\" \" \" \"world\"");
    try std.testing.expectEqualStrings("hello world", result.?.string);
}

test "string: join" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "join \",\" \"a\" \"b\" \"c\"");
    try std.testing.expectEqualStrings("a,b,c", result.?.string);
}

test "list: construction" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "list 1 2 3");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 3), items.len);
    try std.testing.expectEqual(@as(i64, 1), items[0].?.int);
    try std.testing.expectEqual(@as(i64, 2), items[1].?.int);
    try std.testing.expectEqual(@as(i64, 3), items[2].?.int);
}

test "list: length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length [1 2 3]");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "list: flat" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "flat 1 [2 3] 4");
    const items = result.?.list;
    try std.testing.expectEqual(@as(usize, 4), items.len);
}

test "higher-order: map" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // map "not" over a list — inverts each element's truthiness
    const result = try evalWithBuiltins(arena.allocator(), "length (map \"length\" [\"ab\" \"cde\"])");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "higher-order: apply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "apply \"+\" [1 2 3]");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "sequencing: proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // proc evaluates all args, returns the last
    const result = try evalWithBuiltins(arena.allocator(), "proc 1 2 3");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "constants: some and none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const some_result = try evalWithBuiltins(arena.allocator(), "some");
    try std.testing.expect(some_result != null);
    const none_result = try evalWithBuiltins(arena.allocator(), "none");
    try std.testing.expect(none_result == null);
}

test "list: first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first [10 20 30]");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "list: first on empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first []");
    try std.testing.expect(result == null);
}

test "list: rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (rest [10 20 30])");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "list: rest on single element" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (rest [10])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: rest on empty list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (rest [])");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at 1 [10 20 30]");
    try std.testing.expectEqual(@as(i64, 20), result.?.int);
}

test "list: at out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at 5 [10 20 30]");
    try std.testing.expect(result == null);
}

test "list: at negative index" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at (- 0 1) [10 20 30]");
    try std.testing.expect(result == null);
}

test "list: reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first (reverse [10 20 30])");
    try std.testing.expectEqual(@as(i64, 30), result.?.int);
}

test "list: range inclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (range 1 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "list: range with step" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at 2 (range 0 10 3)");
    try std.testing.expectEqual(@as(i64, 6), result.?.int);
}

test "list: range descending" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first (range 5 1)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "list: range start > end returns empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (range 5 1 1)");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "list: until exclusive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (until 1 5)");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "list: until same start and end" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "length (until 5 5)");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "higher-order: filter" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // filter "not" over [some none some] — keeps elements where (not element) is truthy
    // (not some) = null (filtered out), (not none) = some (kept), (not some) = null (filtered out)
    const result = try evalWithBuiltins(arena.allocator(), "length (filter \"not\" [$some $none $some])");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "higher-order: reduce" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "reduce \"+\" 0 [1 2 3 4 5]");
    try std.testing.expectEqual(@as(i64, 15), result.?.int);
}

test "higher-order: reduce with multiply" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "reduce \"*\" 1 [2 3 4]");
    try std.testing.expectEqual(@as(i64, 24), result.?.int);
}

test "utility: identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "identity 42");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "utility: identity with none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "identity $none");
    try std.testing.expect(result == null);
}

test "block literal as proc" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    // {expr1 expr2} is sugar for (proc expr1 expr2)
    // At top level: the block becomes a sub-expression whose result is the top-level ID
    // So we use it as an arg: proc {1 2 3} evaluates the block (returns 3)
    const result = try evalWithBuiltins(arena.allocator(), "proc {1 2 3}");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

// ── Type conversion tests ──

test "type conversion: int from float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "int 3.14");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "type conversion: int from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "int \"42\"");
    try std.testing.expectEqual(@as(i64, 42), result.?.int);
}

test "type conversion: int from invalid string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "int \"hello\"");
    try std.testing.expect(result == null);
}

test "type conversion: int from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "int $none");
    try std.testing.expect(result == null);
}

test "type conversion: float from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "float 5");
    try std.testing.expectEqual(@as(f64, 5.0), result.?.float);
}

test "type conversion: float from string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "float \"3.14\"");
    try std.testing.expectApproxEqAbs(@as(f64, 3.14), result.?.float, 0.001);
}

test "type conversion: string from int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "string 42");
    try std.testing.expectEqualStrings("42", result.?.string);
}

test "type conversion: string from none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "string $none");
    try std.testing.expect(result == null);
}

// ── Type inspection tests ──

test "type inspection: int" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "type 42");
    try std.testing.expectEqualStrings("int", result.?.string);
}

test "type inspection: float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "type 3.14");
    try std.testing.expectEqualStrings("float", result.?.string);
}

test "type inspection: string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "type \"hello\"");
    try std.testing.expectEqualStrings("string", result.?.string);
}

test "type inspection: list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "type [1 2]");
    try std.testing.expectEqualStrings("list", result.?.string);
}

test "type inspection: none" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "type $none");
    try std.testing.expect(result == null);
}

// ── String predicate tests ──

test "string predicate: prefix returns remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "prefix \"hel\" \"hello\"");
    try std.testing.expectEqualStrings("lo", result.?.string);
}

test "string predicate: prefix full match returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "prefix \"hello\" \"hello\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string predicate: prefix falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "prefix \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: suffix returns remainder" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "suffix \"llo\" \"hello\"");
    try std.testing.expectEqualStrings("he", result.?.string);
}

test "string predicate: suffix full match returns empty string" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "suffix \"hello\" \"hello\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string predicate: suffix falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "suffix \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: in string returns needle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "in \"ell\" \"hello\"");
    try std.testing.expectEqualStrings("ell", result.?.string);
}

test "string predicate: in string falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "in \"xyz\" \"hello\"");
    try std.testing.expect(result == null);
}

test "string predicate: in list returns needle" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "in 2 [1 2 3]");
    try std.testing.expectEqual(@as(i64, 2), result.?.int);
}

test "string predicate: in list falsy" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "in 5 [1 2 3]");
    try std.testing.expect(result == null);
}

// ── Math utility tests ──

test "math: min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "min 3 1 2");
    try std.testing.expectEqual(@as(i64, 1), result.?.int);
}

test "math: min float promotion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "min 3 1.5 2");
    try std.testing.expectEqual(@as(f64, 1.5), result.?.float);
}

test "math: max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "max 3 1 2");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: clamp within range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "clamp 5 0 10");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: clamp above max" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "clamp 15 0 10");
    try std.testing.expectEqual(@as(i64, 10), result.?.int);
}

test "math: clamp below min" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "clamp (- 0 5) 0 10");
    try std.testing.expectEqual(@as(i64, 0), result.?.int);
}

test "math: abs positive" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "abs 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs negative" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "abs (- 0 5)");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: abs float" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "abs -3.5");
    try std.testing.expectEqual(@as(f64, 3.5), result.?.float);
}

test "math: floor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "floor 3.7");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

test "math: floor int identity" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "floor 5");
    try std.testing.expectEqual(@as(i64, 5), result.?.int);
}

test "math: ceil" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "ceil 3.2");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "round 3.5");
    try std.testing.expectEqual(@as(i64, 4), result.?.int);
}

test "math: round down" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "round 3.4");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}

// ── Dual string/list support tests ──

test "string: at" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at 0 \"hello\"");
    try std.testing.expectEqualStrings("h", result.?.string);
}

test "string: at out of bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "at 10 \"hello\"");
    try std.testing.expect(result == null);
}

test "string: first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first \"hello\"");
    try std.testing.expectEqualStrings("h", result.?.string);
}

test "string: first empty" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "first \"\"");
    try std.testing.expect(result == null);
}

test "string: rest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "rest \"hello\"");
    try std.testing.expectEqualStrings("ello", result.?.string);
}

test "string: rest single char" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "rest \"h\"");
    try std.testing.expectEqualStrings("", result.?.string);
}

test "string: reverse" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "reverse \"hello\"");
    try std.testing.expectEqualStrings("olleh", result.?.string);
}

// ── Comment integration tests ──

test "comment: inline comment in expression" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const result = try evalWithBuiltins(arena.allocator(), "+ 1 ## comment ## 2");
    try std.testing.expectEqual(@as(i64, 3), result.?.int);
}
