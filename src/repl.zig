const std = @import("std");
const lish = @import("lish");
const line_editor_mod = @import("line_editor.zig");

const Allocator = std.mem.Allocator;
const LineEditor = line_editor_mod.LineEditor;

const op_autopair_insert = "autopair-insert";
const op_autopair_delete = "autopair-delete";

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

fn autopairInsertOp(config: *ReplConfig, args: lish.Args) lish.exec.ExecError!?lish.Value {
    switch (args.count()) {
        0 => config.autopair_insert = true,
        1 => config.autopair_insert = (try args.at(0).get()) != null,
        else => return args.env.fail(op_autopair_insert ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn autopairDeleteOp(config: *ReplConfig, args: lish.Args) lish.exec.ExecError!?lish.Value {
    switch (args.count()) {
        0 => config.autopair_delete = true,
        1 => config.autopair_delete = (try args.at(0).get()) != null,
        else => return args.env.fail(op_autopair_delete ++ " takes 0 or 1 argument"),
    }
    return null;
}

fn macrosOp(config: *ReplConfig, args: lish.Args) lish.exec.ExecError!?lish.Value {
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

    var registry = lish.Registry{};
    defer registry.deinit(allocator);
    lish.builtins.registerCore(&registry, allocator) catch return;
    registry.registerOperation(allocator, op_autopair_insert, lish.Operation.fromBoundFn(ReplConfig, autopairInsertOp, config)) catch return;
    registry.registerOperation(allocator, op_autopair_delete, lish.Operation.fromBoundFn(ReplConfig, autopairDeleteOp, config)) catch return;
    registry.registerOperation(allocator, "macros", lish.Operation.fromBoundFn(ReplConfig, macrosOp, config)) catch return;

    const config_macros =
        \\|on| $some
        \\|off| $none
    ;
    _ = lish.loadMacroModule(allocator, &registry, config_macros) catch return;

    const trimmed = std.mem.trim(u8, source, " \t\r\n");
    if (trimmed.len == 0) return;

    var env = lish.Env{ .registry = &registry, .allocator = allocator };
    _ = lish.processRaw(&env, trimmed, null) catch {};
}

pub fn runRepl(
    session: *lish.Session,
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
                            var format_buf: [1024]u8 = undefined;
                            const formatted = value.getS(&format_buf);
                            stdout.print("{s}\n", .{formatted}) catch {};
                        } else {
                            stdout.print("none\n", .{}) catch {};
                        }
                    },
                    .validation_err => |errors| {
                        for (errors) |validation_error| {
                            stderr.print("Validation error: {s}\n", .{validation_error.message}) catch {};
                        }
                    },
                    .runtime_err => |message| {
                        stderr.print("Runtime error: {s}\n", .{message}) catch {};
                    },
                }
            },
        }
    }
}
