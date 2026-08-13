//! duplicate-json-key: one function writing the same JSON key twice into the
//! same object.
//!
//! The motivating case (eda, 2026-08): one serializer emitted
//! `"pour_min_width"` and `"pour_corner_radius"` twice into a single `"rules"`
//! object, from two `w.print` format strings fourteen lines apart. `JSON.parse`
//! takes the last one, so today it is silently last-wins — and the moment that
//! blob becomes a module, or is read by a strict parser, it is a SyntaxError.
//! Nothing in the file looks wrong; the two writes are simply far enough apart
//! that no reader holds both in their head.
//!
//! **Scoping is where the precision lives.** A naive per-function rule
//! false-positives on any function writing two sibling objects — `{"a":1}` then
//! `{"a":2}` is perfectly good JSON. So the check tracks OBJECT SEGMENTS: a key
//! is only a duplicate of an earlier key when nothing between them could have
//! closed the object, opened another, or made the two writes alternatives.
//! Four things break a segment:
//!
//!   * a `{` or `}` a string literal actually emits, including the `{{` / `}}`
//!     escapes of a format string,
//!   * a completed call between two literals — a write this check cannot see
//!     inside (`try writeNested(w)`), so what it emitted is unknown,
//!   * control flow diverging between them — an `else`, a switch prong's `=>`,
//!     or a `return`/`break`/`continue`: only ONE of two alternatives ever
//!     runs, so `if (v) |x| print(",\"voltage\":{d}") else
//!     writeAll(",\"voltage\":null")` is one key, written once,
//!   * anything else ambiguous, which is always resolved toward suppression.
//!
//! A literal also has to BE a write. Its enclosing call's name must read like
//! one (`print`, `writeAll`, `allocPrint`, `append`), because a JSON key
//! fragment appears in plenty of code that emits nothing —
//! `std.mem.indexOf(u8, body, "\"dnp\":true")` inspects a REQUEST, and two of
//! those in one `or` chain are not a duplicated key.
//!
//! A format PLACEHOLDER (`{d}`, `{s}`, `{d:.3}`) is deliberately not a brace:
//! it writes one complete value, which is brace-balanced or the JSON was
//! already invalid. That is the whole reason the motivating case is reachable —
//! `\"pour_min_width\":{d},` has a `{` between the two keys and it means
//! nothing structurally.
//!
//! The cost of that conservatism is recall: a duplicate separated by a helper
//! call, or built through a writer this check does not recognise by name, is
//! not reported. That is the intended direction — a check that false-positives
//! on valid serializers gets turned off, and then it catches nothing at all.
//! Measured on eda before these two rules existed: 19 findings, of which 4 were
//! real; after them, the real ones remain and the branch/read cases are gone.

const std = @import("std");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");
const ast_index = @import("../ast/index.zig");
const ast_decls = @import("../ast/decls.zig");
const LineCursor = @import("../text.zig").LineCursor;

const Allocator = std.mem.Allocator;
const Ast = std.zig.Ast;

const check_name = "duplicate-json-key";

/// Longest format spec read as a placeholder (`{d}`, `{d:.3}`, `{[name]s}`).
/// Past this, a `{` is treated as a real brace — the conservative reading.
const max_format_spec_len = 16;

/// Paren nesting tracked while looking for a completed call between two
/// literals. Deeper than this the check gives up and calls it a barrier.
const max_paren_depth = 64;

/// How far back from a literal the enclosing call's name is looked for. An
/// argument list is a handful of tokens; past this the literal is treated as
/// not being a write, which is the quiet side.
const max_callee_lookback = 64;

/// Stems that make an enclosing call a WRITE. Matched case-insensitively as a
/// substring, so `print`, `writeAll`, `allocPrint`, `bufPrint`, `writeString`
/// and `appendSlice` all qualify while `indexOf`, `eql` and `startsWith` do
/// not.
const write_stems = [_][]const u8{ "print", "write", "format", "append" };

