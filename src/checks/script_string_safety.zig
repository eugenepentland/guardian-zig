//! script-string-safety: a JSON/string serializer whose output is embedded
//! verbatim inside an HTML `<script>` element must escape `<`, or a `</script>`
//! sequence in the data terminates the element early — a stored-XSS class.
//!
//! The safe escape is `<` (JavaScript reads `"</script>"` as the text
//! `</script>`, never as a closing tag; JSON accepts the same escape). A plain
//! `application/json` writer legitimately need not do this — the browser never
//! parses a JSON response as HTML — so keying on "any writer missing `<`" is far
//! too broad. Only the consumer knows which serializers actually feed a script
//! blob, so the check is OPT-IN: `[script_string_safety] blob_files` names those
//! files, and an empty list (the default) is a no-op.
//!
//! Inside a listed file the check fires when the file EMITS JSON strings but is
//! not `<`-safe:
//!   * it EMITS JSON strings when it defines a JSON-string escaper — a function
//!     that opens a `"` and escapes both `"` and `\` — OR calls one of the
//!     recognized string-writer helpers (`writeString`, `writeJsonString`,
//!     `writeJsonStr`, `writeEscaped`); and
//!   * it is `<`-safe when it escapes `<` in its own code: a `'<'` escape arm or
//!     the `<` output that arm emits.
//! The delegating case is why a call signal is needed at all: a file whose local
//! escaper does nothing but forward to a shared unsafe writer (the eda power-
//! integrity page does exactly this) has no escape arms of its own to inspect.
//!
//! `<`-safety is deliberately NOT satisfied by merely CALLING the sanctioned
//! `writeScriptString`: a file that routes its live blob strings through that
//! helper while still harboring a latent unsafe escaper (two eda `_json.zig`
//! pages do exactly this) is one refactor away from routing a string through the
//! unsafe one, so the latent escaper is the finding.
//!
//! Comment lines and Zig `test` blocks are blanked before the scan (shared
//! `lexical_scan` machinery), so prose describing the fix and a golden inside a
//! test — the exact place a `</script>` XSS-regression assertion lives —
//! never make an unsafe file read safe.
//!
//! Precision tradeoff: safety is judged per FILE, not per function. A blob file
//! that escapes `<` in ANY function is taken to guard its script output, so a
//! second, unsafe escaper in the same file would be missed. For the eda tree the
//! file-level verdict is exact; per-function granularity is the refinement if a
//! consumer needs it.

const std = @import("std");
const fs = @import("../fs.zig");
const walk = @import("../walk.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const lexical = @import("lexical_scan.zig");

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "script-string-safety";

const fix_hint = "escape `<` as `\\u003c` in this serializer (see json_writer.writeScriptString), " ++
    "or drop the file from [script_string_safety] blob_files if its output never lands in a <script> element.";

/// The `<` escape a script-safe serializer emits. Its presence in the scrubbed
/// (comment- and test-free) source is proof the file guards its script output.
const script_escape = "u003c";

/// The `'<'` character-literal escape arm — the other half of the `<`-safety
/// signal, for a serializer that spells the escape without the `u003c` text.
const lt_arm = "'<'";

/// String-writer helper names whose call means "this file emits JSON strings".
/// A file that only delegates (no local escape arms) is caught by these.
const writer_names = [_][]const u8{ "writeString", "writeJsonString", "writeJsonStr", "writeEscaped" };

/// True when `text` contains a JSON-string escaper's shape: the two character
/// literals every such escaper tests — `'"'` and `'\\'` — regardless of whether
/// it spells them as `switch` arms (`'"' => …`) or an `if (c == '"' or …)`.
fn hasEscaperShape(text: []const u8) bool {
    return std.mem.indexOf(u8, text, "'\"'") != null and std.mem.indexOf(u8, text, "'\\\\'") != null;
}

/// True when `text` calls (or defines) one of the recognized string-writer
/// helpers — the signal that a file emits JSON strings even when it holds no
/// escaper of its own.
fn callsJsonWriter(text: []const u8) bool {
    for (writer_names) |name| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, text, from, name)) |at| : (from = at + 1) {
            const end = at + name.len;
            if (end < text.len and text[end] == '(') return true;
        }
    }
    return false;
}

