const std = @import("std");
const lish = @import("lish");
const line_editor_mod = @import("line_editor.zig");
const repl_mod = @import("repl.zig");

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

    var repl_config = repl_mod.ReplConfig.init(allocator);
    defer repl_config.deinit();
    repl_mod.loadConfig(&repl_config, allocator);

    var all_macro_dirs = std.ArrayListUnmanaged([]const u8){};
    defer all_macro_dirs.deinit(allocator);
    try all_macro_dirs.appendSlice(allocator, repl_config.macro_dirs.items);
    try all_macro_dirs.appendSlice(allocator, macro_dir_storage[0..macro_dir_count]);

    var session = try lish.Session.init(allocator, .{
        .fragments = &.{&lish.builtins.registerAll},
        .macro_paths = all_macro_dirs.items,
        .stdout = stdout,
        .stderr = stderr,
    });
    defer session.deinit();

    var editor = line_editor_mod.LineEditor.init(allocator, stdout);
    editor.autopair_insert = repl_config.autopair_insert;
    editor.autopair_delete = repl_config.autopair_delete;
    defer editor.deinit();

    repl_mod.runRepl(&session, &editor, stdout, stderr);
}
