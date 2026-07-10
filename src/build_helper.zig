const std = @import("std");
const registry = @import("cli/registry.zig");

const generator_name = "spec-init"; // generator, not a gate
const mutate_name = "mutate"; // explicit step, not a gate
const debt_name = "debt"; // non-gating debt report, invoked directly
const nightly_name = "nightly"; // composed scheduled tier, dispatched specially
const commit_name = "commit"; // gate + auto-commit, dispatched specially
const run_all_name = "all";

// Comptime branch budget for the registry-iteration loop in
// all_check_names. Bumped manually if the registry grows enough to
// exhaust it.
const registry_eval_quota: u32 = 20000;

/// Hard-block checks that should run on every build. Derived from
/// `cli/registry.zig::all` at comptime — adding a new check there wires it
/// here automatically. The generator (`spec-init`), the explicit `mutate`
/// step, the non-gating `debt` report, and the composed `nightly`/`commit`/
/// `all` commands are never gates and are excluded (the last three defensively —
/// they are dispatched specially and don't appear in the registry, mirroring
/// the existing `all` exclusion).
pub const all_check_names: []const []const u8 = blk: {
    @setEvalBranchQuota(registry_eval_quota);
    var names: []const []const u8 = &.{};
    for (registry.all) |cmd| {
        if (std.mem.eql(u8, cmd.name, generator_name)) continue;
        if (std.mem.eql(u8, cmd.name, mutate_name)) continue;
        if (std.mem.eql(u8, cmd.name, debt_name)) continue;
        if (std.mem.eql(u8, cmd.name, nightly_name)) continue;
        if (std.mem.eql(u8, cmd.name, commit_name)) continue;
        if (std.mem.eql(u8, cmd.name, run_all_name)) continue;
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
    /// When true (default), also register the top-level `mutate` and
    /// `mutate-full` steps so consumers get the mutation tier for free the
    /// day they upgrade — no hand-wiring. Registration is idempotent (see
    /// `registerMutateSteps`), so calling addAllChecks more than once (a
    /// consumer typically wires both the install and test steps) is safe.
    mutate_steps: bool = true,
};

/// Adds RunArtifact step(s) for the hard-block checks as dependencies of
/// `target_step`. By default emits one combined step (`all`); set
/// `opts.single_process = false` to emit one step per check. Unless
/// `opts.mutate_steps = false`, also registers the top-level `mutate` /
/// `mutate-full` steps once.
pub fn addAllChecks(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    target_step: *std.Build.Step,
    opts: Options,
) void {
    if (opts.mutate_steps) registerMutateSteps(b, check_exe, opts);

    if (opts.single_process) {
        const run = b.addRunArtifact(check_exe);
        if (opts.quiet) {
            run.addArgs(&.{ run_all_name, ".", "--quiet" });
        } else {
            run.addArgs(&.{ run_all_name, "." });
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

/// Registers the `mutate` (fast tier) and `mutate-full` (whole-tree ratchet)
/// top-level steps. Each is a standalone user-invoked step, never a dependency
/// of the build (a mutant costs a build + test cycle, so mutation is not a
/// gate). Idempotent so it survives multiple addAllChecks calls and a
/// consumer's own hand-rolled steps.
fn registerMutateSteps(b: *std.Build, check_exe: *std.Build.Step.Compile, opts: Options) void {
    ensureMutateStep(b, check_exe, opts, mutate_name, "Mutation-test changed lines (fast tier)", &.{
        mutate_name, ".",
    });
    ensureMutateStep(b, check_exe, opts, "mutate-full", "Mutation-test whole tree + score ratchet", &.{
        mutate_name, ".", "--full",
    });
}

/// Creates one mutate step wired to `guardian-check <args>`, but only when no
/// top-level step of that name already exists — `b.step` panics on a duplicate,
/// so the `contains` guard is what makes repeated calls (and a consumer's own
/// hand-rolled `mutate` step) safe in either order.
fn ensureMutateStep(
    b: *std.Build,
    check_exe: *std.Build.Step.Compile,
    opts: Options,
    name: []const u8,
    description: []const u8,
    args: []const []const u8,
) void {
    if (b.top_level_steps.contains(name)) return;
    const run = b.addRunArtifact(check_exe);
    run.addArgs(args);
    if (opts.cwd) |cwd| run.setCwd(cwd);
    const step = b.step(name, description);
    step.dependOn(&run.step);
}