const fix_hint = "write the key once — the second write silently wins today and " ++
    "is a parse error under any strict JSON reader.";

// ── Reading one string literal ──────────────────────────────────────────

/// One JSON key found in a literal, and where the scan continues.
const KeyHit = struct {
    name: []const u8,
    end: usize,
};

/// True for the bytes a JSON object key is spelled with here. Deliberately
/// narrow: a key with a space or a quote in it is not the machine-generated
/// shape this check is about.
fn isKeyByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c == '-' or c == '.';
}

/// The length of the quote at `at`: 2 for the `\"` of a Zig string literal, 1
/// for the bare `"` of a `\\` multiline line, 0 when there is no quote.
fn quoteLen(text: []const u8, at: usize) usize {
    if (at < text.len and text[at] == '"') return 1;
    if (at + 1 < text.len and text[at] == '\\' and text[at + 1] == '"') return 2;
    return 0;
}

/// Reads a `"<key>":` fragment starting at `at`, in either the escaped form a
/// Zig string literal carries or the bare form a multiline line does. Null when
/// the text at `at` is not a key.
fn keyAt(text: []const u8, at: usize) ?KeyHit {
    const open = quoteLen(text, at);
    if (open == 0) return null;
    var i = at + open;
    const name_start = i;
    while (i < text.len and isKeyByte(text[i])) i += 1;
    if (i == name_start) return null;
    const close = quoteLen(text, i);
    if (close != open) return null;
    const colon = i + close;
    if (colon >= text.len or text[colon] != ':') return null;
    return .{ .name = text[name_start..i], .end = colon + 1 };
}

/// True for a byte that may appear inside a format placeholder's spec.
fn isSpecByte(c: u8) bool {
    if (std.ascii.isAlphanumeric(c)) return true;
    return std.mem.indexOfScalar(u8, "_:.<>^*?+-[]", c) != null;
}

/// The offset just past a format placeholder starting at `at`, or null when
/// that `{` is a real brace — including the `{{` escape, whose second `{` is
/// not a spec byte.
fn placeholderEnd(text: []const u8, at: usize) ?usize {
    var i = at + 1;
    const limit = @min(text.len, at + 1 + max_format_spec_len);
    while (i < limit) : (i += 1) {
        if (text[i] == '}') return i + 1;
        if (!isSpecByte(text[i])) return null;
    }
    return null;
}

// ── Segment tracking ────────────────────────────────────────────────────

/// Where a key was last written: which object segment was open, and on which
/// source line.
const LastWrite = struct {
    segment: u32,
    line: u32,
};

/// One function's (or one declaration's) accumulating view: the segment counter,
/// what each key last did, and the keys already reported here.
const OwnerScan = struct {
    allocator: Allocator,
    file: []const u8,
    owner: []const u8,
    segment: u32 = 0,
    last: std.StringHashMapUnmanaged(LastWrite) = .empty,
    reported: std.StringHashMapUnmanaged(void) = .empty,
    out: *std.ArrayList(reporter.Violation),

    /// Ends the current object segment: everything after this is provably not
    /// inside the object everything before it was.
    fn barrier(self: *OwnerScan) void {
        self.segment += 1;
    }

    /// Records one key write, reporting it when the same key was already
    /// written into the segment still open.
    fn write(self: *OwnerScan, name: []const u8, line: u32) Allocator.Error!void {
        const gop = try self.last.getOrPut(self.allocator, name);
        const duplicate = gop.found_existing and gop.value_ptr.segment == self.segment;
        const first_line = if (gop.found_existing) gop.value_ptr.line else line;
        gop.value_ptr.* = .{ .segment = self.segment, .line = line };
        if (!duplicate) return;
        if ((try self.reported.getOrPut(self.allocator, name)).found_existing) return;
        try self.out.append(self.allocator, try self.violation(name, first_line, line));
    }

    /// Builds the violation for one duplicated key.
    fn violation(self: *OwnerScan, name: []const u8, first: u32, second: u32) Allocator.Error!reporter.Violation {
        const message = try std.fmt.allocPrint(
            self.allocator,
            "{s} writes JSON key \"{s}\" twice into the same object (lines {d} and {d})",
            .{ self.owner, name, first, second },
        );
        // Identity is file, owner and KEY — never the line pair, which moves
        // whenever anything above the serializer does.
        const identity = try std.fmt.allocPrint(
            self.allocator,
            "{s}|{s}|{s}",
            .{ self.file, self.owner, name },
        );
        return .{
            .check = check_name,
            .file = self.file,
            .line = second,
            .message = message,
            .fix_hint = fix_hint,
            .identity = identity,
        };
    }
};

