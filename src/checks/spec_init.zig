const std = @import("std");
const spec_init = @import("../spec/init.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const print = std.debug.print;
const ok = reporter.ok;
const fail = reporter.fail;

/// Entry point for the spec-init generator.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    const project_dir = ctx.project_dir;
    // Honor the configured spec file so `spec_file = "docs/SPEC.md"` projects
    // get the starter file where the coverage check will actually read it.
    const spec_file = ctx.cfg.spec_file;
    const spec_path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, spec_file });

    if (std.fs.cwd().access(spec_path, .{})) |_| {
        fail("{s} already exists — refusing to overwrite", .{spec_file});
        print("  Delete it first if you want to regenerate.\n", .{});
        std.process.exit(1);
    } else |_| {}

    const src_path = try std.fmt.allocPrint(allocator, "{s}/src", .{project_dir});
    var modules: std.ArrayListUnmanaged(spec_init.ModuleInfo) = .empty;
    try spec_init.collectModules(allocator, src_path, "", &modules);

    if (modules.items.len == 0) {
        fail("no pub fn declarations found in src/", .{});
        std.process.exit(1);
    }

    const content = try spec_init.generateSpecContent(allocator, modules.items);
    const file = std.fs.cwd().createFile(spec_path, .{}) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };
    defer file.close();
    file.writeAll(content) catch {
        fail("failed to write {s}", .{spec_path});
        std.process.exit(1);
    };

    var total_fns: usize = 0;
    for (modules.items) |m| total_fns += m.pub_fns.len;
    ok("generated {s} with {d} modules, {d} behavior placeholders", .{ spec_path, modules.items.len, total_fns });
    print("  Each pub fn got its own bullet — refine the wording, then add a matching\n", .{});
    print("  // spec: <Section> - <Behavior> tag to a test for each one.\n", .{});
}
