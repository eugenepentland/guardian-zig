const std = @import("std");
const Allocator = std.mem.Allocator;
const print = std.debug.print;

pub const GREEN = "\x1b[32m";
pub const RED = "\x1b[31m";
pub const RESET = "\x1b[0m";
pub const PREFIX = "guardian: ";

/// A single check failure with optional location and fix hint.
pub const Violation = struct {
    file: ?[]const u8 = null,
    line: ?u32 = null,
    message: []const u8,
    fix_hint: ?[]const u8 = null,
};

/// Captures formatted output instead of printing it. Used by baseline
/// mode to intercept a check's violation lines for diffing.
pub const Capture = struct {
    allocator: Allocator,
    buf: std.ArrayListUnmanaged(u8) = .empty,

    pub fn deinit(self: *Capture) void {
        self.buf.deinit(self.allocator);
    }

    pub fn write(self: *Capture, comptime fmt: []const u8, args: anytype) void {
        self.buf.writer(self.allocator).print(fmt, args) catch |e|
            std.log.warn("guardian capture write failed: {s}", .{@errorName(e)});
    }
};

/// Output controller — owns color, quiet, and (optional) capture state.
pub const Reporter = struct {
    use_color: bool = false,
    quiet: bool = false,
    /// When non-null, all output is appended here and not printed.
    capture: ?*Capture = null,

    pub fn ok(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(PREFIX ++ fmt ++ "\n", args);
            return;
        }
        if (self.quiet) return;
        if (self.use_color)
            print(GREEN ++ PREFIX ++ RESET ++ fmt ++ "\n", args)
        else
            print(PREFIX ++ fmt ++ "\n", args);
    }

    pub fn fail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(PREFIX ++ fmt ++ "\n", args);
            return;
        }
        if (self.use_color)
            print(RED ++ PREFIX ++ RESET ++ fmt ++ "\n", args)
        else
            print(PREFIX ++ fmt ++ "\n", args);
    }

    pub fn detail(self: Reporter, comptime fmt: []const u8, args: anytype) void {
        if (self.capture) |c| {
            c.write(fmt, args);
            return;
        }
        print(fmt, args);
    }

    pub fn emit(self: Reporter, v: Violation) void {
        if (self.capture) |c| {
            emitTo(c, v);
            return;
        }
        emitDirect(v);
    }
};

fn emitTo(c: *Capture, v: Violation) void {
    if (v.file) |f| {
        if (v.line) |l|
            c.write("  {s}:{d}: {s}\n", .{ f, l, v.message })
        else
            c.write("  {s}: {s}\n", .{ f, v.message });
    } else {
        c.write("  {s}\n", .{v.message});
    }
    if (v.fix_hint) |h| c.write("    fix: {s}\n", .{h});
}

fn emitDirect(v: Violation) void {
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
