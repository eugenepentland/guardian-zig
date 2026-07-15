//! Read-only project-health diagnostics for Guardian metadata and integration.

const std = @import("std");
const types = @import("types.zig");
const registry = @import("registry.zig");
const reporter = @import("../reporter.zig");

const cache_warn_bytes: u64 = 1024 * 1024 * 1024;
const max_metadata_bytes = 16 * 1024 * 1024;
const retired = [_][]const u8{
    "spec-drift", "comptime-quota",       "doc-quality", "vague-name-blacklist",
    "dup-const",  "returns-per-function",
};
const snapshots = [_][]const u8{
    "pub-api.txt",           "panic-budget.txt", "int-from-float-budget.txt",
    "unsafe-ops-budget.txt", "mutation.txt",
};

const Findings = struct {
    warnings: usize = 0,
    integrity: usize = 0,
};

/// Audits Guardian's local metadata without modifying project files. Only
/// corrupt/unreadable recognized metadata is fatal; stale files, cache growth,
/// and local path integration are advisory.
pub fn run(ctx: *types.RunCtx) types.RunError!void {
    var findings: Findings = .{};
    try inspectBaselines(ctx, &findings);
    try inspectSnapshots(ctx, &findings);
    try inspectMutationAdoption(ctx, &findings);
    try inspectIntegration(ctx, &findings);
    try inspectCache(ctx, &findings);

    if (findings.integrity > 0) {
        reporter.fail("doctor found {d} metadata integrity problem(s) and {d} advisory warning(s)", .{
            findings.integrity, findings.warnings,
        });
        return error.CheckFailed;
    }
    reporter.ok("doctor: metadata integrity is healthy ({d} advisory warning(s))", .{findings.warnings});
}

fn inspectBaselines(ctx: *types.RunCtx, findings: *Findings) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/baselines", .{ctx.project_dir});
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => {
            integrity(findings, "cannot read baseline directory {s}: {s}", .{ path, @errorName(e) });
            return;
        },
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |e| {
        integrity(findings, "cannot enumerate {s}: {s}", .{ path, @errorName(e) });
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        const name = entry.name[0 .. entry.name.len - ".txt".len];
        if (!knownCheck(name)) {
            advisory(
                findings,
                "stale baseline: .guardian/baselines/{s} (preview with `debt --prune-stale`)",
                .{entry.name},
            );
        }
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
        try inspectHeader(ctx.allocator, full, findings);
    }
}

fn inspectSnapshots(ctx: *types.RunCtx, findings: *Findings) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian", .{ctx.project_dir});
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return,
        else => {
            integrity(findings, "cannot read metadata directory {s}: {s}", .{ path, @errorName(e) });
            return;
        },
    };
    defer dir.close();
    var it = dir.iterate();
    while (it.next() catch |e| {
        integrity(findings, "cannot enumerate {s}: {s}", .{ path, @errorName(e) });
        return;
    }) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".txt")) continue;
        if (!contains(snapshots[0..], entry.name)) {
            advisory(findings, "unrecognized Guardian snapshot: .guardian/{s}", .{entry.name});
            continue;
        }
        const full = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ path, entry.name });
        try inspectHeader(ctx.allocator, full, findings);
    }
}

fn inspectHeader(allocator: std.mem.Allocator, path: []const u8, findings: *Findings) !void {
    const content = std.fs.cwd().readFileAlloc(allocator, path, max_metadata_bytes) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        integrity(findings, "cannot read recognized metadata {s}: {s}", .{ path, @errorName(e) });
        return;
    };
    if (!std.mem.startsWith(u8, content, "# guardian-snapshot v")) {
        integrity(findings, "malformed Guardian metadata header: {s}", .{path});
    }
}