/// Feeds one literal's text through the segment tracker: keys are writes,
/// emitted braces are barriers, format placeholders are neither.
fn scanLiteral(scan: *OwnerScan, text: []const u8, line: u32) Allocator.Error!void {
    var i: usize = 0;
    while (i < text.len) {
        if (text[i] == '{') {
            if (placeholderEnd(text, i)) |end| {
                i = end;
                continue;
            }
            scan.barrier();
            i += 1;
            continue;
        }
        if (text[i] == '}') {
            scan.barrier();
            i += 1;
            continue;
        }
        if (keyAt(text, i)) |hit| {
            try scan.write(hit.name, line);
            i = hit.end;
            continue;
        }
        i += 1;
    }
}

// ── Walking one owner's tokens ──────────────────────────────────────────

/// True when a completed call sits between two literal tokens — a write whose
/// emitted text this check cannot see. Depth past `max_paren_depth` reports
/// true as well, since an unknown nesting is exactly the case to suppress.
fn callBetween(tree: *const Ast, from: u32, to: u32) bool {
    var is_call: [max_paren_depth]bool = @splat(false);
    var depth: usize = 0;
    var tok = from;
    while (tok < to) : (tok += 1) {
        switch (tree.tokenTag(tok)) {
            .l_paren => {
                if (depth == max_paren_depth) return true;
                is_call[depth] = tok > 0 and opensCall(tree.tokenTag(tok - 1));
                depth += 1;
            },
            .r_paren => {
                if (depth == 0) continue;
                depth -= 1;
                if (is_call[depth]) return true;
            },
            else => {},
        }
    }
    return false;
}

/// True when a token before a `(` makes it a call rather than a grouping or a
/// control-flow condition.
fn opensCall(prev: std.zig.Token.Tag) bool {
    return prev == .identifier or prev == .builtin;
}

/// True when control flow diverges between two literals, so the second write is
/// not provably a later step of the same sequence: an `else` (including the
/// one-line `if (x) a else b` form), a switch prong's `=>`, or a `return` /
/// `break` / `continue` — the early-out shape
/// `if (x) return w.writeAll(",\"authored\":false"); try w.writeAll(",\"authored\":true")`
/// writes one key once, on two different paths.
fn divergesBetween(tree: *const Ast, from: u32, to: u32) bool {
    var tok = from;
    while (tok < to) : (tok += 1) {
        switch (tree.tokenTag(tok)) {
            .keyword_else,
            .equal_angle_bracket_right,
            .keyword_return,
            .keyword_break,
            .keyword_continue,
            => return true,
            else => {},
        }
    }
    return false;
}

/// True when what stands between two literals means the second is not provably
/// a later write into the same still-open object.
fn separated(tree: *const Ast, from: u32, to: u32) bool {
    return callBetween(tree, from, to) or divergesBetween(tree, from, to);
}

/// True when the statement writing this literal ENDS the path —
/// `return w.writeAll(",\"authored\":false");`. The divergence keyword sits
/// BEFORE the write, so scanning the gap after it would never see one; the
/// segment has to break on the far side of the literal instead.
fn endsPath(tree: *const Ast, literal: u32, floor: u32) bool {
    var tok = literal;
    while (tok > floor) {
        tok -= 1;
        switch (tree.tokenTag(tok)) {
            .semicolon, .l_brace, .r_brace => return false,
            .keyword_return, .keyword_break, .keyword_continue => return true,
            else => {},
        }
    }
    return false;
}

