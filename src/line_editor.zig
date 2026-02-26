const std = @import("std");
const posix = std.posix;

const Allocator = std.mem.Allocator;

const BUFFER_SIZE = 4096;
const MAX_HISTORY = 256;
const PROMPT = "lish> ";

pub const ReadLineResult = union(enum) {
    line: []const u8,
    eof,
};

const EscapeState = enum {
    ground,
    escape,
    csi,
    csi_param,
};

const EscapeAction = enum {
    none,
    move_up,
    move_down,
    move_right,
    move_left,
    home,
    end,
    delete_forward,
};

/// Module-level storage so the SIGINT handler can restore the terminal.
var global_original_termios: ?posix.termios = null;
var signal_handler_installed: bool = false;

fn sigintHandler(_: c_int) callconv(.c) void {
    if (global_original_termios) |original| {
        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
    }
    // Exit with 128 + SIGINT (2) = 130
    std.process.exit(130);
}

pub const LineEditor = struct {
    line_buffer: [BUFFER_SIZE]u8 = undefined,
    line_length: usize = 0,
    cursor_position: usize = 0,

    original_termios: ?posix.termios = null,
    raw_mode_active: bool = false,
    is_terminal: bool = true,

    history_entries: [MAX_HISTORY]?[]const u8 = [_]?[]const u8{null} ** MAX_HISTORY,
    history_count: usize = 0,
    history_write_index: usize = 0,
    history_browse_index: ?usize = null,

    saved_line_buffer: [BUFFER_SIZE]u8 = undefined,
    saved_line_length: usize = 0,

    escape_state: EscapeState = .ground,
    csi_param: u16 = 0,

    stdout: std.io.AnyWriter,
    allocator: Allocator,

    pub fn init(allocator: Allocator, stdout: std.io.AnyWriter) LineEditor {
        return .{
            .allocator = allocator,
            .stdout = stdout,
        };
    }

    pub fn deinit(self: *LineEditor) void {
        self.disableRawMode();
        for (&self.history_entries) |*entry| {
            if (entry.*) |slice| {
                self.allocator.free(slice);
                entry.* = null;
            }
        }
        self.history_count = 0;
        self.history_write_index = 0;
    }

    fn enableRawMode(self: *LineEditor) void {
        if (self.raw_mode_active or !self.is_terminal) return;

        const original = posix.tcgetattr(posix.STDIN_FILENO) catch |err| {
            if (err == error.NotATerminal) {
                self.is_terminal = false;
            }
            return;
        };

        self.original_termios = original;
        global_original_termios = original;

        if (!signal_handler_installed) {
            const act = posix.Sigaction{
                .handler = .{ .handler = &sigintHandler },
                .mask = posix.sigemptyset(),
                .flags = 0,
            };
            posix.sigaction(posix.SIG.INT, &act, null);
            signal_handler_installed = true;
        }

        var raw = original;

        // Input flags: disable CR->NL, XON/XOFF flow control
        raw.iflag.ICRNL = false;
        raw.iflag.IXON = false;

        // Output flags: disable post-processing
        raw.oflag.OPOST = false;

        // Local flags: disable echo, canonical mode, signals, extended input
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.ISIG = false;
        raw.lflag.IEXTEN = false;

        // Read returns after 1 byte, no timeout
        raw.cc[@intFromEnum(posix.V.MIN)] = 1;
        raw.cc[@intFromEnum(posix.V.TIME)] = 0;

        posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, raw) catch return;
        self.raw_mode_active = true;
    }

    fn disableRawMode(self: *LineEditor) void {
        if (!self.raw_mode_active) return;
        if (self.original_termios) |original| {
            posix.tcsetattr(posix.STDIN_FILENO, .FLUSH, original) catch {};
        }
        self.raw_mode_active = false;
    }

    pub fn readLine(self: *LineEditor) ReadLineResult {
        self.line_length = 0;
        self.cursor_position = 0;
        self.escape_state = .ground;
        self.history_browse_index = null;

        self.enableRawMode();

        if (!self.is_terminal) {
            return self.readLineFallback();
        }

        // Write prompt
        self.stdout.writeAll(PROMPT) catch {};

        while (true) {
            var byte_buf: [1]u8 = undefined;
            const bytes_read = posix.read(posix.STDIN_FILENO, &byte_buf) catch {
                self.disableRawMode();
                return .eof;
            };

            if (bytes_read == 0) {
                self.disableRawMode();
                return .eof;
            }

            const byte = byte_buf[0];

            switch (self.processInput(byte)) {
                .continue_reading => continue,
                .submit_line => {
                    // Write the newline
                    self.stdout.writeAll("\r\n") catch {};
                    self.disableRawMode();

                    const line = self.line_buffer[0..self.line_length];
                    const trimmed = std.mem.trim(u8, line, " \t\r");
                    if (trimmed.len > 0) {
                        self.addHistoryEntry(trimmed);
                    }
                    return .{ .line = line };
                },
                .cancel_line => {
                    self.stdout.writeAll("^C\r\n") catch {};
                    self.line_length = 0;
                    self.cursor_position = 0;
                    self.history_browse_index = null;
                    // Redraw prompt on new line
                    self.stdout.writeAll(PROMPT) catch {};
                },
                .eof_signal => {
                    if (self.line_length == 0) {
                        self.stdout.writeAll("\r\n") catch {};
                        self.disableRawMode();
                        return .eof;
                    }
                    // Non-empty line: delete forward
                    self.deleteForward();
                },
            }
        }
    }

    /// Fallback for piped/non-terminal input — reads line byte-by-byte in cooked mode.
    fn readLineFallback(self: *LineEditor) ReadLineResult {
        var pos: usize = 0;
        while (pos < self.line_buffer.len) {
            const bytes_read = posix.read(posix.STDIN_FILENO, self.line_buffer[pos..][0..1]) catch return .eof;
            if (bytes_read == 0) {
                return if (pos > 0) .{ .line = self.line_buffer[0..pos] } else .eof;
            }
            if (self.line_buffer[pos] == '\n') {
                return .{ .line = self.line_buffer[0..pos] };
            }
            pos += 1;
        }
        return .{ .line = self.line_buffer[0..pos] };
    }

    const InputResult = enum {
        continue_reading,
        submit_line,
        cancel_line,
        eof_signal,
    };

    fn processInput(self: *LineEditor, byte: u8) InputResult {
        // Run through escape sequence state machine first
        const action = self.processEscape(byte);
        if (action != .none) {
            self.handleEscapeAction(action);
            return .continue_reading;
        }

        // If we're in the middle of an escape sequence, don't process as regular input
        if (self.escape_state != .ground) return .continue_reading;

        switch (byte) {
            '\r', '\n' => return .submit_line,
            0x03 => return .cancel_line, // Ctrl+C
            0x04 => return .eof_signal, // Ctrl+D
            0x01 => { // Ctrl+A — beginning of line
                self.moveCursorToBeginning();
                return .continue_reading;
            },
            0x05 => { // Ctrl+E — end of line
                self.moveCursorToEnd();
                return .continue_reading;
            },
            0x0b => { // Ctrl+K — kill to end of line
                self.killToEnd();
                return .continue_reading;
            },
            0x15 => { // Ctrl+U — kill whole line
                self.killLine();
                return .continue_reading;
            },
            0x17 => { // Ctrl+W — delete word backward
                self.deleteWordBackward();
                return .continue_reading;
            },
            0x0c => { // Ctrl+L — clear screen
                self.stdout.writeAll("\x1b[2J\x1b[H") catch {};
                self.refreshLine();
                return .continue_reading;
            },
            0x7f => { // DEL — backspace on macOS
                self.deleteBackward();
                return .continue_reading;
            },
            0x08 => { // BS — backspace on some terminals
                self.deleteBackward();
                return .continue_reading;
            },
            '(' => {
                self.insertPair('(', ')');
                return .continue_reading;
            },
            '[' => {
                self.insertPair('[', ']');
                return .continue_reading;
            },
            '{' => {
                self.insertPair('{', '}');
                return .continue_reading;
            },
            else => {
                if (byte >= 0x20 and byte < 0x7f) {
                    self.insertCharacter(byte);
                }
                // Ignore other control characters
                return .continue_reading;
            },
        }
    }

    fn processEscape(self: *LineEditor, byte: u8) EscapeAction {
        switch (self.escape_state) {
            .ground => {
                if (byte == 0x1b) {
                    self.escape_state = .escape;
                    self.csi_param = 0;
                    return .none;
                }
                return .none;
            },
            .escape => {
                if (byte == '[') {
                    self.escape_state = .csi;
                    return .none;
                }
                // Not a CSI sequence — go back to ground
                self.escape_state = .ground;
                return .none;
            },
            .csi => {
                switch (byte) {
                    'A' => {
                        self.escape_state = .ground;
                        return .move_up;
                    },
                    'B' => {
                        self.escape_state = .ground;
                        return .move_down;
                    },
                    'C' => {
                        self.escape_state = .ground;
                        return .move_right;
                    },
                    'D' => {
                        self.escape_state = .ground;
                        return .move_left;
                    },
                    'H' => {
                        self.escape_state = .ground;
                        return .home;
                    },
                    'F' => {
                        self.escape_state = .ground;
                        return .end;
                    },
                    '0'...'9' => {
                        self.csi_param = byte - '0';
                        self.escape_state = .csi_param;
                        return .none;
                    },
                    else => {
                        self.escape_state = .ground;
                        return .none;
                    },
                }
            },
            .csi_param => {
                switch (byte) {
                    '0'...'9' => {
                        self.csi_param = self.csi_param *| 10 +| (byte - '0');
                        return .none;
                    },
                    '~' => {
                        self.escape_state = .ground;
                        if (self.csi_param == 3) return .delete_forward;
                        return .none;
                    },
                    else => {
                        self.escape_state = .ground;
                        return .none;
                    },
                }
            },
        }
    }

    fn handleEscapeAction(self: *LineEditor, action: EscapeAction) void {
        switch (action) {
            .none => {},
            .move_up => self.historyUp(),
            .move_down => self.historyDown(),
            .move_right => self.moveCursorRight(),
            .move_left => self.moveCursorLeft(),
            .home => self.moveCursorToBeginning(),
            .end => self.moveCursorToEnd(),
            .delete_forward => self.deleteForward(),
        }
    }

    // -- Line editing operations --

    fn insertPair(self: *LineEditor, open: u8, close: u8) void {
        if (self.line_length + 2 > BUFFER_SIZE) {
            self.insertCharacter(open);
            return;
        }
        self.insertCharacter(open);
        self.insertCharacter(close);
        self.moveCursorLeft();
    }

    fn insertCharacter(self: *LineEditor, byte: u8) void {
        if (self.line_length >= BUFFER_SIZE) return;

        if (self.cursor_position < self.line_length) {
            // Shift bytes right to make room
            std.mem.copyBackwards(
                u8,
                self.line_buffer[self.cursor_position + 1 .. self.line_length + 1],
                self.line_buffer[self.cursor_position .. self.line_length],
            );
        }

        self.line_buffer[self.cursor_position] = byte;
        self.cursor_position += 1;
        self.line_length += 1;
        self.refreshLine();
    }

    fn deleteBackward(self: *LineEditor) void {
        if (self.cursor_position == 0) return;

        if (self.cursor_position < self.line_length) {
            std.mem.copyForwards(
                u8,
                self.line_buffer[self.cursor_position - 1 .. self.line_length - 1],
                self.line_buffer[self.cursor_position .. self.line_length],
            );
        }

        self.cursor_position -= 1;
        self.line_length -= 1;
        self.refreshLine();
    }

    fn deleteForward(self: *LineEditor) void {
        if (self.cursor_position >= self.line_length) return;

        if (self.cursor_position + 1 < self.line_length) {
            std.mem.copyForwards(
                u8,
                self.line_buffer[self.cursor_position .. self.line_length - 1],
                self.line_buffer[self.cursor_position + 1 .. self.line_length],
            );
        }

        self.line_length -= 1;
        self.refreshLine();
    }

    fn moveCursorLeft(self: *LineEditor) void {
        if (self.cursor_position == 0) return;
        self.cursor_position -= 1;
        self.refreshLine();
    }

    fn moveCursorRight(self: *LineEditor) void {
        if (self.cursor_position >= self.line_length) return;
        self.cursor_position += 1;
        self.refreshLine();
    }

    fn moveCursorToBeginning(self: *LineEditor) void {
        if (self.cursor_position == 0) return;
        self.cursor_position = 0;
        self.refreshLine();
    }

    fn moveCursorToEnd(self: *LineEditor) void {
        if (self.cursor_position == self.line_length) return;
        self.cursor_position = self.line_length;
        self.refreshLine();
    }

    fn killLine(self: *LineEditor) void {
        if (self.line_length == 0) return;
        self.line_length = 0;
        self.cursor_position = 0;
        self.refreshLine();
    }

    fn killToEnd(self: *LineEditor) void {
        if (self.cursor_position == self.line_length) return;
        self.line_length = self.cursor_position;
        self.refreshLine();
    }

    fn deleteWordBackward(self: *LineEditor) void {
        if (self.cursor_position == 0) return;

        var target = self.cursor_position;

        // Skip whitespace backward
        while (target > 0 and self.line_buffer[target - 1] == ' ') {
            target -= 1;
        }

        // Skip word characters backward
        while (target > 0 and self.line_buffer[target - 1] != ' ') {
            target -= 1;
        }

        const chars_deleted = self.cursor_position - target;
        if (chars_deleted == 0) return;

        // Shift remaining content left
        if (self.cursor_position < self.line_length) {
            std.mem.copyForwards(
                u8,
                self.line_buffer[target .. self.line_length - chars_deleted],
                self.line_buffer[self.cursor_position .. self.line_length],
            );
        }

        self.line_length -= chars_deleted;
        self.cursor_position = target;
        self.refreshLine();
    }

    // -- Terminal refresh --

    fn refreshLine(self: *LineEditor) void {
        var refresh_buf: [BUFFER_SIZE + 128]u8 = undefined;
        var stream = std.io.fixedBufferStream(&refresh_buf);
        const writer = stream.writer();

        // Carriage return to column 0
        writer.writeAll("\r") catch return;
        // Write prompt
        writer.writeAll(PROMPT) catch return;
        // Write current line content
        writer.writeAll(self.line_buffer[0..self.line_length]) catch return;
        // Erase to end of line (clears leftover chars)
        writer.writeAll("\x1b[K") catch return;

        // Move cursor back to correct position
        const chars_after_cursor = self.line_length - self.cursor_position;
        if (chars_after_cursor > 0) {
            std.fmt.format(writer, "\x1b[{d}D", .{chars_after_cursor}) catch return;
        }

        self.stdout.writeAll(stream.getWritten()) catch {};
    }

    // -- History --

    fn addHistoryEntry(self: *LineEditor, line: []const u8) void {
        // Skip duplicates of most recent entry
        if (self.history_count > 0) {
            const last_index = if (self.history_write_index == 0) MAX_HISTORY - 1 else self.history_write_index - 1;
            if (self.history_entries[last_index]) |last_entry| {
                if (std.mem.eql(u8, last_entry, line)) return;
            }
        }

        // Free existing entry at write position if ring buffer wrapped
        if (self.history_entries[self.history_write_index]) |old_entry| {
            self.allocator.free(old_entry);
        }

        const copy = self.allocator.dupe(u8, line) catch return;
        self.history_entries[self.history_write_index] = copy;
        self.history_write_index = (self.history_write_index + 1) % MAX_HISTORY;
        if (self.history_count < MAX_HISTORY) {
            self.history_count += 1;
        }
    }

    fn historyUp(self: *LineEditor) void {
        if (self.history_count == 0) return;

        if (self.history_browse_index == null) {
            // First press — save current line and start browsing from most recent
            @memcpy(self.saved_line_buffer[0..self.line_length], self.line_buffer[0..self.line_length]);
            self.saved_line_length = self.line_length;

            self.history_browse_index = if (self.history_write_index == 0) MAX_HISTORY - 1 else self.history_write_index - 1;
        } else {
            // Already browsing — move to previous entry
            const oldest_index = if (self.history_count < MAX_HISTORY) 0 else self.history_write_index;
            if (self.history_browse_index.? == oldest_index) return; // At oldest entry

            self.history_browse_index = if (self.history_browse_index.? == 0) MAX_HISTORY - 1 else self.history_browse_index.? - 1;
        }

        self.loadHistoryEntry(self.history_browse_index.?);
    }

    fn historyDown(self: *LineEditor) void {
        if (self.history_browse_index == null) return;

        const newest_index = if (self.history_write_index == 0) MAX_HISTORY - 1 else self.history_write_index - 1;

        if (self.history_browse_index.? == newest_index) {
            // Past newest — restore saved line
            self.history_browse_index = null;
            @memcpy(self.line_buffer[0..self.saved_line_length], self.saved_line_buffer[0..self.saved_line_length]);
            self.line_length = self.saved_line_length;
            self.cursor_position = self.line_length;
            self.refreshLine();
            return;
        }

        self.history_browse_index = (self.history_browse_index.? + 1) % MAX_HISTORY;
        self.loadHistoryEntry(self.history_browse_index.?);
    }

    fn loadHistoryEntry(self: *LineEditor, index: usize) void {
        if (self.history_entries[index]) |entry| {
            const copy_len = @min(entry.len, BUFFER_SIZE);
            @memcpy(self.line_buffer[0..copy_len], entry[0..copy_len]);
            self.line_length = copy_len;
            self.cursor_position = copy_len;
            self.refreshLine();
        }
    }

    // -- Tests --

    // Helpers for testing: expose internal state without needing a terminal

    fn testInit() LineEditor {
        var output_buf: [4096]u8 = undefined;
        _ = &output_buf;
        return .{
            .allocator = std.testing.allocator,
            .stdout = std.io.null_writer.any(),
            .is_terminal = false,
        };
    }

    fn testInsertString(self: *LineEditor, string: []const u8) void {
        for (string) |byte| {
            self.insertCharacter(byte);
        }
    }

    fn getLineSlice(self: *const LineEditor) []const u8 {
        return self.line_buffer[0..self.line_length];
    }
};

