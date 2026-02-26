const std = @import("std");
const lish = @import("lish");
const line_editor_mod = @import("line_editor.zig");

const Allocator = std.mem.Allocator;

// ── REPL config ──

const ReplConfig = struct {
    autopair_insert: bool = true,
    autopair_delete: bool = true,
};

fn autopairInsertOp(config: *ReplConfig, args: lish.Args) lish.exec.ExecError!?lish.Value {
    switch (args.count()) {
        0 => config.autopair_insert = true,
        1 => config.autopair_insert = (try args.at(0).get()) != null,
        else => return args.env.fail("autopair-insert takes 0 or 1 argument"),
    }
    return null;
}

fn autopairDeleteOp(config: *ReplConfig, args: lish.Args) lish.exec.ExecError!?lish.Value {
    switch (args.count()) {
        0 => config.autopair_delete = true,
        1 => config.autopair_delete = (try args.at(0).get()) != null,
        else => return args.env.fail("autopair-delete takes 0 or 1 argument"),
    }
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

fn loadConfig(config: *ReplConfig, allocator: Allocator) void {
    const path = configFilePath(allocator) orelse return;
    defer allocator.free(path);

    const source = std.fs.cwd().readFileAlloc(allocator, path, 64 * 1024) catch return;
    defer allocator.free(source);

    var registry = lish.Registry{};
    defer registry.deinit(allocator);
    lish.builtins.registerCore(&registry, allocator) catch return;
    registry.registerOperation(allocator, "autopair-insert", lish.Operation.fromBoundFn(ReplConfig, autopairInsertOp, config)) catch return;
    registry.registerOperation(allocator, "autopair-delete", lish.Operation.fromBoundFn(ReplConfig, autopairDeleteOp, config)) catch return;

    var env = lish.Env{ .registry = &registry, .allocator = allocator };

    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;
        _ = lish.processRaw(&env, trimmed, null) catch {};
    }
}

// ── Entry point ──

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = lish.session.fdWriter(std.posix.STDOUT_FILENO);
    const stderr = lish.session.fdWriter(std.posix.STDERR_FILENO);

    // Parse --macros/-m arguments
    var macro_dir_storage: [16][]const u8 = undefined;
    var macro_dir_count: usize = 0;
    const args = std.os.argv;
    var arg_idx: usize = 1;
    while (arg_idx < args.len) : (arg_idx += 1) {
        const arg = std.mem.span(args[arg_idx]);
        if (std.mem.eql(u8, arg, "--macros") or std.mem.eql(u8, arg, "-m")) {
            arg_idx += 1;
            if (arg_idx < args.len) {
                if (macro_dir_count >= macro_dir_storage.len) {
                    try stderr.print("Too many --macros arguments (max 16)\n", .{});
                    return;
                }
                macro_dir_storage[macro_dir_count] = std.mem.span(args[arg_idx]);
                macro_dir_count += 1;
            }
        }
    }

    var repl_config = ReplConfig{};
    loadConfig(&repl_config, allocator);

    var session = try lish.Session.init(allocator, .{
        .fragments = &.{&lish.builtins.registerAll},
        .macro_paths = macro_dir_storage[0..macro_dir_count],
        .stdout = stdout,
        .stderr = stderr,
    });
    defer session.deinit();

    var editor = line_editor_mod.LineEditor.init(allocator, stdout);
    editor.autopair_insert = repl_config.autopair_insert;
    editor.autopair_delete = repl_config.autopair_delete;
    defer editor.deinit();

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
