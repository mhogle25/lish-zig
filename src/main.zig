const std = @import("std");
const lish = @import("lish");
const line_editor_mod = lish.line_editor;
const repl_mod = lish.repl;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    var stdout_writer = std.Io.File.stdout().writer(io, &.{});
    var stderr_writer = std.Io.File.stderr().writer(io, &.{});
    const stdout = &stdout_writer.interface;
    const stderr = &stderr_writer.interface;

    // --dump-ops / --dump-macros: serialize the full default registry to stdout
    // and exit. This is the canonical, reproducible source of the op/macro
    // vocabulary (nothing is committed to disk); a custom host that builds its
    // own registry can offer the same flag to expose its vocabulary to editor
    // tooling.
    {
        var probe = init.minimal.args.iterate();
        _ = probe.next(); // skip argv[0]
        while (probe.next()) |arg| {
            const dump_ops = std.mem.eql(u8, arg, "--dump-ops");
            const dump_macros = std.mem.eql(u8, arg, "--dump-macros");
            if (dump_ops or dump_macros) {
                var registry = lish.Registry.init(allocator);
                defer registry.deinit(allocator);
                try lish.builtins.registerAll(&registry, allocator);
                try lish.random.registerAll(&registry, allocator);
                if (dump_ops)
                    try lish.introspect.serializeOperations(stdout, &registry, allocator)
                else
                    try lish.introspect.serializeMacros(stdout, &registry, allocator);
                return;
            }
        }
    }

    // Parse --macros/-m arguments
    var macro_dir_storage: [16][]const u8 = undefined;
    var macro_dir_count: usize = 0;
    var arg_iter = init.minimal.args.iterate();
    _ = arg_iter.next(); // skip argv[0]
                         
    while (arg_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--macros") or std.mem.eql(u8, arg, "-m")) {
            const path = arg_iter.next() orelse break;
            if (macro_dir_count >= macro_dir_storage.len) {
                try stderr.print("Too many --macros arguments (max 16)\n", .{});
                return;
            }
            macro_dir_storage[macro_dir_count] = path;
            macro_dir_count += 1;
        }
    }

    var repl_config = repl_mod.ReplConfig.init(allocator);
    defer repl_config.deinit();
    repl_mod.loadConfig(io, init.minimal.environ, &repl_config, allocator);

    var all_macro_dirs = std.ArrayListUnmanaged([]const u8).empty;
    defer all_macro_dirs.deinit(allocator);
    try all_macro_dirs.appendSlice(allocator, repl_config.macro_dirs.items);
    try all_macro_dirs.appendSlice(allocator, macro_dir_storage[0..macro_dir_count]);

    var session = try lish.Session.init(allocator, .{
        .io = io,
        .fragments = &.{ &lish.builtins.registerAll, &lish.random.registerAll },
        .macro_paths = all_macro_dirs.items,
        .stdout = stdout,
        .stderr = stderr,
        .bounds = repl_config.bounds,
    });
    defer session.deinit();

    _ = try lish.loadStdlib(&session.registry);

    var editor = line_editor_mod.LineEditor.init(allocator, stdout);
    editor.autopair_insert = repl_config.autopair_insert;
    editor.autopair_delete = repl_config.autopair_delete;
    editor.bracket_expand = repl_config.bracket_expand;
    editor.renderer.highlight_enabled = repl_config.highlight;
    defer editor.deinit();

    repl_mod.runRepl(&session, &editor, stdout, stderr);
}
