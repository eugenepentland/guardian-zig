//! concurrency-test-presence: a file declared concurrency-critical must carry a
//! test that actually spawns a second unit of execution.
//!
//! A codebase can hold a mutex, a lock table, or a rev guard and still have zero
//! evidence that it serializes anything. In the consumer that motivated this (an
//! EDA tool), a layout-sidecar rev guard was a lockless check-then-write for its
//! whole life: two saves that both read `rev=5` both passed the guard, both
//! wrote `rev=6`, and one was silently lost. A lock was added — but "a lock
//! exists" is not "the lock is exercised".
//!
//! Whether a lock actually prevents a lost update is a RUNTIME property no
//! static check can decide. What a static check CAN do is refuse to let a file
//! declared as concurrency-critical carry no concurrency test at all. That is
//! exactly `fuzz-presence`'s bargain for untrusted parsers, applied to shared
//! mutable state: the project names the files, and the gate holds the harness in
//! place across refactors.
//!
//! What counts as a spawn is deliberately narrow (see `isSpawnSite`): only a
//! spelling that yields a real second unit of execution. Declaring or taking a
//! lock never counts — a lock is the thing whose presence proves nothing, and
//! crediting it would make the check tautological.
//!
//! Reachability, not brace position: a spawn inside a `test { ... }` body counts,
//! and so does one inside a file-local function a test body calls. Guardian's own
//! `test-no-conditional` pushes the `for (&threads) |t| t.join()` loop OUT of the
//! test body and into a helper, so an in-test-braces-only rule would red the
//! files that write the best concurrency tests. A spawn reached from no test is
//! production code and never counts.

const std = @import("std");
const fs = @import("../fs.zig");
const text = @import("../text.zig");
const reporter = @import("../reporter.zig");
const registry = @import("../cli/types.zig");

const Allocator = std.mem.Allocator;
const print = reporter.detail;
const ok = reporter.ok;
const fail = reporter.fail;

const read_limit = 4 * 1024 * 1024;

/// One configured module paired with the source Guardian read for it. `content`
/// is null when the file was missing or unreadable — a fail-closed hard error,
/// not a silent skip, so a stale entry can't quietly pass the gate.
const ModuleSource = struct {
    path: []const u8,
    content: ?[]const u8,
};

/// A call edge inside one file: `caller` is the enclosing function's name,
/// `callee` the identifier it calls. Names only — this is a token-level
/// approximation of the file-local call graph, not a resolved one.
const Edge = struct {
    caller: []const u8,
    callee: []const u8,
};

/// What one file's token stream said about concurrency.
const Scan = struct {
    /// A spawn spelling appeared directly inside a `test { ... }` body.
    spawn_in_test: bool = false,
    /// Functions whose body carries a spawn spelling outside any test body.
    spawners: []const []const u8 = &.{},
    /// Identifiers called from inside a test body — the reachability roots.
    test_calls: []const []const u8 = &.{},
    /// Call edges between the file's own functions, outside test bodies.
    edges: []const Edge = &.{},
};

/// The last two token tags plus the last identifier's text. Enough to recognise
/// a two- or three-token spelling without buffering the stream, and the reason a
/// mention inside a comment or a string literal can never match: the tokenizer
/// drops comments entirely and yields a string as one `.string_literal`, so the
/// identifiers a spelling needs are simply not there.
const Prev = struct {
    tag1: std.zig.Token.Tag = .invalid,
    tag2: std.zig.Token.Tag = .invalid,
    ident: []const u8 = "",

    /// Shifts one token in.
    fn push(self: *Prev, tag: std.zig.Token.Tag, name: []const u8) void {
        self.tag2 = self.tag1;
        self.tag1 = tag;
        if (tag == .identifier) self.ident = name;
    }
};

/// Tracks which named function the tokenizer is currently inside, by brace
/// depth. A function nested in another (a `const W = struct { fn run() ... }`)
/// is attributed to the innermost name, which is the one a caller spells; the
/// attribution is cleared when depth returns to the top level.
const FnTracker = struct {
    depth: u32 = 0,
    pending: bool = false,
    current: ?[]const u8 = null,

    /// Advances the tracker for one token.
    fn advance(self: *FnTracker, tag: std.zig.Token.Tag, name: []const u8) void {
        switch (tag) {
            .keyword_fn => self.pending = true,
            // `const F = fn (u32) void` has no name: stop waiting for one.
            .l_paren => self.pending = false,
            .identifier => self.takeName(name),
            .l_brace => self.depth += 1,
            .r_brace => self.leaveBrace(),
            else => {},
        }
    }

    /// Adopts `name` as the current function when a `fn` keyword just opened.
    fn takeName(self: *FnTracker, name: []const u8) void {
        if (!self.pending) return;
        self.current = name;
        self.pending = false;
    }

    /// Closes one brace, forgetting the current function at the top level.
    fn leaveBrace(self: *FnTracker) void {
        if (self.depth > 0) self.depth -= 1;
        if (self.depth == 0) self.current = null;
    }
};