/// The name of the call a literal is an argument to, or null when it is not
/// inside one within `max_callee_lookback` tokens. The search walks back to the
/// nearest unmatched `(` and reads the identifier in front of it.
fn enclosingCallee(tree: *const Ast, literal: u32, floor: u32) ?[]const u8 {
    var depth: usize = 0;
    var tok = literal;
    const stop = if (literal > floor + max_callee_lookback) literal - max_callee_lookback else floor;
    while (tok > stop) {
        tok -= 1;
        switch (tree.tokenTag(tok)) {
            .r_paren => depth += 1,
            .l_paren => {
                if (depth > 0) {
                    depth -= 1;
                    continue;
                }
                if (tok == 0 or tree.tokenTag(tok - 1) != .identifier) return null;
                return tree.tokenSlice(tok - 1);
            },
            else => {},
        }
    }
    return null;
}

/// True when a literal is an argument to a call that writes output. A key
/// fragment in a call that READS (`std.mem.indexOf(u8, body, "\"dnp\":true")`)
/// emits nothing, so two of them are not a duplicated key.
fn isWrite(tree: *const Ast, literal: u32, floor: u32) bool {
    const callee = enclosingCallee(tree, literal, floor) orelse return false;
    for (write_stems) |stem| {
        if (containsIgnoreCase(callee, stem)) return true;
    }
    return false;
}

/// True when `needle` appears in `haystack`, ignoring ASCII case.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.startsWithIgnoreCase(haystack[i..], needle)) return true;
    }
    return false;
}

/// True for the two literal token kinds a JSON key can be written in.
fn isLiteral(tag: std.zig.Token.Tag) bool {
    return tag == .string_literal or tag == .multiline_string_literal_line;
}

/// One declaration whose body is scanned as a unit — a function, or a
/// file-scope const holding a literal. A container declaration is never an
/// owner: its members are owners of their own, so scanning it too would report
/// every finding twice.
const Owner = struct {
    name: []const u8,
    first: u32,
    last: u32,
};

/// Scans one owner's token range, running the segment tracker over every
/// literal and inserting a barrier for each unreadable write between them.
fn scanOwner(
    scan: *OwnerScan,
    tree: *const Ast,
    owner: Owner,
    cursor: *LineCursor,
    content: []const u8,
) Allocator.Error!void {
    var prev_literal: ?u32 = null;
    var tok = owner.first;
    while (tok <= owner.last) : (tok += 1) {
        if (!isLiteral(tree.tokenTag(tok))) continue;
        if (!isWrite(tree, tok, owner.first)) continue;
        if (prev_literal) |prev| {
            if (separated(tree, prev + 1, tok)) scan.barrier();
        }
        const start = tree.tokenStart(tok);
        try scanLiteral(scan, tree.tokenSlice(tok), cursor.at(content, start));
        if (endsPath(tree, tok, owner.first)) scan.barrier();
        prev_literal = tok;
    }
}

/// The declarations scanned as owners, in source order. Test blocks are absent
/// by construction (they are not declarations), which is what keeps a test's
/// own JSON fixtures out of the check.
fn collectOwners(allocator: Allocator, tree: *const Ast) Allocator.Error![]const Owner {
    var out: std.ArrayList(Owner) = .empty;
    for (try ast_decls.collectDecls(allocator, tree)) |node| {
        const name = ownerName(tree, node) orelse continue;
        try out.append(allocator, .{
            .name = name,
            .first = tree.firstToken(node),
            .last = tree.lastToken(node),
        });
    }
    const owners = try out.toOwnedSlice(allocator);
    std.mem.sort(Owner, owners, {}, byFirstToken);
    return owners;
}

/// Orders owners by their first token so one forward-only line cursor covers
/// the whole file.
fn byFirstToken(_: void, a: Owner, b: Owner) bool {
    return a.first < b.first;
}

