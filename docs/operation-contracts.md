# Operation contracts

Guardian can enforce declaration-scoped persistence and request boundaries with
`[[contract]]` entries in `guardian.toml`. These are opt-in: no contract means no
new gate findings. The EDA review profile is `examples/eda-contracts.toml`.

```sh
guardian-check contract-audit /path/to/eda --contracts examples/eda-contracts.toml --json
```

The audit reports all findings independently of accepted baselines. It does not
update the target configuration or snapshots. Exit zero means the report was
produced; use `violations` and `review_items` for the verdict. `--contracts` is an
audit-only overlay; put reviewed entries in the target's config to gate builds.

| Kind | Gate | Meaning |
| --- | --- | --- |
| `durable_write` | `durable-write-errors` | Selected write wrappers erase operation errors or return void. |
| `persistent_read` | `persistent-read-errors` | Selected readers erase read/parse errors into ordinary absence. |
| `transaction` | `mutation-boundary` | Raw mutations occur outside declared owners. |
| `decoder` | `request-decoding` | Raw request parsing occurs outside declared decoders. |
| `identity` | `edit-identity` | Target selection lacks verified identity/revision evidence; advisory. |

Every entry requires `name`, `kind`, `functions`, `operations` and `reason`.
`functions` selects declarations with `file::function` globs. `operations`
selects resolved declarations or external methods, for example `*.writeFile`.
`allow` exempts exact reviewed declarations; wildcard exemptions are rejected. Avoid broad exemptions: an allowed owner
is trusted by policy, not proven correct by the analyzer.
Identity contracts also require `validators`, `identity` and `revision`; the
last two lists are argument identifier names, not string matching in comments.

The call index follows direct same-file functions, imported modules and constant
function aliases. Storage effects propagate through wrappers and recursive
calls. Catch analysis distinguishes simple error propagation, explicit benign
returns/defaults, and complex handlers requiring review. A switch arm recovering
only `error.FileNotFound` is permitted for readers; swallowing other errors is
not. Unknown function selectors and policies reaching no operation produce review findings.

A violation proves a mismatch with the configured policy, not reproduced data
loss. Several rows can describe one underlying design issue: counts deduplicate
by rule, function, operation and failure class, not by root cause.

## Limits and verification

This is source analysis, not Zig compiler type analysis. Dynamic receivers retain
an `external.method` name; use narrowly scoped function selectors to avoid
confusing unrelated methods. Ambiguous declarations and unresolved dispatch do
not gain inferred effects. Catch analysis is conservative and does not model
arbitrary helper-returned errors or runtime reachability. Returning a different
identifier from a handler requires review because it may be an error alias. Identity validator
presence still produces a review row: the tool cannot prove dominance, correct
validator implementation, or use of the validated result. Mutation owners need
human review for lock lifetime and revision semantics.

The checks complement behavioral tests. Simulate write failure before API
acknowledgement, malformed/oversized sidecars, concurrent edits from the same
revision, JSON escapes and wrong types, stale offsets and numeric extremes.
Those tests are necessary to establish runtime guarantees; a clean static report
cannot establish them. The existing `int-from-float-budget` check remains the
numeric conversion guard.

Run analyzer regressions with `zig build test -Dtest-filter=contracts`. Run the
CLI integration checks with `python3 scripts/test-operation-contracts.py
zig-out/bin/guardian-check` (on one line) after building Guardian. The latter
checks JSON redirected to a regular file, counts, gate exit codes, invalid
arguments, malformed source and an unchanged target tree.