/// True when `text` escapes `<` in its own code — the `u003c` output or a `'<'`
/// escape arm. Merely CALLING `writeScriptString` is deliberately NOT enough
/// (see the module header): a file can route live strings through it and still
/// hold a latent unsafe escaper.
fn isScriptSafe(text: []const u8) bool {
    return std.mem.indexOf(u8, text, script_escape) != null or
        std.mem.indexOf(u8, text, lt_arm) != null;
}

/// Pure core: at most one violation for a configured blob file — raised when the
/// file emits JSON strings but never makes them `<`-safe. `text` is expected to
/// be already scrubbed of comments and test blocks.
pub fn analyzeFile(allocator: Allocator, rel_path: []const u8, text: []const u8) Allocator.Error!?reporter.Violation {
    if (isScriptSafe(text)) return null;
    const escaper = hasEscaperShape(text);
    if (!escaper and !callsJsonWriter(text)) return null;
    const how = if (escaper)
        "defines a JSON-string escaper that escapes \" and \\ but not <"
    else
        "emits JSON strings through a helper that does not escape <";
    return .{
        .check = check_name,
        .file = rel_path,
        .message = try std.fmt.allocPrint(
            allocator,
            "script blob serializer {s} \u{2014} `</script>` in the data breaks out of the element (stored XSS)",
            .{how},
        ),
        .fix_hint = fix_hint,
        // Identity is the file: a file is safe or it is not, and re-keying that
        // verdict on a reworded message must never re-open a frozen baseline.
        .identity = try std.fmt.allocPrint(allocator, "{s}|{s}", .{ check_name, rel_path }),
    };
}

const ScanCtx = struct {
    allocator: Allocator,
    globs: []const []const u8,
    skip: []const []const u8,
    violations: *std.ArrayList(reporter.Violation),

    /// True when a configured `blob_files` glob names `rel_path`.
    fn wants(self: *const ScanCtx, rel_path: []const u8) bool {
        for (self.globs) |g| {
            if (walk.matchGlob(rel_path, g)) return true;
        }
        return false;
    }
};

/// Reads and scans one file a `blob_files` glob named. A `.zig` file is parsed
/// so its test blocks are blanked alongside its comments; any other extension
/// gets comment-only scrubbing.
fn scanFile(ctx: *ScanCtx, dir: fs.Dir, name: []const u8, rel_path: []const u8) !void {
    if (!ctx.wants(rel_path) or lexical.selfExempt(rel_path) or lexical.skipPath(ctx.skip, rel_path)) return;
    const content = try dir.readFileAlloc(ctx.allocator, name, lexical.read_limit);
    const scrubbed = if (std.mem.endsWith(u8, rel_path, ".zig")) blk: {
        const source = try ctx.allocator.dupeSentinel(u8, content, 0);
        var tree = try Ast.parse(ctx.allocator, source, .{});
        break :blk try lexical.scrubbed(ctx.allocator, rel_path, source, &tree);
    } else try lexical.scrubbed(ctx.allocator, rel_path, content, null);
    if (try analyzeFile(ctx.allocator, rel_path, scrubbed)) |v| {
        try ctx.violations.append(ctx.allocator, v);
    }
}

fn visit(raw_ctx: *anyopaque, dir: fs.Dir, name: []const u8, rel_path: []const u8) walk.WalkError!void {
    const ctx: *ScanCtx = @ptrCast(@alignCast(raw_ctx));
    try scanFile(ctx, dir, name, rel_path);
}

