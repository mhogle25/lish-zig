const std = @import("std");
const exec_mod = @import("exec.zig");
const value_mod = @import("value.zig");
const builtins_mod = @import("builtins.zig");
const process_mod = @import("process.zig");
const session_mod = @import("session.zig");
const line_editor_mod = @import("line_editor.zig");

const Allocator = std.mem.Allocator;
const LineEditor = line_editor_mod.LineEditor;

const op_autopair_insert = "autopair-insert";
const op_autopair_delete = "autopair-delete";

/// Wraps a writer to append a newline after each write. Used for session stdout
/// so ops like `say` can write raw strings without caring about newlines.
pub const NewlineWriter = struct {
    inner: std.io.AnyWriter,

    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *const NewlineWriter = @ptrCast(@alignCast(context));
        try self.inner.writeAll(bytes);
        try self.inner.writeByte('\n');
        return bytes.len;
    }

    pub fn any(self: *const NewlineWriter) std.io.AnyWriter {
        return .{ .context = self, .writeFn = writeFn };
    }
};

/// Wraps a writer to wrap each write in ANSI red and append a newline.
/// Used for session stderr so ops like `error` get colored output in the REPL.
pub const AnsiErrorWriter = struct {
    inner: std.io.AnyWriter,

    fn writeFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
        const self: *const AnsiErrorWriter = @ptrCast(@alignCast(context));
        try self.inner.writeAll("\x1b[31m");
        try self.inner.writeAll(bytes);
        try self.inner.writeAll("\x1b[0m\n");
        return bytes.len;
    }

    pub fn any(self: *const AnsiErrorWriter) std.io.AnyWriter {
        return .{ .context = self, .writeFn = writeFn };
    }
};

pub const ReplConfig = struct {
    autopair_insert: bool = true,
    autopair_delete: bool = true,
    macro_dirs: std.ArrayListUnmanaged([]const u8) = .{},
    allocator: Allocator,

    pub fn init(allocator: Allocator) ReplConfig {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *ReplConfig) void {
        for (self.macro_dirs.items) |path| self.allocator.free(path);
        self.macro_dirs.deinit(self.allocator);
    }
};

fn autopairInsertOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.autopair_insert = true,
        1 => config.autopair_insert = (try args.at(0).get()) != null,
        else => return args.env.fail(op_autopair_insert ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn autopairDeleteOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    switch (args.count()) {
        0 => config.autopair_delete = true,
        1 => config.autopair_delete = (try args.at(0).get()) != null,
        else => return args.env.fail(op_autopair_delete ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn macrosOp(config: *ReplConfig, args: exec_mod.Args) exec_mod.ExecError!?value_mod.Value {
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try (try args.single()).resolveString(&path_buf);
    const owned = config.allocator.dupe(u8, path) catch return error.OutOfMemory;
    config.macro_dirs.append(config.allocator, owned) catch {
        config.allocator.free(owned);
        return error.OutOfMemory;
    };
    return null;
}

fn configFilePath(allocator: Allocator) ?[]const u8 {
    if (std.posix.getenv("XDG_CONFIG_HOME")) |xdg| {
        return std.fs.path.join(allocator, &.{ xdg, "lish", "config" }) catch null;
    }
    if (std.posix.getenv("HOME")) |home| {
        return std.fs.path.join(allocator, &.{ home, ".config", "lish", "config" }) catch null;
    }
    return null;
}

pub fn loadConfig(config: *ReplConfig, allocator: Allocator) void {
    const path = configFilePath(allocator) orelse return;
    defer allocator.free(path);

    const source = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return;
    defer allocator.free(source);

    var registry = exec_mod.Registry.init(allocator);
    defer registry.deinit(allocator);
    builtins_mod.registerCore(&registry, allocator) catch return;
    registry.registerOperation(allocator, op_autopair_insert, exec_mod.Operation.fromBoundFn(ReplConfig, autopairInsertOp, config)) catch return;
    registry.registerOperation(allocator, op_autopair_delete, exec_mod.Operation.fromBoundFn(ReplConfig, autopairDeleteOp, config)) catch return;
    registry.registerOperation(allocator, "macros", exec_mod.Operation.fromBoundFn(ReplConfig, macrosOp, config)) catch return;

    const config_macros =
        \\|on| $some
        \\|off| $none
    ;
    _ = process_mod.loadMacroModule(&registry, config_macros) catch return;

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return;

    var env = exec_mod.Env{ .registry = &registry, .allocator = allocator };
    _ = process_mod.processRaw(&env, trimmed, null) catch {};
}

pub fn runRepl(
    session: *session_mod.Session,
    editor: *LineEditor,
    stdout: std.io.AnyWriter,
    stderr: std.io.AnyWriter,
) void {
    while (true) {
        switch (editor.readLine()) {
            .eof => break,
            .line => |line| {
                const trimmed = std.mem.trim(u8, line, " \t\r");
                if (trimmed.len == 0) continue;

                if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
                    break;
                }

                if (std.mem.eql(u8, trimmed, "clear")) {
                    stdout.print("\x1b[2J\x1b[H", .{}) catch {};
                    continue;
                }

                const result = session.execute(trimmed) catch |err| {
                    stderr.print("Error: {}\n", .{err}) catch {};
                    continue;
                };

                switch (result) {
                    .ok => |maybe_value| {
                        if (maybe_value) |value| {
                            switch (value) {
                                .string => |str| stdout.print("\x1b[2m=> \"{s}\"\x1b[0m\n", .{str}) catch {},
                                else => {
                                    stdout.writeAll("\x1b[2m=> ") catch {};
                                    value.writeTo(stdout) catch {};
                                    stdout.writeAll("\x1b[0m\n") catch {};
                                },
                            }
                        }
                    },
                    .validation_err => |errors| {
                        for (errors) |validation_error| {
                            stderr.print("\x1b[31mValidation error: {s}\x1b[0m\n", .{validation_error.message}) catch {};
                        }
                    },
                    .runtime_err => |message| {
                        stderr.print("\x1b[31mRuntime error: {s}\x1b[0m\n", .{message}) catch {};
                    },
                }
            },
        }
    }
}
