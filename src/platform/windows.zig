const std = @import("std");
const common = @import("common.zig");

pub const Term = @cImport({
    @cInclude("windows.h");
});

pub fn getTerminalSize() !common.TerminalSize {
    var info: Term.CONSOLE_SCREEN_BUFFER_INFO = undefined;
    const handle = Term.GetStdHandle(Term.STD_OUTPUT_HANDLE);
    if (Term.GetConsoleScreenBufferInfo(handle, &info) == 0) {
        return error.WindowsApiError;
    }
    const cols = @as(usize, @intCast(info.srWindow.Right - info.srWindow.Left + 1));
    const rows = @as(usize, @intCast(info.srWindow.Bottom - info.srWindow.Top + 1));
    return common.TerminalSize{ .rows = rows, .cols = cols };
}

pub fn setupSignalHandler(handler: fn (Term.DWORD) callconv(Term.WINAPI) Term.BOOL) void {
    _ = Term.SetConsoleCtrlHandler(handler, 1);
}

pub fn enableAnsiEscapes() void {
    const handle = Term.GetStdHandle(Term.STD_OUTPUT_HANDLE);
    var mode: Term.DWORD = undefined;
    if (Term.GetConsoleMode(handle, &mode) != 0) {
        _ = Term.SetConsoleMode(handle, mode | Term.ENABLE_VIRTUAL_TERMINAL_PROCESSING);
    }
}
