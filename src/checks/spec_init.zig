const std = @import("std");
const spec_init = @import("../spec/init.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/registry.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

// spec: Spec Lifecycle - Generates starter SPEC.md from pub fn signatures via spec-init

pub fn run(ctx: *registry.RunCtx) !void {
    const allocator = ctx.allocator;
    const project_dir = ctx.project_dir;
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/SPEC.md", .{project_dir});

    if (std.fs.cwd().access(spec_path, .{})) |_| {
        fail("SPEC.md already exists — refusing to overwrite", .{});
        print("  Delete it first if you want to regenerate.\n", .{});
        std.process.exit(1);
    } else |_| {}

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var modules: std.ArrayListUnmanaged(spec_init.ModuleInfo) = .empty;
    spec_init.collectModules(allocator, src_path, "", &modules) catch {};

    if (modules.items.len == 0) {
        fail("no pub fn declarations found in src/", .{});
        std.process.exit(1);
    }

    const content = spec_init.generateSpecContent(allocator, modules.items);
    const file = std.fs.cwd().createFile(spec_path, .{}) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(content) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };

    ok("generated {s} with {d} modules", .{ spec_path, modules.items.len });
    print("  Edit the generated behaviors, then add // spec: tags to your tests.\n", .{});
}
