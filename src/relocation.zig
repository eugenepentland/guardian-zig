//! Relocation-aware ratchet identity: recognizing that an over-cap subject
//! MOVED, rather than treating it as debt that appeared from nowhere.
//!
//! A per-item ratchet (ratchet.zig) keys each grandfathered offender by
//! `<file>|<item>`, or by `<file>` alone for the whole-file checks. Splitting an
//! over-cap file — the refactor Guardian's own design asks for — therefore
//! re-charges every entry it moves: the old key silently prunes and the new key
//! is a `new_offender` that FAILS until someone accepts it, while raising a
//! ceiling in place costs one env var. eda paid two hours to that inversion
//! (FEEDBACK 2026-07-26: moving `PadObs` fired type-size at the new key for the
//! same 8 fields it was already baselined for at the old one).
//!
//! Two tiers recognize a move, in this order:
//!
//!   1. **Whole-file rename**, from git's own rename detection. It re-keys every
//!      entry under the old path — including the file-only keys (file-size,
//!      line-length) tier 2 cannot see — and is safe in any run view, because
//!      git looked at the whole tree even when the checks did not. Only renames
//!      git can see count: a `git mv`, or a move whose new path was `git add`ed.
//!   2. **Extracted item**, by content: an unrecorded `<newfile>|<Item>` whose
//!      item name matches exactly ONE recorded entry elsewhere that reported
//!      nothing this run, measuring at or below that entry's ceiling. This is
//!      the `PadObs` case, where the destination file is brand new and in no
//!      diff at all.
//!
//! What is deliberately NOT a move: an ambiguous match (two recorded entries, or
//! two new keys, sharing one item name), a match the run cannot verify (a
//! diff-scoped run sees only part of the tree, so "the old key reported nothing"
//! may just mean "the old file was out of scope"), and — above all — a match
//! that GREW. A move must not smuggle growth: over the candidate's ceiling it
//! stays a failure. Each of those keeps today's behaviour and gains a hint
//! naming the recorded candidate, so the reader is told the entry exists instead
//! of guessing why the gate is red.
//!
//! Everything here is pure: git's answer arrives as data (`[]const git.Rename`)
//! and the plan leaves as key→key transfers the ratchet lifecycle applies.

const std = @import("std");
const Allocator = std.mem.Allocator;
const ratchet = @import("ratchet.zig");
const git = @import("git.zig");
const scope = @import("scope.zig");

/// One recorded entry re-keyed because its subject moved. Rendered as
/// pub-api-surface renders its relocations (`moved: <from> -> <to> :: <item>`),
/// so one convention covers every "same thing, new home" report Guardian makes.
pub const Moved = struct {
    from: []const u8,
    to: []const u8,
    /// The item that moved, or "" for a whole-file key (file-size, line-length).
    item: []const u8 = "",
};

/// Why a relocation-looking new key was left to fail as a new offender.
pub const Reason = enum {
    /// Several recorded entries — or several new keys — share the item name.
    ambiguous,
    /// The item measures above the candidate's ceiling: growth, not a move.
    over_ceiling,
    /// A diff-scoped run cannot confirm the old key stopped reporting.
    scoped,
};

/// A new key that looks relocated but was not transferred, kept so the failure
/// can name the recorded entry the reader is probably looking for.
pub const Unresolved = struct {
    /// The unrecorded key this run reported.
    key: []const u8,
    /// The item name it shares with the candidate(s).
    item: []const u8,
    /// What this run measured for it.
    value: u64,
    /// The recorded entries for the same item elsewhere.
    candidates: []const ratchet.Entry,
    reason: Reason,
};

/// One detection tier's result: the recorded entries as re-keyed so far, the
/// transfers that produced them, what to report as moved, and the new keys that
/// looked relocated but could not be transferred.
pub const Plan = struct {
    entries: []const ratchet.Entry = &.{},
    transfers: []const ratchet.Transfer = &.{},
    moved: []const Moved = &.{},
    unresolved: []const Unresolved = &.{},
};