/// Growable halves of a `Scan`, filled during the token walk.
const Acc = struct {
    spawn_in_test: bool = false,
    spawners: std.ArrayList([]const u8) = .empty,
    test_calls: std.ArrayList([]const u8) = .empty,
    edges: std.ArrayList(Edge) = .empty,
};

/// One token from the walk: its tag, its source text, and the two tags plus
/// last identifier that preceded it. Bundled so the recognisers below take one
/// value instead of a parameter list.
const Tok = struct {
    tag: std.zig.Token.Tag,
    name: []const u8,
    prev: Prev,
};

/// Where in the file the token sits: inside a `test { ... }` body, and/or inside
/// the named function the tracker is currently in.
const Site = struct {
    in_test: bool,
    current_fn: ?[]const u8,
};

/// True when the token just read closes a *spawn* spelling — a spelling that
/// yields a real second unit of execution.
///
/// Accepted: `Thread.spawn` and `Thread.Pool` (any receiver spelled `Thread`, so
/// `std.Thread.spawn` and an aliased `const Thread = std.Thread` both match), and
/// a `.concurrent(` call — `Io.concurrent` and `Io.Group.concurrent`, the Zig
/// 0.17 `std.Io` primitives that GUARANTEE a unit of concurrency.
///
/// Deliberately NOT accepted:
/// * `std.Io.Mutex` / `RwLock` / `Semaphore` / `Condition` / `lock()` — holding a
///   lock is the very thing whose presence proves nothing.
/// * `Io.async` / `Group.async` — "`function` *may* be called immediately, before
///   `async` returns" (std/Io.zig). A single-threaded or saturated implementation
///   runs it inline, so an `async` test can pass having never interleaved.
///   `concurrent` is the spelling with the guarantee; that is why it is the one
///   this check credits.
fn isSpawnSite(tok: Tok) bool {
    if (tok.tag == .identifier) return isThreadSpawn(tok);
    if (tok.tag == .l_paren) return isConcurrentCall(tok.prev);
    return false;
}

/// True when the token closes `Thread.spawn` or `Thread.Pool`: the two prior
/// tokens were an identifier then `.`, and that identifier was `Thread`.
fn isThreadSpawn(tok: Tok) bool {
    if (tok.prev.tag1 != .period or tok.prev.tag2 != .identifier) return false;
    if (!std.mem.eql(u8, tok.prev.ident, "Thread")) return false;
    return std.mem.eql(u8, tok.name, "spawn") or std.mem.eql(u8, tok.name, "Pool");
}

/// True when a `(` closes a `<receiver>.concurrent(` call. The trailing paren is
/// required so a struct FIELD named `concurrent` is not mistaken for the call.
fn isConcurrentCall(prev: Prev) bool {
    if (prev.tag1 != .identifier or prev.tag2 != .period) return false;
    return std.mem.eql(u8, prev.ident, "concurrent");
}

/// The identifier being called when the token just read is a `(` that follows
/// one, else null. `if (`, `while (` and friends open with keywords, so they
/// yield nothing.
fn calleeAt(tok: Tok) ?[]const u8 {
    if (tok.tag != .l_paren or tok.prev.tag1 != .identifier) return null;
    return tok.prev.ident;
}

/// Records what one token contributes: a spawn site (credited to the test body
/// or to the enclosing function) and a call edge (rooted at a test body or
/// hanging off the enclosing function).
fn note(allocator: Allocator, acc: *Acc, tok: Tok, site: Site) Allocator.Error!void {
    if (isSpawnSite(tok)) try noteSpawn(allocator, acc, site);
    const callee = calleeAt(tok) orelse return;
    if (site.in_test) return acc.test_calls.append(allocator, callee);
    const caller = site.current_fn orelse return;
    try acc.edges.append(allocator, .{ .caller = caller, .callee = callee });
}

