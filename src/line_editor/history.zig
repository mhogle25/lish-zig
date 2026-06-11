const std = @import("std");
const buffer_mod = @import("buffer.zig");

const Allocator = std.mem.Allocator;
const LineBuffer = buffer_mod.LineBuffer;
const BUFFER_SIZE = buffer_mod.BUFFER_SIZE;

pub const MAX_ENTRIES = 256;

/// Ring buffer of past input lines plus browse state. Methods that change the
/// current input take a `*LineBuffer` so History stays decoupled from the
/// editor's orchestration role.
pub const History = struct {
    entries: [MAX_ENTRIES]?[]const u8 = [_]?[]const u8{null} ** MAX_ENTRIES,
    count: usize = 0,
    write_index: usize = 0,
    /// When browsing, index into `entries` of the currently-displayed entry.
    /// Null means not browsing.
    browse_index: ?usize = null,

    /// Backup of the in-progress buffer captured when browsing starts so that
    /// stepping past the newest entry restores what the user was typing.
    saved_buffer: [BUFFER_SIZE]u8 = undefined,
    saved_length: usize = 0,

    allocator: Allocator,

    pub fn init(allocator: Allocator) History {
        return .{ .allocator = allocator };
    }

    pub fn deinit(self: *History) void {
        for (&self.entries) |*entry| {
            if (entry.*) |slice| {
                self.allocator.free(slice);
                entry.* = null;
            }
        }
        self.count = 0;
        self.write_index = 0;
    }

    /// Append a line to history, skipping consecutive duplicates. Silently
    /// drops the entry on allocation failure.
    pub fn add(self: *History, line: []const u8) void {
        if (self.count > 0) {
            const last_index = if (self.write_index == 0) MAX_ENTRIES - 1 else self.write_index - 1;
            if (self.entries[last_index]) |last_entry| {
                if (std.mem.eql(u8, last_entry, line)) return;
            }
        }

        if (self.entries[self.write_index]) |old_entry| {
            self.allocator.free(old_entry);
        }

        const copy = self.allocator.dupe(u8, line) catch return;
        self.entries[self.write_index] = copy;
        self.write_index = (self.write_index + 1) % MAX_ENTRIES;
        if (self.count < MAX_ENTRIES) self.count += 1;
    }

    /// Move to the previous (older) history entry. On first call captures
    /// the current buffer contents so `down` can restore them later.
    pub fn up(self: *History, buffer: *LineBuffer) void {
        if (self.count == 0) return;

        if (self.browse_index == null) {
            @memcpy(self.saved_buffer[0..buffer.length], buffer.data[0..buffer.length]);
            self.saved_length = buffer.length;

            self.browse_index = if (self.write_index == 0) MAX_ENTRIES - 1 else self.write_index - 1;
        } else {
            const oldest_index = if (self.count < MAX_ENTRIES) 0 else self.write_index;
            if (self.browse_index.? == oldest_index) return;

            self.browse_index = if (self.browse_index.? == 0) MAX_ENTRIES - 1 else self.browse_index.? - 1;
        }

        self.loadEntry(self.browse_index.?, buffer);
    }

    /// Move to the next (newer) history entry. Past the newest entry restores
    /// the buffer that was saved when browsing started.
    pub fn down(self: *History, buffer: *LineBuffer) void {
        if (self.browse_index == null) return;

        const newest_index = if (self.write_index == 0) MAX_ENTRIES - 1 else self.write_index - 1;

        if (self.browse_index.? == newest_index) {
            self.browse_index = null;
            @memcpy(buffer.data[0..self.saved_length], self.saved_buffer[0..self.saved_length]);
            buffer.length = self.saved_length;
            buffer.cursor = buffer.length;
            return;
        }

        self.browse_index = (self.browse_index.? + 1) % MAX_ENTRIES;
        self.loadEntry(self.browse_index.?, buffer);
    }

    /// Reset browse state without clearing entries. Used at the start of a
    /// fresh input cycle.
    pub fn endBrowse(self: *History) void {
        self.browse_index = null;
    }

    fn loadEntry(self: *History, index: usize, buffer: *LineBuffer) void {
        if (self.entries[index]) |entry| {
            const copy_len = @min(entry.len, BUFFER_SIZE);
            @memcpy(buffer.data[0..copy_len], entry[0..copy_len]);
            buffer.length = copy_len;
            buffer.cursor = copy_len;
        }
    }
};


fn testInsertString(buffer: *LineBuffer, string: []const u8) void {
    for (string) |byte| {
        _ = buffer.insertChar(byte);
    }
}

test "history: add and navigate" {
    var buffer = LineBuffer{};
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    history.add("first");
    history.add("second");
    history.add("third");

    try std.testing.expectEqual(@as(usize, 3), history.count);

    history.up(&buffer);
    try std.testing.expectEqualStrings("third", buffer.slice());

    history.up(&buffer);
    try std.testing.expectEqualStrings("second", buffer.slice());

    history.up(&buffer);
    try std.testing.expectEqualStrings("first", buffer.slice());

    history.down(&buffer);
    try std.testing.expectEqualStrings("second", buffer.slice());

    history.down(&buffer);
    try std.testing.expectEqualStrings("third", buffer.slice());

    history.down(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}

test "history: skip duplicates" {
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    history.add("hello");
    history.add("hello");
    history.add("hello");

    try std.testing.expectEqual(@as(usize, 1), history.count);
}

test "history: saves current line when browsing" {
    var buffer = LineBuffer{};
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    history.add("old command");
    testInsertString(&buffer, "in progress");

    history.up(&buffer);
    try std.testing.expectEqualStrings("old command", buffer.slice());

    history.down(&buffer);
    try std.testing.expectEqualStrings("in progress", buffer.slice());
}

test "history: ring buffer wrapping" {
    var buffer = LineBuffer{};
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    for (0..MAX_ENTRIES + 10) |idx| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "cmd {d}", .{idx}) catch continue;
        history.add(num_str);
    }

    try std.testing.expectEqual(@as(usize, MAX_ENTRIES), history.count);

    history.up(&buffer);
    try std.testing.expectEqualStrings("cmd 265", buffer.slice());
}

test "history: up on empty history does nothing" {
    var buffer = LineBuffer{};
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    history.up(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}

test "history: down without browsing does nothing" {
    var buffer = LineBuffer{};
    var history = History.init(std.testing.allocator);
    defer history.deinit();

    history.add("something");
    history.down(&buffer);
    try std.testing.expectEqualStrings("", buffer.slice());
    try std.testing.expect(history.browse_index == null);
}