/// Tier 1 — re-key every recorded entry under a file git reports as renamed,
/// including the file-only keys. Honoured in any run view: git compared the
/// whole tree regardless of how narrow this run's checks were.
pub fn renamedFiles(
    arena: Allocator,
    recorded: []const ratchet.Entry,
    renames: []const git.Rename,
) Allocator.Error!Plan {
    if (recorded.len == 0 or renames.len == 0) return .{ .entries = recorded };
    var transfers: std.ArrayList(ratchet.Transfer) = .empty;
    var moved: std.ArrayList(Moved) = .empty;
    for (recorded) |e| {
        const r = renameOf(renames, fileOf(e.key)) orelse continue;
        try transfers.append(arena, .{
            .from = e.key,
            .to = try std.fmt.allocPrint(arena, "{s}{s}", .{ r.to, e.key[r.from.len..] }),
        });
        try moved.append(arena, .{ .from = r.from, .to = r.to, .item = itemOf(e.key) orelse "" });
    }
    const applied = try ratchet.applyTransfers(arena, recorded, transfers.items);
    return .{
        .entries = applied.entries,
        .transfers = try transfers.toOwnedSlice(arena),
        .moved = try moved.toOwnedSlice(arena),
    };
}

/// Tier 2 — transfer a recorded entry to the file its item was extracted into.
/// `base` is tier 1's plan (so a rename-then-extract chain resolves); `current`
/// is this run's aggregated state. The returned plan carries BOTH tiers'
/// transfers, in the order they must be applied.
///
/// A partial view produces no transfers at all: it cannot tell a vanished key
/// from an out-of-scope one, and re-keying on that guess would move recorded
/// debt onto the wrong subject. It still names the candidate.
pub fn extractedItems(
    arena: Allocator,
    base: Plan,
    current: []const ratchet.Entry,
    view: scope.View,
) Allocator.Error!Plan {
    var transfers: std.ArrayList(ratchet.Transfer) = .empty;
    try transfers.appendSlice(arena, base.transfers);
    var moved: std.ArrayList(Moved) = .empty;
    try moved.appendSlice(arena, base.moved);
    var unresolved: std.ArrayList(Unresolved) = .empty;

    const arrivals = try unrecordedItems(arena, base.entries, current);
    for (arrivals) |a| {
        const cands = try candidatesFor(arena, base.entries, current, a);
        if (cands.len == 0) continue; // genuinely new debt, not a relocation
        if (reasonToRefuse(view, cands, a, arrivals)) |reason| {
            try unresolved.append(arena, .{
                .key = a.entry.key,
                .item = a.item,
                .value = a.entry.value,
                .candidates = cands,
                .reason = reason,
            });
            continue;
        }
        try transfers.append(arena, .{ .from = cands[0].key, .to = a.entry.key });
        try moved.append(arena, .{
            .from = fileOf(cands[0].key),
            .to = fileOf(a.entry.key),
            .item = a.item,
        });
    }
    const applied = try ratchet.applyTransfers(arena, base.entries, transfers.items[base.transfers.len..]);
    return .{
        .entries = applied.entries,
        .transfers = try transfers.toOwnedSlice(arena),
        .moved = try moved.toOwnedSlice(arena),
        .unresolved = try unresolved.toOwnedSlice(arena),
    };
}

/// A current key with no recorded entry, split into its file and item parts.
const Arrival = struct { entry: ratchet.Entry, item: []const u8 };

/// The current keys that are not on file AND name an item — the only shape a
/// content-matched move can take. A file-only key (file-size, line-length)
/// carries nothing to match on, so it stays a new offender unless tier 1 saw
/// git rename the file.
fn unrecordedItems(
    arena: Allocator,
    recorded: []const ratchet.Entry,
    current: []const ratchet.Entry,
) Allocator.Error![]const Arrival {
    var out: std.ArrayList(Arrival) = .empty;
    for (current) |e| {
        if (hasKey(recorded, e.key)) continue;
        const item = itemOf(e.key) orelse continue;
        try out.append(arena, .{ .entry = e, .item = item });
    }
    return out.toOwnedSlice(arena);
}

/// Recorded entries that could be `a`'s former home: same item name, different
/// key, and silent this run — a key that still reports is a subject that did not
/// move, however alike the two names look.
fn candidatesFor(
    arena: Allocator,
    recorded: []const ratchet.Entry,
    current: []const ratchet.Entry,
    a: Arrival,
) Allocator.Error![]const ratchet.Entry {
    var out: std.ArrayList(ratchet.Entry) = .empty;
    for (recorded) |e| {
        if (std.mem.eql(u8, e.key, a.entry.key)) continue;
        const item = itemOf(e.key) orelse continue;
        if (!std.mem.eql(u8, item, a.item)) continue;
        if (hasKey(current, e.key)) continue;
        try out.append(arena, e);
    }
    return out.toOwnedSlice(arena);
}

