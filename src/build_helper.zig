const std = @import("std");

/// Hard-block checks that should run on every build.
/// Keep this in sync with src/cli/registry.zig — these names must match.
/// `spec-init` is intentionally excluded: it's a generator, not a gate.
pub const all_check_names: []const []const u8 = &.{
    "spec",
    "file-size",
    "boundaries",
    "usingnamespace-ban",
    "spec-quality",
    "naming",
    "function-size",
    "doc-comments",
    "imports",
    "pub-api-surface",
    "panic-budget",
    "spec-drift",
    "catch-discipline",
    "error-discipline",
};

/// Tunables for addAllChecks.
pub const Options = struct {
    quiet: bool = true,
    /// Optional working directory for each check invocation. Null means
    /// the build's current working directory.
    cwd: ?std.Build.LazyPath = null,
};

/// Adds a RunArtifact step for each hard-block check; each becomes a
/// dependency of `target_step`. Steps run in parallel when the build
/// graph allows.
pub fn addAllChecks(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    target_step: *std.Build.Step,
    opts: Options,
) void {
    for (all_check_names) |name| {
        const run = b.addRunArtifact(check_exe);
        if (opts.quiet) {
            run.addArgs(&.{ name, ".", "--quiet" });
        } else {
            run.addArgs(&.{ name, "." });
        }
        if (opts.cwd) |cwd| run.setCwd(cwd);
        target_step.dependOn(&run.step);
    }
}