/// Credits one spawn spelling: to the test body when it sits in one, else to the
/// function that owns it (which only counts if a test reaches that function).
fn noteSpawn(allocator: Allocator, acc: *Acc, site: Site) Allocator.Error!void {
    if (site.in_test) {
        acc.spawn_in_test = true;
        return;
    }
    const owner = site.current_fn orelse return;
    try acc.spawners.append(allocator, owner);
}

/// Walks one file's TOKEN stream and reports where its spawn spellings live and
/// which of its functions its tests reach.
fn scanSource(allocator: Allocator, z: [:0]const u8) Allocator.Error!Scan {
    var tokenizer = std.zig.Tokenizer.init(z);
    var prev: Prev = .{};
    var scope: text.TestScope = .{};
    var fns: FnTracker = .{};
    var acc: Acc = .{};
    while (true) {
        const t = tokenizer.next();
        if (t.tag == .eof) break;
        const name = z[t.loc.start..t.loc.end];
        const tok: Tok = .{ .tag = t.tag, .name = name, .prev = prev };
        try note(allocator, &acc, tok, .{ .in_test = scope.in_test, .current_fn = fns.current });
        scope.update(t.tag);
        fns.advance(t.tag, name);
        prev.push(t.tag, name);
    }
    return .{
        .spawn_in_test = acc.spawn_in_test,
        .spawners = try acc.spawners.toOwnedSlice(allocator),
        .test_calls = try acc.test_calls.toOwnedSlice(allocator),
        .edges = try acc.edges.toOwnedSlice(allocator),
    };
}

/// True when `name` is in `names`.
fn contains(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

/// True when a spawning function is reachable from a test body through the
/// file-local call graph. A transitive closure, so a test that calls an
/// orchestrating helper which calls the thread-starting one still counts.
fn testsReachASpawner(allocator: Allocator, scan: Scan) Allocator.Error!bool {
    var seen: std.ArrayList([]const u8) = .empty;
    var queue: std.ArrayList([]const u8) = .empty;
    try queue.appendSlice(allocator, scan.test_calls);
    var i: usize = 0;
    while (i < queue.items.len) : (i += 1) {
        const name = queue.items[i];
        if (contains(seen.items, name)) continue;
        try seen.append(allocator, name);
        if (contains(scan.spawners, name)) return true;
        for (scan.edges) |e| {
            if (std.mem.eql(u8, e.caller, name)) try queue.append(allocator, e.callee);
        }
    }
    return false;
}

/// True when the file carries a test that genuinely exercises concurrency.
fn hasConcurrencyTest(allocator: Allocator, source: []const u8) Allocator.Error!bool {
    const z = try allocator.dupeSentinel(u8, source, 0);
    const scan = try scanSource(allocator, z);
    if (scan.spawn_in_test) return true;
    return testsReachASpawner(allocator, scan);
}

/// Pure core: one violation line per configured module that is either missing/
/// unreadable (null content) or carries no test that spawns a unit of
/// concurrency. An empty `modules` slice yields no violations (the check is
/// opt-in by listing paths).
fn analyzeModules(allocator: Allocator, modules: []const ModuleSource) Allocator.Error![]const []const u8 {
    var violations: std.ArrayList([]const u8) = .empty;
    for (modules) |m| {
        const content = m.content orelse {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}: listed module is missing or unreadable",
                .{m.path},
            ));
            continue;
        };
        if (!try hasConcurrencyTest(allocator, content)) {
            try violations.append(allocator, try std.fmt.allocPrint(
                allocator,
                "{s}: no test spawns a second unit of execution (a lock alone proves nothing)",
                .{m.path},
            ));
        }
    }
    return violations.toOwnedSlice(allocator);
}

/// Reads a configured module's source under `project_dir`, or null when the
/// file is missing/unreadable (the caller turns null into a hard violation).
fn readModule(allocator: Allocator, project_dir: []const u8, module: []const u8) Allocator.Error!?[]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ project_dir, module });
    return fs.cwd().readFileAlloc(allocator, path, read_limit) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return null,
    };
}

