const std = @import("std");
const print = std.debug.print;

pub const GREEN = "\x1b[32m";
pub const RED = "\x1b[31m";
pub const RESET = "\x1b[0m";

/// A single check failure with optional location and fix hint.
pub const Violation = struct {
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
    fix_hint: ?[]const u8 = null,
};

/// Output controller — owns color and quiet state.
pub const Reporter = struct {
    use_color: bool = false,
    quiet: bool = false,

    pub fn ok(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.quiet) return;
        if (self.use_color)
            print(GREEN ++ "guardian: " ++ RESET ++ fmt ++ "\n", args)
        else
            print("guardian: " ++ fmt ++ "\n", args);
    }

    pub fn fail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.use_color)
            print(RED ++ "guardian: " ++ RESET ++ fmt ++ "\n", args)
        else
            print("guardian: " ++ fmt ++ "\n", args);
    }

    pub fn detail(_: Reporter, comptime fmt: []const u8, args: anytype) void {
        print(fmt, args);
    }

    pub fn emit(_: Reporter, v: Violation) void {
        if (v.file) |f| {
            if (v.line) |l|
                print("  {s}:{d}: {s}\n", .{ f, l, v.message })
            else
                print("  {s}: {s}\n", .{ f, v.message });
        } else {
            print("  {s}\n", .{v.message});
        }
        if (v.fix_hint) |h| print("    fix: {s}\n", .{h});
    }
};

pub var default: Reporter = .{};

/// Initializes the module-level default Reporter (TTY-detected color).
pub fn init(quiet: bool) void {
    default = .{
        .use_color = std.fs.File.stderr().isTty(),
        .quiet = quiet,
    };
}

/// Print a green-prefixed success line (suppressed when quiet).
pub fn ok(comptime fmt: []const u8, args: anytype) void {
    default.ok(fmt, args);
}

/// Print a red-prefixed failure line (always printed, even when quiet).
pub fn fail(comptime fmt: []const u8, args: anytype) void {
    default.fail(fmt, args);
}

/// Print a follow-on detail line beneath an ok/fail message.
pub fn detail(comptime fmt: []const u8, args: anytype) void {
    default.detail(fmt, args);
}

/// Format and print a Violation record.
pub fn emit(v: Violation) void {
    default.emit(v);
}