/// Why this arrival must not be transferred, or null when it may be. Order
/// matters only for the message: an unverifiable view is reported as such even
/// when the match would otherwise have been clean.
fn reasonToRefuse(
    view: scope.View,
    cands: []const ratchet.Entry,
    a: Arrival,
    arrivals: []const Arrival,
) ?Reason {
    if (view == .partial) return .scoped;
    if (cands.len > 1 or claimants(arrivals, a.item) > 1) return .ambiguous;
    if (a.entry.value > cands[0].value) return .over_ceiling;
    return null;
}

/// How many arriving keys name `item`. Two claimants on one recorded entry would
/// duplicate it — the entry count must be conserved, so neither is transferred.
fn claimants(arrivals: []const Arrival, item: []const u8) usize {
    var n: usize = 0;
    for (arrivals) |a| {
        if (std.mem.eql(u8, a.item, item)) n += 1;
    }
    return n;
}

/// The advisory line for one unresolved relocation: what is recorded, where,
/// and what would make the entry transfer. `check_name` supplies both the accept
/// command and (via the ratchet's unit table) the dimension a bare number means.
pub fn hintText(arena: Allocator, check_name: []const u8, u: Unresolved) Allocator.Error![]const u8 {
    const lead = try std.fmt.allocPrint(
        arena,
        "an entry for {s} exists at {s}",
        .{ u.item, try candidateList(arena, u.candidates) },
    );
    const accept = try std.fmt.allocPrint(arena, "`guardian-check accept {s} .`", .{check_name});
    return switch (u.reason) {
        .ambiguous => std.fmt.allocPrint(
            arena,
            "{s} — if this code moved, run {s} to transfer",
            .{ lead, accept },
        ),
        .scoped => std.fmt.allocPrint(
            arena,
            "{s} — this run is diff-scoped and cannot confirm the move; run {s} over the whole tree to transfer",
            .{ lead, accept },
        ),
        .over_ceiling => std.fmt.allocPrint(
            arena,
            "{s} — this measures {d} {s}, above that ceiling: growth, not a move " ++
                "(reduce it to {d} and the entry transfers)",
            .{ lead, u.value, ratchet.unitLabel(check_name), u.candidates[0].value },
        ),
    };
}

/// `<file> (ceiling N)`, comma-joined — the recorded side of a hint.
fn candidateList(arena: Allocator, candidates: []const ratchet.Entry) Allocator.Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    for (candidates, 0..) |c, i| {
        if (i > 0) try out.appendSlice(arena, ", ");
        try out.print(arena, "{s} (ceiling {d})", .{ fileOf(c.key), c.value });
    }
    return out.toOwnedSlice(arena);
}

/// The file part of a ratchet key: everything before the last `|`, or the whole
/// key for a file-only one.
fn fileOf(key: []const u8) []const u8 {
    const bar = std.mem.lastIndexOfScalar(u8, key, '|') orelse return key;
    return key[0..bar];
}

/// The item part of a ratchet key, or null when the key names a file only.
fn itemOf(key: []const u8) ?[]const u8 {
    const bar = std.mem.lastIndexOfScalar(u8, key, '|') orelse return null;
    return key[bar + 1 ..];
}

/// The rename whose old path is exactly `file`, or null.
fn renameOf(renames: []const git.Rename, file: []const u8) ?git.Rename {
    for (renames) |r| {
        if (std.mem.eql(u8, r.from, file)) return r;
    }
    return null;
}

fn hasKey(entries: []const ratchet.Entry, key: []const u8) bool {
    for (entries) |e| {
        if (std.mem.eql(u8, e.key, key)) return true;
    }
    return false;
}

// ── Tests ──────────────────────────────────────────────────────────────

const testing = std.testing;

/// The two tiers as a caller runs them: renames first, then content matching.
fn planFor(
    arena: Allocator,
    recorded: []const ratchet.Entry,
    current: []const ratchet.Entry,
    renames: []const git.Rename,
    view: scope.View,
) Allocator.Error!Plan {
    return extractedItems(arena, try renamedFiles(arena, recorded, renames), current, view);
}

// spec: Ratchet Relocation - Re-keys every recorded entry under a file git reports as renamed

