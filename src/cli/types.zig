const std = @import("std");
const config_mod = @import("../config.zig");

/// Errors any check `run` function may propagate. Composed from stdlib
/// I/O and allocator errors plus Guardian-specific snapshot/parse errors.
/// Adding a new error is a real change to the contract; the explicit
/// declaration is the point.
pub const RunError =
    std.mem.Allocator.Error ||
    std.fs.File.OpenError ||
    std.fs.File.WriteError ||
    std.fs.File.ReadError ||
    std.fs.Dir.MakeError ||
    error{
        BadFormat,
        Missing,
        VersionMismatch,
        CouldNotReadSpec,
        Unexpected,
        EndOfStream,
        StreamTooLong,
        ReadFailed,
        WriteFailed,
        Canceled,
        NoDevice,
        SharingViolation,
        PathAlreadyExists,
        PipeBusy,
        AntivirusInterference,
        InvalidUtf8,
        InvalidWtf8,
        BadPathName,
        FileBusy,
        WouldBlock,
        FileLocksNotSupported,
        FileTooBig,
        IsDir,
        NotDir,
        OperationAborted,
        ConnectionResetByPeer,
        ConnectionTimedOut,
        SocketNotConnected,
        ProcessNotFound,
        InvalidArgument,
    };

/// Per-invocation context handed to every check's `run` function.
pub const RunCtx = struct {
    allocator: std.mem.Allocator,
    project_dir: []const u8,
    cfg: *const config_mod.Config,
    quiet: bool,
};

/// Whether a check needs the AST index built before invocation.
pub const NeedsAst = enum { no, yes };

/// Entry in the subcommand registry.
pub const Command = struct {
    name: []const u8,
    summary: []const u8,
    needs_ast: NeedsAst = .no,
    run: *const fn (ctx: *RunCtx) RunError!void,
};
