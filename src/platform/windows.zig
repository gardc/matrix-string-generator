const std = @import("std");
const common = @import("common.zig");
const windows = std.os.windows;

pub const Term = struct {
    pub const DWORD = windows.DWORD;
    pub const BOOL = windows.BOOL;
    pub const WINAPI = windows.WINAPI;
    pub const CTRL_C_EVENT = windows.CTRL_C_EVENT;
    pub const SIGINT = CTRL_C_EVENT;
    pub const SIGWINCH = undefined; // Windows doesn't have SIGWINCH
};

pub fn getTerminalSize() !common.TerminalSize {
    var info: windows.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const handle = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return error.WindowsApiError;
    if (windows.kernel32.GetConsoleScreenBufferInfo(handle, &info) == 0) {
        return error.WindowsApiError;
    }
    const cols = @as(usize, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
    const rows = @as(usize, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));
    return common.TerminalSize{ .rows = rows, .cols = cols };
}

pub fn setupSignalHandler(handler: *const fn (Term.DWORD) callconv(Term.WINAPI) Term.BOOL) void {
    _ = windows.kernel32.SetConsoleCtrlHandler(handler, 1);
}

pub fn enableAnsiEscapes() void {
    const handle = windows.kernel32.GetStdHandle(windows.STD_OUTPUT_HANDLE) orelse return;
    var mode: windows.DWORD = undefined;
    if (windows.kernel32.GetConsoleMode(handle, &mode) != 0) {
        _ = windows.kernel32.SetConsoleMode(handle, mode | windows.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}
