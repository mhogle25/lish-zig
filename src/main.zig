const std = @import("std");
const sh = @import("sh");

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

    var line_buf: [4096]u8 = undefined;

    while (true) {
        stdout.print("sh> ", .{}) catch break;

        const line = readLine(&line_buf) orelse break;
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len == 0) continue;

        if (std.mem.eql(u8, trimmed, "exit") or std.mem.eql(u8, trimmed, "quit")) {
            break;
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
    }
}

/// Read a line from stdin up to newline or EOF. Returns null on EOF with no data.
fn readLine(buf: []u8) ?[]const u8 {
    var pos: usize = 0;
    while (pos < buf.len) {
        const bytes_read = std.posix.read(std.posix.STDIN_FILENO, buf[pos..][0..1]) catch return null;
        if (bytes_read == 0) {
            // EOF
            return if (pos > 0) buf[0..pos] else null;
        }
        if (buf[pos] == '\n') {
            return buf[0..pos];
        }
        pos += 1;
    }
    // Line too long — return what we have
    return buf[0..pos];
}
