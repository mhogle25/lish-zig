//! Registry introspection: the canonical machine-readable description of a
//! registry's vocabulary.
//!
//! A lish registry is self-describing. Every operation carries its signature,
//! description, and (when registered through a named group) its category. This
//! module serializes that to the JSON shape editor tooling consumes. The output
//! is registry-derived and reproducible on demand, so nothing is committed to
//! disk; callers obtain it live:
//!
//!   Zig consumers     call these functions directly (lish-lsp, etc.)
//!   `lish --dump-ops` emits the registry of whatever host is running,
//!   `--dump-macros`   including a custom host with its own DSL ops/macros
//!
//! Operations and macros are serialized separately, since they are different
//! kinds: an op is opaque native code whose signature/description must be
//! supplied by its author, while a macro is lish source whose signature is
//! derived from its parameters (`serializeMacros`). Macros carry no required
//! metadata.

const std = @import("std");
const exec = @import("exec.zig");

const Registry = exec.Registry;
const Operation = exec.Operation;
const Macro = exec.Macro;
const Allocator = std.mem.Allocator;

const Entry = struct {
    name: []const u8,
    op: Operation,
};

fn lessByName(_: void, a: Entry, b: Entry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

const MacroEntry = struct {
    name: []const u8,
    macro: *const Macro,
};

fn macroLessByName(_: void, a: MacroEntry, b: MacroEntry) bool {
    return std.mem.order(u8, a.name, b.name) == .lt;
}

fn writeJsonString(writer: *std.Io.Writer, text: []const u8) !void {
    try writer.writeByte('"');
    for (text) |c| switch (c) {
        '"' => try writer.writeAll("\\\""),
        '\\' => try writer.writeAll("\\\\"),
        '\n' => try writer.writeAll("\\n"),
        '\t' => try writer.writeAll("\\t"),
        '\r' => try writer.writeAll("\\r"),
        else => try writer.writeByte(c),
    };
    try writer.writeByte('"');
}

/// Write every operation in `registry` as a JSON array, sorted by name. The
/// `category` field is omitted for ops registered outside a named group.
pub fn serializeOperations(
    writer: *std.Io.Writer,
    registry: *const Registry,
    allocator: Allocator,
) !void {
    var entries: std.ArrayListUnmanaged(Entry) = .empty;
    defer entries.deinit(allocator);

    var it = registry.operations.iterator();
    while (it.next()) |op| {
        try entries.append(allocator, .{ .name = op.key_ptr.*, .op = op.value_ptr.* });
    }
    std.mem.sort(Entry, entries.items, {}, lessByName);

    try writer.writeAll("[\n");
    for (entries.items, 0..) |entry, i| {
        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, entry.name);
        if (entry.op.category) |category| {
            try writer.writeAll(", \"category\": ");
            try writeJsonString(writer, category);
        }
        try writer.writeAll(", \"signature\": ");
        try writeJsonString(writer, entry.op.signature);
        try writer.writeAll(", \"description\": ");
        try writeJsonString(writer, entry.op.description);
        try writer.writeAll(if (i + 1 < entries.items.len) " },\n" else " }\n");
    }
    try writer.writeAll("]\n");
}

/// Write every macro in `registry` as a JSON array, sorted by name. The
/// signature is derived from each macro's parameters (see `Macro.writeSignature`);
/// macros carry no description, so none is emitted.
pub fn serializeMacros(
    writer: *std.Io.Writer,
    registry: *const Registry,
    allocator: Allocator,
) !void {
    var entries: std.ArrayListUnmanaged(MacroEntry) = .empty;
    defer entries.deinit(allocator);

    var it = registry.macros.iterator();
    while (it.next()) |entry| {
        try entries.append(allocator, .{ .name = entry.key_ptr.*, .macro = entry.value_ptr.* });
    }
    std.mem.sort(MacroEntry, entries.items, {}, macroLessByName);

    var signature: std.Io.Writer.Allocating = .init(allocator);
    defer signature.deinit();

    try writer.writeAll("[\n");
    for (entries.items, 0..) |entry, i| {
        signature.clearRetainingCapacity();
        try entry.macro.writeSignature(&signature.writer);

        try writer.writeAll("    { \"name\": ");
        try writeJsonString(writer, entry.name);
        try writer.writeAll(", \"signature\": ");
        try writeJsonString(writer, signature.written());
        try writer.writeAll(if (i + 1 < entries.items.len) " },\n" else " }\n");
    }
    try writer.writeAll("]\n");
}