// -- Escape parser tests --

test "escape parser: arrow keys" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Up arrow: ESC [ A
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeState.escape, editor.escape_state);
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeState.csi, editor.escape_state);
    try std.testing.expectEqual(EscapeAction.move_up, editor.processEscape('A'));
    try std.testing.expectEqual(EscapeState.ground, editor.escape_state);

    // Down arrow: ESC [ B
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.move_down, editor.processEscape('B'));

    // Right arrow: ESC [ C
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.move_right, editor.processEscape('C'));

    // Left arrow: ESC [ D
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.move_left, editor.processEscape('D'));
}

test "escape parser: home and end" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Home: ESC [ H
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.home, editor.processEscape('H'));

    // End: ESC [ F
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.end, editor.processEscape('F'));
}

test "escape parser: delete key" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Delete: ESC [ 3 ~
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('3'));
    try std.testing.expectEqual(EscapeState.csi_param, editor.escape_state);
    try std.testing.expectEqual(EscapeAction.delete_forward, editor.processEscape('~'));
    try std.testing.expectEqual(EscapeState.ground, editor.escape_state);
}

test "escape parser: unknown CSI param sequence" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC [ 5 ~ — not mapped, should return none
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('['));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('5'));
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('~'));
    try std.testing.expectEqual(EscapeState.ground, editor.escape_state);
}

