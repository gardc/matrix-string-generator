const std = @import("std");
const time = std.time;
const builtin = @import("builtin");

// Import platform-specific code
const platform = if (builtin.target.os.tag == .windows)
    @import("platform/windows.zig")
else
    @import("platform/posix.zig");

const common = @import("platform/common.zig");
const TerminalSize = common.TerminalSize;

var stdout: std.fs.File.Writer = undefined;
var buffered: std.io.BufferedWriter(4096, std.fs.File.Writer) = undefined;
var writer: @TypeOf(buffered).Writer = undefined;

var global_state: ?*State = null;

const State = struct {
    size: TerminalSize,
    characters: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    prng: std.Random.Xoshiro256,
    resize_needed: bool = false,
    map: []u8,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) !State {
        const seed: u64 = @intCast(std.time.timestamp());
        const prng = std.Random.DefaultPrng.init(seed);

        const size = try getTerminalSize();

        const map = try allocator.alloc(u8, size.rows * size.cols);
        for (map) |*cell| {
            cell.* = ' ';
        }

        return State{
            .size = size,
            .prng = prng,
            .map = map,
            .resize_needed = false,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.map);
    }

    pub fn updateMap(self: *State) !void {
        // Process rows from bottom to top to prevent multiple moves in one update
        const rand = self.prng.random();

        var row: usize = self.size.rows;
        while (row > 0) : (row -= 1) {
            const current_row = row - 1;
            const y = current_row * self.size.cols;

            for (0..self.size.cols) |col| {
                const current_index = y + col;
                if (current_index >= self.map.len) continue;

                const cell = self.map[current_index];
                if (cell != ' ' and current_row < self.size.rows - 1) {
                    const next_index = current_index + self.size.cols;
                    if (next_index < self.map.len) {
                        self.map[next_index] = cell;
                        self.map[current_index] = ' ';
                    }
                }
            }

            if (row == 1) {
                for (0..self.size.cols) |col| {
                    if (rand.intRangeAtMost(usize, 0, 100) < 5) {
                        const new_char = try self.getRandomChar();
                        // std.debug.print("Generated char: {c}\n", .{new_char}); // Debug print
                        self.map[col] = new_char;
                    } else if (self.map[col] != ' ') {
                        self.map[col] = ' ';
                    }
                }
            }
        }
    }

    pub fn drawMap(self: *State) !void {
        // Save cursor position and attributes
        try writer.writeAll("\x1b[s");
        try writer.writeAll("\x1b[H");
        try buffered.flush();

        for (self.map, 0..) |cell, i| {
            if (i % self.size.cols == 0 and i != 0) {
                try writer.writeAll("\n");
            }
            const row = i / self.size.cols;
            if (row == self.size.rows - 1) {
                try writer.writeAll("\x1b[91m");
                try writer.writeByte(cell);
            } else if (cell != ' ') {
                try writer.writeAll("\x1b[92m");
                try writer.writeByte(cell);
            } else {
                try writer.writeAll("\x1b[0m");
                try writer.writeByte(cell);
            }
        }

        // Restore cursor position and attributes
        try writer.writeAll("\x1b[u");
        try buffered.flush();
    }

    pub inline fn updateTerminalSize(self: *State) !void {
        switch (builtin.target.os.tag) {
            .windows => {
                // windows doesn't support SIGWINCH, so we need to manually check if resize is needed
                const newSize = try getTerminalSize();
                if (newSize.rows != self.size.rows or newSize.cols != self.size.cols) {
                    try self.resize(newSize);
                }
            },
            else => {
                // posix systems support SIGWINCH, so we only need to resize when the terminal is resized
                if (!self.resize_needed) return;

                const newSize = try getTerminalSize();
                if (newSize.rows != self.size.rows or newSize.cols != self.size.cols) {
                    try self.resize(newSize);
                }
                self.resize_needed = false;
            },
        }
    }

    pub fn resize(self: *State, newSize: TerminalSize) !void {
        // resize map and clear everything
        self.size = newSize;
        self.map = try self.allocator.realloc(self.map, newSize.rows * newSize.cols);
        for (self.map) |*cell| {
            cell.* = ' ';
        }
    }

    pub fn getRandomChar(self: *State) !u8 {
        const rand = self.prng.random();
        const random_index = rand.intRangeAtMost(usize, 0, self.characters.len - 1);
        return self.characters[random_index];
    }
};

fn getTerminalSize() !TerminalSize {
    return platform.getTerminalSize();
}

fn clearScreen() !void {
    // try stdout.writeAll("\x1b[?25h"); // show cursor
    try stdout.writeAll("\x1b[2J\x1b[H"); // clear screen
}

fn setupSignalHandler() void {
    if (comptime builtin.target.os.tag == .windows) {
        platform.setupSignalHandler(handleSignalWindows);
    } else {
        platform.setupSignalHandler(handleSignal);
    }
}

export fn handleSignal(sig: c_int) callconv(.C) void {
    if (sig == platform.Term.SIGINT) {
        // Show cursor before exit
        stdout.writeAll("\x1b[2J\x1b[H") catch {}; // clear screen
        stdout.writeAll("\x1b[?25h") catch {}; // show cursor
        std.process.exit(0);
    } else if (builtin.target.os.tag != .windows and sig == platform.Term.SIGWINCH) {
        if (global_state) |state| {
            state.resize_needed = true;
        }
    }
}

fn handleSignalWindows(ctrlType: platform.Term.DWORD) callconv(platform.Term.WINAPI) platform.Term.BOOL {
    if (ctrlType == platform.Term.CTRL_C_EVENT) {
        stdout.writeAll("\x1b[?25h") catch {}; // show cursor
        stdout.writeAll("\x1b[2J\x1b[H") catch {}; // clear screen
        std.process.exit(0);
    }
    return 0;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // setup stdout
    const stdout_file = std.io.getStdOut();
    stdout = stdout_file.writer();
    buffered = std.io.bufferedWriter(stdout);
    writer = buffered.writer();

    // Hide cursor
    try stdout.writeAll("\x1b[?25l");
    // Clear screen once at start
    try clearScreen();

    // Setup signal handler
    setupSignalHandler();

    if (comptime builtin.target.os.tag == .windows) {
        platform.enableAnsiEscapes();
    }

    var state = try State.init(allocator);
    defer state.deinit();
    global_state = &state;

    while (true) {
        try state.updateTerminalSize();

        try state.updateMap();
        try state.drawMap();
        time.sleep(20 * time.ns_per_ms);
    }
}
