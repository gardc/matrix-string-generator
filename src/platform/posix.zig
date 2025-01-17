const std = @import("std");
const common = @import("common.zig");
const posix = std.posix;
const builtin = @import("builtin");

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
    var sa: Term.struct_sigaction = undefined;
    if (comptime builtin.target.os.tag == .linux) {
        sa = Term.struct_sigaction{
            .__sa_handler = .{ .sa_handler = handler },
            .sa_flags = 0,
            .sa_mask = std.mem.zeroes(Term.struct___sigset_t),
        };
    } else if (comptime builtin.target.os.tag == .macos) {
        sa = Term.struct_sigaction{
            .__sigaction_u = .{ .__sa_handler = handler },
            .sa_flags = 0,
            .sa_mask = 0,
        };
    }
    _ = Term.sigaction(Term.SIGINT, &sa, null);
    _ = Term.sigaction(Term.SIGWINCH, &sa, null);
}
