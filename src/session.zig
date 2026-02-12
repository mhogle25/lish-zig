const std = @import("std");
const exec_mod = @import("exec.zig");
const process_mod = @import("process.zig");
const validation_mod = @import("validation.zig");

const Allocator = std.mem.Allocator;
const Registry = exec_mod.Registry;
const Env = exec_mod.Env;
const Scope = exec_mod.Scope;
const ExpressionCache = process_mod.ExpressionCache;
const ProcessResult = process_mod.ProcessResult;
const MacroLoadResult = process_mod.MacroLoadResult;
const MacroDirResult = process_mod.MacroDirResult;
const RegistryFragment = process_mod.RegistryFragment;
const ValidationError = validation_mod.ValidationError;

pub const SessionConfig = struct {
    fragments: []const RegistryFragment = &.{},
    macro_paths: []const []const u8 = &.{},
    expression_cache_capacity: usize = 256,
    stdout: std.io.AnyWriter = null_writer,
    stderr: std.io.AnyWriter = null_writer,
};

/// Create an AnyWriter that wraps a POSIX file descriptor.
pub fn fdWriter(fd: std.posix.fd_t) std.io.AnyWriter {
    return .{
        .context = @ptrFromInt(@as(usize, @intCast(fd))),
        .writeFn = &fdWriteFn,
    };
}

fn fdWriteFn(context: *const anyopaque, bytes: []const u8) anyerror!usize {
    const fd: std.posix.fd_t = @intCast(@intFromPtr(context));
    return std.posix.write(fd, bytes) catch |err| return err;
}

fn nullWriteFn(_: *const anyopaque, bytes: []const u8) anyerror!usize {
    return bytes.len;
}

const null_context: u8 = 0;

const null_writer: std.io.AnyWriter = .{
    .context = @ptrCast(&null_context),
    .writeFn = &nullWriteFn,
};

pub const Session = struct {
    registry: Registry,
    env: Env,
    expression_cache: ExpressionCache,
    arena: std.heap.ArenaAllocator,
    session_allocator: Allocator,

    pub fn init(allocator: Allocator, config: SessionConfig) !Session {
        var registry = Registry{};
        try process_mod.loadFragments(&registry, allocator, config.fragments);

        var expression_cache = try ExpressionCache.init(allocator, config.expression_cache_capacity);
        errdefer expression_cache.deinit();

        const arena = std.heap.ArenaAllocator.init(allocator);

        var session = Session{
            .registry = registry,
            .env = .{
                .registry = undefined, // set in execute() via self pointer
                .allocator = undefined, // set in execute() via self.arena
                .stdout = config.stdout,
                .stderr = config.stderr,
            },
            .expression_cache = expression_cache,
            .arena = arena,
            .session_allocator = allocator,
        };

        // Load macro files from configured paths
        for (config.macro_paths) |macro_path| {
            _ = try process_mod.loadMacroDir(allocator, &session.registry, macro_path);
        }

        return session;
    }

    pub fn deinit(self: *Session) void {
        self.expression_cache.deinit();
        self.arena.deinit();
        self.registry.deinit(self.session_allocator);
    }

    /// Execute a single line of input. This is the main entry point.
    /// Terminal REPL calls this in a loop. Raylib calls this from an event.
    ///
    /// The arena grows across executions because cached expressions hold
    /// pointers into arena memory. Call clearCache() + resetArena() to
    /// reclaim memory when appropriate.
    pub fn execute(self: *Session, input: []const u8) Allocator.Error!ProcessResult {
        self.prepareEnv();
        return process_mod.processRawCached(
            &self.env,
            &self.expression_cache,
            input,
            null,
        );
    }

    /// Execute with a provided scope.
    pub fn executeWithScope(self: *Session, input: []const u8, scope: *const Scope) Allocator.Error!ProcessResult {
        self.prepareEnv();
        return process_mod.processRawCached(
            &self.env,
            &self.expression_cache,
            input,
            scope,
        );
    }

    fn prepareEnv(self: *Session) void {
        self.env.registry = &self.registry;
        self.env.allocator = self.arena.allocator();
        self.env.runtime_error = null;
    }

    /// Load macro files from a directory.
    pub fn loadMacroDir(self: *Session, dir_path: []const u8) !MacroDirResult {
        return process_mod.loadMacroDir(self.session_allocator, &self.registry, dir_path);
    }

    /// Load a single macro file.
    pub fn loadMacroFile(self: *Session, file_path: []const u8) !MacroLoadResult {
        return process_mod.loadMacroFile(self.session_allocator, &self.registry, file_path);
    }

    /// Clear the expression cache.
    pub fn clearCache(self: *Session) void {
        self.expression_cache.clear();
    }

    /// Clear the cache and reset the arena to reclaim memory.
    /// Call this periodically in long-running sessions.
    pub fn resetArena(self: *Session) void {
        self.expression_cache.clear();
        _ = self.arena.reset(.retain_capacity);
    }
};

// -- Tests --

const builtins = @import("builtins.zig");

test "session: basic execute" {
    var session = try Session.init(std.testing.allocator, .{
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    const result = try session.execute("+ 1 2");
    switch (result) {
        .ok => |maybe_value| {
            try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int);
        },
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }
}

test "session: multiple executions reuse cache" {
    var session = try Session.init(std.testing.allocator, .{
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    // First execution — cache miss
    const result1 = try session.execute("+ 10 20");
    switch (result1) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 30), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }

    // Second execution — cache hit
    const result2 = try session.execute("+ 10 20");
    switch (result2) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 30), maybe_value.?.int),
        .validation_err => return error.TestUnexpectedResult,
        .runtime_err => return error.TestUnexpectedResult,
    }

    try std.testing.expectEqual(@as(usize, 1), session.expression_cache.count());
}

test "session: runtime error does not break subsequent executions" {
    var session = try Session.init(std.testing.allocator, .{
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    // Trigger a runtime error
    const bad_result = try session.execute("nonexistent 1 2");
    switch (bad_result) {
        .runtime_err => {},
        else => return error.TestUnexpectedResult,
    }

    // Should still work fine after error
    const good_result = try session.execute("+ 1 2");
    switch (good_result) {
        .ok => |maybe_value| try std.testing.expectEqual(@as(i64, 3), maybe_value.?.int),
        else => return error.TestUnexpectedResult,
    }
}

test "session: clear cache" {
    var session = try Session.init(std.testing.allocator, .{
        .fragments = &.{&builtins.registerAll},
    });
    defer session.deinit();

    _ = try session.execute("+ 1 2");
    try std.testing.expectEqual(@as(usize, 1), session.expression_cache.count());

    session.clearCache();
    try std.testing.expectEqual(@as(usize, 0), session.expression_cache.count());
}