/// Entry point for the concurrency-test-presence check (opt-in via
/// `[concurrency_presence] modules`).
pub fn run(ctx_param: *registry.RunCtx) registry.RunError!void {
    const allocator = ctx_param.allocator;
    const modules = ctx_param.cfg.concurrency_presence.modules;
    if (modules.len == 0) {
        ok("concurrency-test-presence: no modules configured (opt-in via [concurrency_presence] modules)", .{});
        return;
    }

    var sources = try allocator.alloc(ModuleSource, modules.len);
    for (modules, 0..) |m, i| {
        sources[i] = .{ .path = m, .content = try readModule(allocator, ctx_param.project_dir, m) };
    }
    const violations = try analyzeModules(allocator, sources);

    if (violations.len == 0) {
        ok("concurrency-test-presence: all {d} listed module(s) carry a concurrency test", .{modules.len});
        return;
    }
    fail("concurrency-test-presence FAILED ({d} module(s) without a concurrency test)", .{violations.len});
    for (violations) |v| print("  {s}\n", .{v});
    print("  fix: add a test that starts a second worker over the shared state —\n", .{});
    print("       `std.Thread.spawn` (join it), or `io.concurrent` / `Io.Group.concurrent`.\n", .{});
    print("       The spawn may live in a helper the test calls; `io.async` does not\n", .{});
    print("       count (it may run inline). Or drop the path from\n", .{});
    print("       [concurrency_presence] modules if it no longer guards shared state.\n", .{});
    return error.CheckFailed;
}

// spec: Concurrency Test Presence - Passes a configured module whose test spawns a unit of concurrency

test "analyzeModules passes a module whose test spawns a thread or goes concurrent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]ModuleSource{
        .{ .path = "src/a.zig", .content = "test \"race\" { const t = try std.Thread.spawn(.{}, w, .{}); t.join(); }" },
        // The spawn lives in a helper the test calls: guardian's own
        // test-no-conditional pushes the join loop out of the test body, so the
        // helper pattern must count or the check fights the rest of the suite.
        .{ .path = "src/b.zig", .content =
        \\fn hammer(s: *S) !void {
        \\    var ts: [2]std.Thread = undefined;
        \\    for (&ts) |*t| t.* = try std.Thread.spawn(.{}, work, .{s});
        \\    for (ts) |t| t.join();
        \\}
        \\test "shared store survives two writers" { try hammer(&s); }
        },
        // The std.Io spelling that GUARANTEES a unit of concurrency.
        .{ .path = "src/c.zig", .content = "test \"io\" { var f = try io.concurrent(work, .{&s}); f.await(io); }" },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 0), out.len);
}

// spec: Concurrency Test Presence - Flags a configured module whose locks are never exercised by a test

test "analyzeModules flags a lock-only module and ignores comments, strings and prod spawns" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]ModuleSource{
        // A lock table plus structure tests: exactly the motivating file. Holding
        // a lock is not evidence that the lock is exercised.
        .{ .path = "src/lockonly.zig", .content =
        \\var locks: [8]std.Io.Mutex = @splat(.{});
        \\pub fn lockSidecar(n: []const u8) Guard { return .{ .mu = pick(n) }; }
        \\test "one sidecar maps to one lock slot" { try expect(pick("b") == pick("b")); }
        },
        // A mention inside a comment or a string literal is not code.
        .{ .path = "src/mentions.zig", .content =
        \\// std.Thread.spawn would go here one day
        \\const doc = "std.Thread.spawn(.{}, w, .{})";
        \\test "documents the plan" { try expect(doc.len > 0); }
        },
        // A production spawn no test reaches: the point is a TEST.
        .{ .path = "src/prodspawn.zig", .content =
        \\pub fn startWarmup(ctx: *Ctx) void {
        \\    const t = std.Thread.spawn(.{}, run, .{ctx}) catch return;
        \\    t.detach();
        \\}
        \\test "warmup context defaults to idle" { try expect(!ctx.busy); }
        },
        // `async` carries no concurrency guarantee — it may run inline.
        .{ .path = "src/asyncish.zig", .content = "test \"io\" { var f = io.async(work, .{&s}); f.await(io); }" },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 4), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "no test spawns a second unit") != null);
}

// spec: Concurrency Test Presence - Hard-fails a configured module that is missing or unreadable

test "analyzeModules hard-fails a missing or unreadable module" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const mods = [_]ModuleSource{
        .{ .path = "src/gone.zig", .content = null },
    };
    const out = try analyzeModules(a, &mods);
    try std.testing.expectEqual(@as(usize, 1), out.len);
    try std.testing.expect(std.mem.indexOf(u8, out[0], "missing or unreadable") != null);
}
