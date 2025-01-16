const std = @import("std");
const time = std.time;
const posix = std.posix;
const builtin = @import("builtin");
const Term = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

const stdout = std.io.getStdOut().writer();

const TerminalSize = struct {
    rows: usize,
    cols: usize,
};

const State = struct {
    size: TerminalSize,
    characters: []const u8 = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789",
    prng: std.rand.Xoshiro256,
    last_frame: i128,
    frame_time_ns: i128,

    map: []u8,

    allocator: std.mem.Allocator,

    const target_fps = 15;

    pub fn init(allocator: std.mem.Allocator) !State {
        const seed: u64 = @intCast(std.time.timestamp());
        const prng = std.rand.DefaultPrng.init(seed);

        const frame_time_ns = time.ns_per_s / target_fps;
        const last_frame = time.nanoTimestamp();

        const size = try getTerminalSize();

        const map = try allocator.alloc(u8, size.rows * size.cols);
        for (map) |*cell| {
            cell.* = ' ';
        }

        return State{
            .size = size,
            .prng = prng,
            .last_frame = last_frame,
            .frame_time_ns = frame_time_ns,
            .map = map,
            .allocator = allocator,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.map);
    }

    fn xyToIndex(self: *State, row: usize, col: usize) usize {
        return row * self.size.cols + col;
    }

    fn indexToXY(self: *State, index: usize) struct { row: usize, col: usize } {
        return .{ .row = index / self.size.cols, .col = index % self.size.cols };
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
        try stdout.writeAll("\x1b[s");

        // Position cursor at start without clearing
        try stdout.writeAll("\x1b[H");

        for (self.map, 0..) |cell, i| {
            if (i % self.size.cols == 0 and i != 0) {
                try stdout.writeAll("\n");
            }
            const row = i / self.size.cols;
            if (row == self.size.rows - 1) { // Check last row first
                try stdout.print("\x1b[91m{c}", .{cell});
            } else if (cell != ' ') {
                try stdout.print("\x1b[92m{c}", .{cell});
            } else {
                try stdout.print("\x1b[0m{c}", .{cell});
            }
        }

        // Restore cursor position and attributes
        try stdout.writeAll("\x1b[u");
    }

    pub fn updateTerminalSize(self: *State) !void {
        const newSize = try getTerminalSize();
        if (newSize.rows != self.size.rows or newSize.cols != self.size.cols) {
            try self.resize(newSize);
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
    if (comptime builtin.target.os.tag == .windows) {
        return error.WindowsNotSupported;
    }

    var wsz: Term.winsize = undefined;
    if (Term.ioctl(posix.STDOUT_FILENO, Term.TIOCGWINSZ, &wsz) != 0) {
        return error.IoctlError;
    }
    const rows = wsz.ws_row;
    const cols = wsz.ws_col;

    return TerminalSize{ .rows = rows, .cols = cols };
}

fn clearScreen() !void {
    // try stdout.writeAll("\x1b[?25h"); // show cursor
    try stdout.writeAll("\x1b[2J\x1b[H"); // clear screen
}

fn setupSignalHandler() void {
    if (comptime builtin.target.os.tag == .macos) {
        const sa = Term.struct_sigaction{
            .__sigaction_u = .{ .__sa_handler = handleSignal },
            .sa_flags = 0,
            .sa_mask = 0,
        };
        _ = Term.sigaction(Term.SIGINT, &sa, null);
    }
    // will add Linux and Windows handling later
}

export fn handleSignal(sig: c_int) callconv(.C) void {
    if (sig == Term.SIGINT) {
        // Show cursor before exit
        stdout.writeAll("\x1b[?25h") catch {}; // show cursor
        stdout.writeAll("\x1b[2J\x1b[H") catch {}; // clear screen
        std.process.exit(0);
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Hide cursor
    try stdout.writeAll("\x1b[?25l");
    // Clear screen once at start
    try clearScreen();

    // Setup signal handler
    setupSignalHandler();

    var state = try State.init(allocator);
    defer state.deinit();

    while (true) {
        try state.updateTerminalSize();

        try state.updateMap();
        try state.drawMap();
        time.sleep(50 * time.ns_per_ms);
    }
}