test "a renamed file carries all of its recorded keys, item-keyed and file-keyed alike" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // src/router.zig became src/route/core.zig: one file-only key (file-size)
    // and two item keys ride along; an unrelated file is untouched.
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/router.zig", .value = 10_200 },
        .{ .key = "src/router.zig|claim", .value = 8 },
        .{ .key = "src/router.zig|width", .value = 7 },
        .{ .key = "src/other.zig|keep", .value = 9 },
    };
    const current = [_]ratchet.Entry{
        .{ .key = "src/route/core.zig", .value = 10_200 },
        .{ .key = "src/route/core.zig|claim", .value = 8 },
        .{ .key = "src/route/core.zig|width", .value = 7 },
        .{ .key = "src/other.zig|keep", .value = 9 },
    };
    const renames = [_]git.Rename{.{ .from = "src/router.zig", .to = "src/route/core.zig" }};
    // The two tiers, called as a caller runs them (see `planFor` elsewhere).
    const p = try extractedItems(a, try renamedFiles(a, &recorded, &renames), &current, .whole_tree);
    try testing.expectEqual(@as(usize, 3), p.transfers.len);
    try testing.expectEqual(@as(usize, 3), p.moved.len);
    try testing.expectEqual(@as(usize, 0), p.unresolved.len);
    // Every re-keyed entry now matches a current key, at its recorded ceiling.
    try testing.expectEqual(recorded.len, p.entries.len);
    for (p.entries) |e| try testing.expect(hasKey(&current, e.key));
    // The file-only key moved too — its `moved` line has no item to name.
    try testing.expectEqualStrings("", p.moved[0].item);
    try testing.expectEqualStrings("src/router.zig", p.moved[0].from);
    try testing.expectEqualStrings("src/route/core.zig", p.moved[0].to);
}

// spec: Ratchet Relocation - Transfers a recorded entry to the file its item was extracted into

test "an item extracted into a new file takes its ceiling with it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // The PadObs case: the struct is baselined at 8 fields in obs.zig and now
    // lives in pad_obs.zig, a file git has never seen — no rename to detect.
    const recorded = [_]ratchet.Entry{.{ .key = "src/obs.zig|PadObs", .value = 8 }};
    const current = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 8 }};
    const p = try planFor(a, &recorded, &current, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 1), p.transfers.len);
    try testing.expectEqualStrings("src/obs.zig|PadObs", p.transfers[0].from);
    try testing.expectEqualStrings("src/pad_obs.zig|PadObs", p.transfers[0].to);
    try testing.expectEqualStrings("PadObs", p.moved[0].item);
    try testing.expectEqualStrings("src/obs.zig", p.moved[0].from);
    try testing.expectEqualStrings("src/pad_obs.zig", p.moved[0].to);
    try testing.expectEqual(@as(usize, 0), p.unresolved.len);
}

// spec: Ratchet Relocation - Keeps the new-offender failure when several recorded entries share the item name

test "an ambiguous item name transfers nothing and is left to fail" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // Two recorded `init`s went quiet and one arrived elsewhere: which ceiling
    // would move is a guess, so none does.
    const two_homes = [_]ratchet.Entry{
        .{ .key = "src/a.zig|init", .value = 9 },
        .{ .key = "src/b.zig|init", .value = 12 },
    };
    const arrived = [_]ratchet.Entry{.{ .key = "src/c.zig|init", .value = 9 }};
    const p = try planFor(a, &two_homes, &arrived, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 0), p.transfers.len);
    try testing.expectEqual(@as(usize, 1), p.unresolved.len);
    try testing.expect(p.unresolved[0].reason == .ambiguous);
    try testing.expectEqual(@as(usize, 2), p.unresolved[0].candidates.len);

    // The mirror case: ONE recorded entry, two arrivals claiming it. Splitting
    // one ceiling into two would grow the recorded set, so neither transfers.
    const one_home = [_]ratchet.Entry{.{ .key = "src/a.zig|init", .value = 9 }};
    const two_arrivals = [_]ratchet.Entry{
        .{ .key = "src/b.zig|init", .value = 9 },
        .{ .key = "src/c.zig|init", .value = 9 },
    };
    const q = try planFor(a, &one_home, &two_arrivals, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 0), q.transfers.len);
    try testing.expectEqual(@as(usize, 2), q.unresolved.len);
}

// spec: Ratchet Relocation - Keeps the new-offender failure when a moved item measures above its recorded ceiling

test "a move that grew past the recorded ceiling is refused as growth" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recorded = [_]ratchet.Entry{.{ .key = "src/obs.zig|PadObs", .value = 8 }};
    // Moved AND given a ninth field in the same edit: a transfer here would
    // launder growth through a relocation, so it stays a new offender.
    const grew = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 9 }};
    const p = try planFor(a, &recorded, &grew, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 0), p.transfers.len);
    try testing.expectEqual(@as(usize, 1), p.unresolved.len);
    try testing.expect(p.unresolved[0].reason == .over_ceiling);

    // Landing exactly ON the ceiling is still a move, not growth.
    const at_ceiling = [_]ratchet.Entry{.{ .key = "src/pad_obs.zig|PadObs", .value = 8 }};
    const q = try planFor(a, &recorded, &at_ceiling, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 1), q.transfers.len);
}

