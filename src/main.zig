const std = @import("std");
const sh = @import("sh");
const line_editor_mod = @import("line_editor.zig");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const stdout = sh.session.fdWriter(std.posix.STDOUT_FILENO);
    const stderr = sh.session.fdWriter(std.posix.STDERR_FILENO);

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

    var session = try sh.Session.init(allocator, .{
        .fragments = &.{&sh.builtins.registerAll},
        .macro_paths = macro_dir_storage[0..macro_dir_count],
        .stdout = stdout,
        .stderr = stderr,
    });
    defer session.deinit();

    var editor = line_editor_mod.LineEditor.init(allocator, stdout);
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
