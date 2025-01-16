const std = @import("std");
const common = @import("common.zig");
const posix = std.posix;

pub const Term = @cImport({
    @cInclude("sys/ioctl.h");
    @cInclude("signal.h");
});

pub fn getTerminalSize() !common.TerminalSize {
    var wsz: Term.winsize = undefined;
    if (Term.ioctl(posix.STDOUT_FILENO, Term.TIOCGWINSZ, &wsz) != 0) {
        return error.IoctlError;
    }
    return common.TerminalSize{ .rows = wsz.ws_row, .cols = wsz.ws_col };
}

pub fn setupSignalHandler(handler: fn (c_int) callconv(.C) void) void {
    const sa = Term.struct_sigaction{
        .__sigaction_u = .{ .__sa_handler = handler },
        .sa_flags = 0,
        .sa_mask = 0,
    };
    _ = Term.sigaction(Term.SIGINT, &sa, null);
    _ = Term.sigaction(Term.SIGWINCH, &sa, null);
}