/// The name a declaration is reported under, or null when it is not an owner:
/// a function's name, or a non-container declaration's name.
fn ownerName(tree: *const Ast, node: Ast.Node.Index) ?[]const u8 {
    var buf: [1]Ast.Node.Index = undefined;
    if (tree.fullFnProto(&buf, node)) |proto| {
        const tok = proto.name_token orelse return null;
        return tree.tokenSlice(tok);
    }
    const var_decl = tree.fullVarDecl(node) orelse return null;
    const init_node = var_decl.ast.init_node.unwrap() orelse return null;
    if (ast_decls.isContainerNode(tree, init_node)) return null;
    return tree.tokenSlice(var_decl.ast.mut_token + 1);
}

// ── Entry points ────────────────────────────────────────────────────────

/// Pure core: every duplicated JSON key in one parsed file.
pub fn analyzeFile(
    allocator: Allocator,
    entry: *const ast_index.Entry,
) Allocator.Error![]const reporter.Violation {
    const tree = &entry.tree;
    var out: std.ArrayList(reporter.Violation) = .empty;
    var cursor: LineCursor = .{};
    for (try collectOwners(allocator, tree)) |owner| {
        var scan: OwnerScan = .{
            .allocator = allocator,
            .file = entry.rel_path,
            .owner = owner.name,
            .out = &out,
        };
        try scanOwner(&scan, tree, owner, &cursor, entry.content);
    }
    return out.toOwnedSlice(allocator);
}

/// Entry point for the duplicate-json-key check.
pub fn run(ctx: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx.allocator;
    var storage: ast_index.Index = undefined;
    const idx = try ast_index.resolve(ctx.source_index, allocator, ctx.project_dir, &storage);
    var found: std.ArrayList(reporter.Violation) = .empty;
    for (idx.files) |*entry| {
        try found.appendSlice(allocator, try analyzeFile(allocator, entry));
    }
    if (found.items.len == 0) {
        reporter.ok("duplicate-json-key: no key written twice into one object", .{});
        return;
    }
    reporter.fail("duplicate-json-key FAILED ({d} key(s))", .{found.items.len});
    for (found.items) |violation| reporter.emitQuiet(violation);
    reporter.detail("  fix: {s}\n", .{fix_hint});
    return error.CheckFailed;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// Parses one in-test source string and runs the pure core over it.
fn analyzeSource(a: Allocator, source: [:0]const u8) ![]const reporter.Violation {
    const entry: ast_index.Entry = .{
        .rel_path = "src/serialize.zig",
        .content = source,
        .tree = try Ast.parse(a, source, .{}),
    };
    return analyzeFile(a, &entry);
}

// spec: Duplicate JSON Key - Flags one key written twice by two prints into one open object

test "analyzeFile flags the two-print duplicate the motivating case has" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The shape measured in eda: an object opened with `{{`, a key written in
    // one print, unrelated prints between, the same key again — no structural
    // brace anywhere between the two writes.
    const out = try analyzeSource(a,
        \\fn writeBlobHead(w: *W, dr: Rules) !void {
        \\    try w.print("{{\"rules\":{{\"min_width\":{d},\"pour_min_width\":{d},", .{ dr.a, dr.b });
        \\    try w.print("\"component_edge\":{d},", .{dr.c});
        \\    try w.print("\"pour_min_width\":{d},\"via_dia\":{d}}}", .{ dr.b, dr.d });
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/serialize.zig|writeBlobHead|pour_min_width", out[0].identity.?);
    try testing.expectEqualStrings(
        "src/serialize.zig:4: writeBlobHead writes JSON key \"pour_min_width\" twice " ++
            "into the same object (lines 2 and 4)",
        try reporter.flatLine(a, out[0]),
    );
}

// spec: Duplicate JSON Key - Flags one key written twice inside a single literal

test "analyzeFile flags a duplicate inside one literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\fn emit(w: *W) !void {
        \\    try w.writeAll("\"a\":1,\"b\":2,\"a\":3");
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
    try testing.expectEqualStrings("src/serialize.zig|emit|a", out[0].identity.?);
}

// spec: Duplicate JSON Key - Ignores the same key in two sibling objects

test "analyzeFile ignores a key repeated across sibling objects" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The `}}`/`{{` between the two writes closes one object and opens another,
    // which is the shape a naive per-function rule reports and this one must not.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W) !void {
        \\    try w.print("{{\"pos\":{{\"x\":{d}}},", .{1});
        \\    try w.print("\"size\":{{\"x\":{d}}}}}", .{2});
        \\}
        \\
    )).len);
    // And a nested object inside ONE literal is the same case.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W) !void {
        \\    try w.writeAll("{\"a\":1,\"b\":{\"a\":2}}");
        \\}
        \\
    )).len);
}