fn inspectMutationAdoption(ctx: *types.RunCtx, findings: *Findings) !void {
    const config_path = try std.fmt.allocPrint(ctx.allocator, "{s}/guardian.toml", .{ctx.project_dir});
    const cfg = std.fs.cwd().readFileAlloc(ctx.allocator, config_path, 1024 * 1024) catch |e| blk: {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        break :blk "";
    };
    const marker = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/cache/last-mutate.jsonl", .{ctx.project_dir});
    const explicitly_configured = std.mem.indexOf(u8, cfg, "[mutation]") != null;
    const previously_run = blk: {
        std.fs.cwd().access(marker, .{}) catch break :blk false;
        break :blk true;
    };
    if (!explicitly_configured and !previously_run) return;
    const ratchet = try std.fmt.allocPrint(ctx.allocator, "{s}/.guardian/mutation.txt", .{ctx.project_dir});
    std.fs.cwd().access(ratchet, .{}) catch {
        advisory(
            findings,
            "mutation is adopted but its ratchet is missing; run `guardian-check mutate --full {s}`",
            .{ctx.project_dir},
        );
    };
}

fn inspectIntegration(ctx: *types.RunCtx, findings: *Findings) !void {
    const zon_path = try std.fmt.allocPrint(ctx.allocator, "{s}/build.zig.zon", .{ctx.project_dir});
    const zon = std.fs.cwd().readFileAlloc(ctx.allocator, zon_path, 4 * 1024 * 1024) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        return;
    };
    if (usesPathIntegration(zon)) {
        advisory(findings, "Guardian dependency uses a local path; pin a release URL + hash in CI/release builds", .{});
    }
}

fn usesPathIntegration(zon: []const u8) bool {
    return std.mem.indexOf(u8, zon, ".guardian =") != null and
        (std.mem.indexOf(u8, zon, ".path =") != null or std.mem.indexOf(u8, zon, "../guardian") != null);
}

fn inspectCache(ctx: *types.RunCtx, findings: *Findings) !void {
    for ([_][]const u8{ ".guardian/cache", ".zig-cache", "zig-cache" }) |leaf| {
        try inspectOneCache(ctx, findings, leaf);
    }
}

fn inspectOneCache(ctx: *types.RunCtx, findings: *Findings, leaf: []const u8) !void {
    const path = try std.fmt.allocPrint(ctx.allocator, "{s}/{s}", .{ ctx.project_dir, leaf });
    const bytes = (try dirSize(ctx.allocator, path)) orelse return;
    if (bytes >= cache_warn_bytes) {
        advisory(findings, "derived cache {s} is {d} MiB; consider clearing it when no build is running", .{
            leaf, bytes / (1024 * 1024),
        });
    }
}

fn dirSize(allocator: std.mem.Allocator, path: []const u8) std.mem.Allocator.Error!?u64 {
    var dir = std.fs.cwd().openDir(path, .{ .iterate = true }) catch return null;
    defer dir.close();
    var total: u64 = 0;
    var it = dir.iterate();
    while (it.next() catch return null) |entry| {
        if (entry.kind == .file) {
            total += (dir.statFile(entry.name) catch continue).size;
        } else if (entry.kind == .directory) {
            const child = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ path, entry.name });
            total += (try dirSize(allocator, child)) orelse 0;
        }
    }
    return total;
}

fn knownCheck(name: []const u8) bool {
    if (registry.find(name) != null) return true;
    return contains(retired[0..], name);
}

fn contains(haystack: []const []const u8, needle: []const u8) bool {
    for (haystack) |item| if (std.mem.eql(u8, item, needle)) return true;
    return false;
}

fn advisory(findings: *Findings, comptime fmt: []const u8, args: anytype) void {
    findings.warnings += 1;
    reporter.detail("  warning: " ++ fmt ++ "\n", args);
}

fn integrity(findings: *Findings, comptime fmt: []const u8, args: anytype) void {
    findings.integrity += 1;
    reporter.detail("  integrity: " ++ fmt ++ "\n", args);
}

// spec: Maintenance - Doctor distinguishes advisory warnings from integrity failures

test "knownCheck accepts live and intentionally retired names" {
    try std.testing.expect(knownCheck("spec"));
    try std.testing.expect(knownCheck("doc-quality"));
    try std.testing.expect(!knownCheck("removed-without-migration"));
}

test "path integration detector ignores the package paths field" {
    try std.testing.expect(!usesPathIntegration(".name = .guardian, .paths = .{ \"src\" }"));
    try std.testing.expect(usesPathIntegration(".guardian = .{ .path = \"../guardian-zig\" }"));
}
