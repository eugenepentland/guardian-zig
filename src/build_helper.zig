const std = @import("std");
const registry = @import("cli/registry.zig");

const GENERATOR_NAME = "spec-init"; // generator, not a gate
const MUTATE_NAME = "mutate"; // explicit step, not a gate
const RUN_ALL_NAME = "all";

// Comptime branch budget for the registry-iteration loop in
// all_check_names. Bumped manually if the registry grows enough to
// exhaust it.
const REGISTRY_EVAL_QUOTA: u32 = 20000;

/// Hard-block checks that should run on every build. Derived from
/// `cli/registry.zig::all` at comptime — adding a new check there wires it
/// here automatically.
pub const all_check_names: []const []const u8 = blk: {
    @setEvalBranchQuota(REGISTRY_EVAL_QUOTA);
    var names: []const []const u8 = &.{};
    for (registry.all) |cmd| {
        if (std.mem.eql(u8, cmd.name, GENERATOR_NAME)) continue;
        if (std.mem.eql(u8, cmd.name, MUTATE_NAME)) continue;
        if (std.mem.eql(u8, cmd.name, RUN_ALL_NAME)) continue;
        names = names ++ [_][]const u8{cmd.name};
    }
    break :blk names;
};

/// Tunables for addAllChecks.
pub const Options = struct {
    quiet: bool = true,
    /// Optional working directory for each check invocation. Null means
    /// the build's current working directory.
    cwd: ?std.Build.LazyPath = null,
    /// When true (default), every hard-block check runs sequentially in
    /// one `guardian-check all` invocation — eliminates 20+ process
    /// spawns per build. When false, each check is its own RunArtifact
    /// (the legacy mode; lets the build graph parallelize across checks).
    single_process: bool = true,
};

/// Adds RunArtifact step(s) for the hard-block checks as dependencies of
/// `target_step`. By default emits one combined step (`all`); set
/// `opts.single_process = false` to emit one step per check.
pub fn addAllChecks(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    target_step: *std.Build.Step,
    opts: Options,
) void {
    if (opts.single_process) {
        const run = b.addRunArtifact(check_exe);
        if (opts.quiet) {
            run.addArgs(&.{ RUN_ALL_NAME, ".", "--quiet" });
        } else {
            run.addArgs(&.{ RUN_ALL_NAME, "." });
        }
        if (opts.cwd) |cwd| run.setCwd(cwd);
        target_step.dependOn(&run.step);
        return;
    }

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