// spec: Duplicate JSON Key - Suppresses a duplicate separated by a call it cannot read

test "analyzeFile suppresses a duplicate across an unreadable write" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // `writeNested` may have opened an object, so the second `a` is not provably
    // in the first one's object.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W, v: V) !void {
        \\    try w.writeAll("\"a\":1,");
        \\    try writeNested(w, v);
        \\    try w.writeAll("\"a\":2,");
        \\}
        \\
    )).len);
}

// spec: Duplicate JSON Key - Ignores two branches of one conditional writing the same key

test "analyzeFile ignores alternatives that only one branch runs" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The measured false positive: one key, written once, spelled twice because
    // its value has a null form.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W, p: P) !void {
        \\    if (p.voltage) |v| try w.print(",\"voltage\":{d}", .{v}) else try w.writeAll(",\"voltage\":null");
        \\}
        \\
    )).len);
    // A switch prong is the same shape.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W, k: K) !void {
        \\    switch (k) {
        \\        .a => try w.writeAll("\"kind\":\"a\","),
        \\        .b => try w.writeAll("\"kind\":\"b\","),
        \\    }
        \\}
        \\
    )).len);
    // So is an early return, which is how a null variant is usually written.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn emit(w: *W, lp: L) !void {
        \\    if (lp.pin.len == 0) return w.writeAll(",\"authored\":false");
        \\    try w.writeAll(",\"authored\":true,\"pin\":");
        \\}
        \\
    )).len);
}

// spec: Duplicate JSON Key - Ignores a key fragment in a call that reads rather than writes

test "analyzeFile only reads literals that are written out" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Inspecting a request body for a key emits nothing, so two of them in one
    // `or` chain are not a duplicated key.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn wants(body: []const u8) bool {
        \\    return std.mem.indexOf(u8, body, "\"dnp\":true") != null or
        \\        std.mem.indexOf(u8, body, "\"dnp\": true") != null;
        \\}
        \\
    )).len);
    // The same two fragments handed to a writer are a duplicate.
    try testing.expectEqual(@as(usize, 1), (try analyzeSource(a,
        \\fn emit(w: *W) !void {
        \\    try w.writeAll("\"dnp\":true,");
        \\    try w.writeAll("\"dnp\":false,");
        \\}
        \\
    )).len);
}

// spec: Duplicate JSON Key - Names the enclosing call a literal is written by

test "enclosingCallee reads back through the argument list" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tree = try Ast.parse(a,
        \\fn emit(w: *W) !void {
        \\    try w.print("\"a\":{d}", .{sum(1, 2)});
        \\    const raw = "\"b\":1";
        \\}
        \\
    , .{});
    const first = firstLiteralToken(&tree, 0).?;
    try testing.expectEqualStrings("print", enclosingCallee(&tree, first, 0).?);
    try testing.expect(isWrite(&tree, first, 0));
    // A literal bound to a const is not inside a call at all.
    const second = firstLiteralToken(&tree, first + 1).?;
    try testing.expect(enclosingCallee(&tree, second, 0) == null);
    // The stem match is case-insensitive and covers the usual writer names.
    try testing.expect(containsIgnoreCase("allocPrint", "print"));
    try testing.expect(!containsIgnoreCase("indexOf", "write"));
}