/// Entry point for script-string-safety (opt-in: `[script_string_safety]
/// blob_files`).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const globs = ctx_param.cfg.script_string_safety.blob_files;
    if (globs.len == 0) {
        reporter.ok("script-string-safety: no blob_files configured (opt-in via [script_string_safety] blob_files)", .{});
        return;
    }
    var found: std.ArrayList(reporter.Violation) = .empty;
    const skip = try std.mem.concat(allocator, []const u8, &.{
        ctx_param.cfg.extraAllowed(check_name),
        ctx_param.cfg.exclude,
    });
    var scan_ctx: ScanCtx = .{ .allocator = allocator, .globs = globs, .skip = skip, .violations = &found };
    var root = try fs.cwd().openDir(ctx_param.project_dir, .{ .iterate = true });
    defer root.close();
    try lexical.walkFiles(allocator, root, "", .{ .ctx = &scan_ctx, .visit = visit });

    if (found.items.len == 0) {
        reporter.ok("script-string-safety: all configured blob serializers escape < ({d} glob(s))", .{globs.len});
        return;
    }
    reporter.fail("script-string-safety FAILED ({d} unsafe blob serializer(s))", .{found.items.len});
    for (found.items) |v| reporter.emitQuiet(v);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

// spec: Script String Safety - Flags a script-blob escaper that escapes quote and backslash but not <

test "script-string-safety: analyzeFile flags a switch escaper that omits the < arm" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn writeJsonString(w: *Writer, value: []const u8) !void {
        \\    try w.writeByte('"');
        \\    for (value) |c| switch (c) {
        \\        '"' => try w.writeAll("\\\""),
        \\        '\\' => try w.writeAll("\\\\"),
        \\        else => try w.writeByte(c),
        \\    };
        \\}
    ;
    const out = (try analyzeFile(a, "src/serve/pcb_part_json.zig", src)).?;
    try testing.expectEqualStrings(check_name, out.check);
    try testing.expectEqualStrings("script-string-safety|src/serve/pcb_part_json.zig", out.identity.?);
    try testing.expect(std.mem.indexOf(u8, out.message, "escaper") != null);
}

// spec: Script String Safety - Flags an if-form escaper that omits the < arm

test "script-string-safety: analyzeFile flags an if-condition escaper missing <" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn writeJsonStr(w: *Writer, s: []const u8) !void {
        \\    try w.writeByte('"');
        \\    for (s) |c| {
        \\        if (c == '"' or c == '\\') try w.writeByte('\\');
        \\        try w.writeByte(c);
        \\    }
        \\}
    ;
    try testing.expect((try analyzeFile(a, "src/serve/layer_table_json.zig", src)) != null);
}

// spec: Script String Safety - Flags a file that emits JSON strings only through an unsafe helper

test "script-string-safety: analyzeFile flags a delegating file with no local escape arms" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // No `'"'` / `'\\'` arms of its own — it forwards to a shared writer that is
    // itself unsafe. The call signal is what catches it.
    const src =
        \\fn writeRow(w: *Writer, net: Net) !void {
        \\    try writeString(w, net.name);
        \\}
    ;
    const out = (try analyzeFile(a, "src/power_integrity_json.zig", src)).?;
    try testing.expect(std.mem.indexOf(u8, out.message, "helper") != null);
}

// spec: Script String Safety - Passes a serializer that escapes < as u003c

test "script-string-safety: analyzeFile passes an escaper that encodes <" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn writeJsonStr(w: *Writer, s: []const u8) !void {
        \\    try w.writeByte('"');
        \\    for (s) |c| switch (c) {
        \\        '"' => try w.writeAll("\\\""),
        \\        '\\' => try w.writeAll("\\\\"),
        \\        '<' => try w.writeAll("\\u003c"),
        \\        else => try w.writeByte(c),
        \\    };
        \\}
    ;
    try testing.expect((try analyzeFile(a, "src/serve/pcb_rules_json.zig", src)) == null);
}

// spec: Script String Safety - Passes a file that routes strings through writeScriptString

test "script-string-safety: analyzeFile passes a file delegating to writeScriptString" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn writeRow(w: *Writer, net: Net) !void {
        \\    try json_writer.writeScriptString(w, net.name);
        \\}
    ;
    try testing.expect((try analyzeFile(a, "src/some_blob.zig", src)) == null);
}

// spec: Script String Safety - Ignores a file that emits no JSON strings at all

test "script-string-safety: analyzeFile ignores a file with neither an escaper nor a writer call" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\fn add(x: u32, y: u32) u32 {
        \\    return x + y;
        \\}
    ;
    try testing.expect((try analyzeFile(a, "src/serve/math.zig", src)) == null);
}