test "escape parser: incomplete escape resets on non-bracket" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // ESC followed by non-'[' should reset to ground
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape(0x1b));
    try std.testing.expectEqual(EscapeState.escape, editor.escape_state);
    try std.testing.expectEqual(EscapeAction.none, editor.processEscape('x'));
    try std.testing.expectEqual(EscapeState.ground, editor.escape_state);
}

// -- Line buffer tests --

test "line buffer: insert characters" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);
    try std.testing.expectEqual(@as(usize, 5), editor.line_length);
}

test "line buffer: insert in middle" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hllo");
    editor.cursor_position = 1; // Move cursor after 'h'
    editor.insertCharacter('e');
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 2), editor.cursor_position);
}

test "line buffer: delete backward" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.deleteBackward();
    try std.testing.expectEqualStrings("hell", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 4), editor.cursor_position);
}

test "line buffer: delete backward in middle" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.cursor_position = 3;
    editor.deleteBackward();
    try std.testing.expectEqualStrings("helo", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 2), editor.cursor_position);
}

test "line buffer: delete backward at beginning does nothing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.cursor_position = 0;
    editor.deleteBackward();
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);
}

test "line buffer: delete forward" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.cursor_position = 2;
    editor.deleteForward();
    try std.testing.expectEqualStrings("helo", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 2), editor.cursor_position);
}