// spec: Duplicate JSON Key - Treats a format placeholder as a value rather than a brace

test "placeholderEnd separates a format spec from an emitted brace" {
    // A placeholder is a value: it neither opens nor closes an object.
    try testing.expectEqual(@as(?usize, 3), placeholderEnd("{d}", 0));
    try testing.expectEqual(@as(?usize, 6), placeholderEnd("{d:.3}x", 0));
    try testing.expectEqual(@as(?usize, 2), placeholderEnd("{}", 0));
    // `{{` is an emitted brace, and so is a `{` opening real JSON content.
    try testing.expect(placeholderEnd("{{", 0) == null);
    try testing.expect(placeholderEnd("{\\\"a\\\":1}", 0) == null);
    // A run too long to be a spec is read as a brace, the conservative side.
    try testing.expect(placeholderEnd("{aaaaaaaaaaaaaaaaaaaa}", 0) == null);
}

// spec: Duplicate JSON Key - Reads a key in both the escaped and multiline literal forms

test "keyAt reads both literal spellings and rejects non-keys" {
    try testing.expectEqualStrings("pour_min_width", keyAt("\\\"pour_min_width\\\":1", 0).?.name);
    try testing.expectEqualStrings("a-b.c", keyAt("\"a-b.c\":1", 0).?.name);
    // Mismatched quoting, an empty key, and a quoted value are not keys.
    try testing.expect(keyAt("\"mixed\\\":1", 0) == null);
    try testing.expect(keyAt("\"\":1", 0) == null);
    try testing.expect(keyAt("\"value\",", 0) == null);
}

// spec: Duplicate JSON Key - Keeps two functions' keys apart

test "analyzeFile scopes a segment to one declaration" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The same key written by two functions is two objects, whatever the
    // brace bookkeeping in either says.
    try testing.expectEqual(@as(usize, 0), (try analyzeSource(a,
        \\fn head(w: *W) !void {
        \\    try w.writeAll("\"a\":1,");
        \\}
        \\fn tail(w: *W) !void {
        \\    try w.writeAll("\"a\":2,");
        \\}
        \\
    )).len);
}

// spec: Duplicate JSON Key - Reports a repeatedly duplicated key once per function

test "analyzeFile reports one violation for a key written three times" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = try analyzeSource(a,
        \\fn emit(w: *W) !void {
        \\    try w.writeAll("\"a\":1,\"a\":2,\"a\":3");
        \\}
        \\
    );
    try testing.expectEqual(@as(usize, 1), out.len);
}

// spec: Duplicate JSON Key - Names a completed call between two literals as unreadable

test "callBetween sees a finished call but not the one wrapping a literal" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const source: [:0]const u8 =
        \\fn emit(w: *W) !void {
        \\    try w.print("a", .{});
        \\    try w.print("b", .{});
        \\}
        \\
    ;
    var tree = try Ast.parse(a, source, .{});
    const first = firstLiteralToken(&tree, 0).?;
    const second = firstLiteralToken(&tree, first + 1).?;
    // Between the two literals lies the FIRST print's closing `)` — but its `(`
    // opened before the literal, so no call completed in the gap.
    try testing.expect(!callBetween(&tree, first + 1, second));
    // A whole call in the gap is the unreadable write.
    var nested = try Ast.parse(a,
        \\fn emit(w: *W) !void {
        \\    try w.writeAll("a");
        \\    try writeNested(w);
        \\    try w.writeAll("b");
        \\}
        \\
    , .{});
    const a1 = firstLiteralToken(&nested, 0).?;
    const b1 = firstLiteralToken(&nested, a1 + 1).?;
    try testing.expect(callBetween(&nested, a1 + 1, b1));
}

/// The first string-literal token at or after `from`, for the token-level tests.
fn firstLiteralToken(tree: *const Ast, from: u32) ?u32 {
    var tok = from;
    while (tok < tree.tokens.len) : (tok += 1) {
        if (isLiteral(tree.tokenTag(tok))) return tok;
    }
    return null;
}