// spec: Ratchet Relocation - Withholds content-matched transfers from a diff-scoped run

test "a diff-scoped run names the candidate but re-keys nothing by content" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/obs.zig|PadObs", .value = 8 },
        .{ .key = "src/router.zig|claim", .value = 7 },
    };
    const current = [_]ratchet.Entry{
        .{ .key = "src/pad_obs.zig|PadObs", .value = 8 },
        .{ .key = "src/route/core.zig|claim", .value = 7 },
    };
    // The old file being silent may only mean "out of scope", so the content
    // match is withheld — but git's rename is whole-tree evidence and still
    // applies, even here.
    const renames = [_]git.Rename{.{ .from = "src/router.zig", .to = "src/route/core.zig" }};
    const p = try planFor(a, &recorded, &current, &renames, .partial);
    try testing.expectEqual(@as(usize, 1), p.transfers.len);
    try testing.expectEqualStrings("src/route/core.zig|claim", p.transfers[0].to);
    try testing.expectEqual(@as(usize, 1), p.unresolved.len);
    try testing.expect(p.unresolved[0].reason == .scoped);
    try testing.expectEqualStrings("src/pad_obs.zig|PadObs", p.unresolved[0].key);
}

// spec: Ratchet Relocation - Names the recorded candidate and its ceiling when a relocation is not transferred

test "every refusal reason names the recorded entry and what would move it" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const one = [_]ratchet.Entry{.{ .key = "src/obs.zig|PadObs", .value = 8 }};
    const base: Unresolved = .{
        .key = "src/pad_obs.zig|PadObs",
        .item = "PadObs",
        .value = 9,
        .candidates = &one,
        .reason = .over_ceiling,
    };
    const grew = try hintText(a, "type-size", base);
    try testing.expect(std.mem.startsWith(u8, grew, "an entry for PadObs exists at src/obs.zig (ceiling 8)"));
    // The unit comes from the ratchet's own table, so "9" reads as 9 fields.
    try testing.expect(std.mem.indexOf(u8, grew, "9 fields") != null);
    try testing.expect(std.mem.indexOf(u8, grew, "reduce it to 8") != null);

    var ambiguous = base;
    ambiguous.reason = .ambiguous;
    const two = [_]ratchet.Entry{ one[0], .{ .key = "src/b.zig|PadObs", .value = 12 } };
    ambiguous.candidates = &two;
    const hint = try hintText(a, "type-size", ambiguous);
    try testing.expect(std.mem.indexOf(u8, hint, "src/b.zig (ceiling 12)") != null);
    try testing.expect(std.mem.indexOf(u8, hint, "`guardian-check accept type-size .` to transfer") != null);

    var scoped = base;
    scoped.reason = .scoped;
    const scoped_hint = try hintText(a, "type-size", scoped);
    try testing.expect(std.mem.indexOf(u8, scoped_hint, "diff-scoped") != null);
}

// spec: Ratchet Relocation - Conserves the recorded entry count and never raises a transferred ceiling

test "a transfer moves debt without adding any" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // A split: two of three recorded items left obs.zig for two new files, and
    // one of them got smaller on the way.
    const recorded = [_]ratchet.Entry{
        .{ .key = "src/obs.zig|PadObs", .value = 8 },
        .{ .key = "src/obs.zig|NetObs", .value = 9 },
        .{ .key = "src/obs.zig|Stay", .value = 10 },
    };
    const current = [_]ratchet.Entry{
        .{ .key = "src/obs.zig|Stay", .value = 10 },
        .{ .key = "src/pad_obs.zig|PadObs", .value = 8 },
        .{ .key = "src/net_obs.zig|NetObs", .value = 8 },
    };
    const p = try planFor(a, &recorded, &current, &.{}, .whole_tree);
    try testing.expectEqual(@as(usize, 2), p.transfers.len);
    // Conserved: same number of entries before and after, each at a ceiling no
    // higher than the one it came from.
    try testing.expectEqual(recorded.len, p.entries.len);
    for (p.entries) |e| {
        try testing.expect(hasKey(&current, e.key));
        try testing.expect(e.value <= 10);
    }
    // Classification now sees a green ratchet: one item held, one shrank.
    const outcome = try ratchet.classify(a, p.entries, &current);
    try testing.expect(outcome == .improved);
    try testing.expectEqual(@as(usize, 1), outcome.improved.lowered);
    try testing.expectEqual(@as(usize, 0), outcome.improved.pruned);
}