test "line buffer: delete forward at end does nothing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.deleteForward();
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
}

test "line buffer: cursor movement" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);

    editor.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 4), editor.cursor_position);

    editor.moveCursorRight();
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);

    // Right at end does nothing
    editor.moveCursorRight();
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);

    editor.moveCursorToBeginning();
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);

    // Left at beginning does nothing
    editor.moveCursorLeft();
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);

    editor.moveCursorToEnd();
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);
}

test "line buffer: kill line" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello world");
    editor.killLine();
    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);
}

test "line buffer: kill to end" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello world");
    editor.cursor_position = 5;
    editor.killToEnd();
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 5), editor.cursor_position);
}

test "line buffer: delete word backward" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello world");
    editor.deleteWordBackward();
    try std.testing.expectEqualStrings("hello ", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 6), editor.cursor_position);
}

test "line buffer: delete word backward with trailing spaces" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello   ");
    editor.deleteWordBackward();
    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);
}

test "line buffer: delete word backward at beginning does nothing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    editor.cursor_position = 0;
    editor.deleteWordBackward();
    try std.testing.expectEqualStrings("hello", editor.getLineSlice());
    try std.testing.expectEqual(@as(usize, 0), editor.cursor_position);
}

// -- History tests --

test "history: add and navigate" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.addHistoryEntry("first");
    editor.addHistoryEntry("second");
    editor.addHistoryEntry("third");

    try std.testing.expectEqual(@as(usize, 3), editor.history_count);

    // Navigate up — should load "third"
    editor.historyUp();
    try std.testing.expectEqualStrings("third", editor.getLineSlice());

    // Navigate up — should load "second"
    editor.historyUp();
    try std.testing.expectEqualStrings("second", editor.getLineSlice());

    // Navigate up — should load "first"
    editor.historyUp();
    try std.testing.expectEqualStrings("first", editor.getLineSlice());

    // Navigate down — should load "second"
    editor.historyDown();
    try std.testing.expectEqualStrings("second", editor.getLineSlice());

    // Navigate down — should load "third"
    editor.historyDown();
    try std.testing.expectEqualStrings("third", editor.getLineSlice());

    // Navigate down — should restore saved (empty) line
    editor.historyDown();
    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expect(editor.history_browse_index == null);
}

test "history: skip duplicates" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.addHistoryEntry("hello");
    editor.addHistoryEntry("hello");
    editor.addHistoryEntry("hello");

    try std.testing.expectEqual(@as(usize, 1), editor.history_count);
}

test "history: saves current line when browsing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.addHistoryEntry("old command");

    // Type something
    editor.testInsertString("in progress");

    // Navigate up — should save "in progress"
    editor.historyUp();
    try std.testing.expectEqualStrings("old command", editor.getLineSlice());

    // Navigate down — should restore "in progress"
    editor.historyDown();
    try std.testing.expectEqualStrings("in progress", editor.getLineSlice());
}

test "history: ring buffer wrapping" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    // Fill history past max
    for (0..MAX_HISTORY + 10) |idx| {
        var num_buf: [16]u8 = undefined;
        const num_str = std.fmt.bufPrint(&num_buf, "cmd {d}", .{idx}) catch continue;
        editor.addHistoryEntry(num_str);
    }

    try std.testing.expectEqual(@as(usize, MAX_HISTORY), editor.history_count);

    // Most recent should be "cmd 265" (MAX_HISTORY + 9)
    editor.historyUp();
    try std.testing.expectEqualStrings("cmd 265", editor.getLineSlice());
}

test "history: up on empty history does nothing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.historyUp();
    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expect(editor.history_browse_index == null);
}

test "history: down without browsing does nothing" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.addHistoryEntry("something");
    editor.historyDown();
    try std.testing.expectEqualStrings("", editor.getLineSlice());
    try std.testing.expect(editor.history_browse_index == null);
}

// -- Input processing tests --

test "processInput: printable characters" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput('a'));
    try std.testing.expectEqualStrings("a", editor.getLineSlice());

    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput('b'));
    try std.testing.expectEqualStrings("ab", editor.getLineSlice());
}

test "processInput: submit on enter" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqual(LineEditor.InputResult.submit_line, editor.processInput('\r'));
}

test "processInput: ctrl+c cancels line" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("hello");
    try std.testing.expectEqual(LineEditor.InputResult.cancel_line, editor.processInput(0x03));
}

test "processInput: ctrl+d on empty sends eof" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    try std.testing.expectEqual(LineEditor.InputResult.eof_signal, editor.processInput(0x04));
}

test "processInput: backspace deletes backward" {
    var editor = LineEditor.testInit();
    defer editor.deinit();

    editor.testInsertString("abc");
    try std.testing.expectEqual(LineEditor.InputResult.continue_reading, editor.processInput(0x7f));
    try std.testing.expectEqualStrings("ab", editor.getLineSlice());
}
