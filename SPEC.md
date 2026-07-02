# Guardian for Zig

## Overview

Build-step quality gates for Zig projects. Runs on every `zig build` — invisible, opinionated, hard-blocking.

## Configuration

- Loads guardian.toml from target directory
- Falls back to defaults when no config file exists
- Supports boundary rules via [[boundary]] sections
- Parses a top-level disabled list of check names

## Spec Coverage

- Parses SPEC.md for section headers and behavior bullets
- Scans test and source files for // spec: tags
- Reports unverified behaviors and unlinked tags
- Enforces 1:1 mapping between spec behaviors and test tags
- Fails with clear error when SPEC.md is missing
- Fails when SPEC.md defines no behaviors
- Reports near-miss spec tags that miss the exact prefix
- Reports duplicate spec behavior bullets
- Requires each spec tag to sit directly on a test

## Spec Lifecycle

- Generates starter SPEC.md from pub fn signatures via spec-init
- Normalizes spec keys for whitespace-insensitive comparison

## File Size

- Checks source files against configurable line limit
- Respects file_size_exclude patterns

## Boundaries

- Extracts @import paths from source files and normalizes relative paths
- Matches file paths against glob and prefix boundary patterns
- Checks against boundary rules defined in guardian.toml
- Reports forbidden import violations

## Usingnamespace Ban

- Hard-fails any usingnamespace keyword outside test files

## Spec Quality

- Flags vague behavior phrases in SPEC.md
- Rejects behaviors shorter than the minimum length

## Naming

- PascalCase pub fn must return type
- camelCase pub fn must not return type
- snake_case pub fn is rejected
- pub const struct/enum/union with fields must be PascalCase

## Function Size

- Caps parameter count per function

## Doc Comments

- Requires /// on every pub fn
- Requires /// on every pub struct/enum/union/opaque

## Imports

- Detects cycles in the @import graph

## AST Index

- Builds a parsed-source index by reading and parsing each file once
- Iterates the index exposing each file's pre-parsed syntax tree to a visitor
- Returns the shared index when present and builds a private one otherwise

## Skip Cache

- Hashes the guardian input set into a stable digest
- Round-trips the digest through the cache file

## Run All

- Skips checks whose name appears in the disabled config list
- Rejects unknown check names in the disabled list

## Snapshot Lifecycle

- Creates snapshot file on first run with no prior snapshot
- Reports drift when current state differs from prior snapshot
- Honors GUARDIAN_UPDATE_SNAPSHOT to regenerate snapshot

## Pub Api Surface

- Snapshots every public declaration
- Diff fails on unexpected pub additions or removals

## Panic Budget

- Tracks panic and unreachable token counts against a snapshot
- Tracks TODO and FIXME comment counts against a snapshot

## Spec Drift

- Snapshots pub fn prototypes
- Diff fails when an existing pub fn signature changes

## Catch Discipline

- Rejects catch unreachable in production code
- Rejects catch with empty block (silent error swallow)
- Rejects catch undefined assigning undefined on error

## Unwrap Discipline

- Rejects orelse unreachable in production code
- Rejects orelse undefined in production code

## Error Discipline

- Rejects inferred error sets on pub fn
- Rejects anyerror on pub fn

## Cognitive Complexity

- Caps per-function cognitive complexity score

## Anytype Budget

- Caps anytype parameter count per file

## Dead Pub

- Flags public declarations referenced only by themselves

## Allocator Hygiene

- Rejects hardcoded global allocators outside test blocks and pub fn main

## Duplicate Const

- Rejects file-scope const string-literal declarations with the same name and value defined in two or more files

## Debug Print Ban

- Rejects std.debug.print call expressions outside test blocks and pub fn main
- Rejects std.log.* call expressions outside test blocks and pub fn main

## Orphan Files

- Reports .zig files under src/ unreachable from any configured root via @import

## Stub Body Ban

- Rejects single-statement function bodies that are stub forms (return undefined, panic with placeholder phrase, or unreachable in non-noreturn fns)

## Doc Quality

- Rejects empty or stub doc comments on public declarations

## Comptime Quota

- Tracks @setEvalBranchQuota call count and max value against a snapshot

## Type Size

- Caps fields per pub struct/enum/union/opaque

## Function Length

- Caps source lines per fn decl

## Nesting Depth

- Caps brace-nesting depth inside fn bodies

## Test Coverage

- Requires every pub fn to be referenced from at least one test block

## Constructor Hygiene

- Rejects @compileError without a non-empty string explanation
- Rejects init bodies with loops, conditionals, or switch statements
- Rejects static factory / singleton patterns in business logic
- Requires structs that own an allocator field to declare a pub fn deinit
- Requires init bodies with multiple try calls to use errdefer

## Tier 2 Anti-patterns

- Caps source line length
- Rejects vague identifier names on public declarations
- Rejects bool parameters in public functions
- Rejects bare integer literals outside a small allowlist
- Rejects identical string literals appearing 3 or more times in a single file
- Caps pub fn methods per pub struct/enum/union
- Caps the percentage of optional fields in a public struct
- Rejects switch expressions whose case keys are string literals

## Tier 3 Architectural Fitness

- Flags the same enum dot-prong set switched in 2+ files

## Baseline Mode

- Captures each check's current violations on first run and only fails on additions
- Wraps a single check run with capture, diff, and outcome reporting

## Complexity Bounds

- Caps boolean operators per condition
- Caps return statements per function body

## Test Hygiene

- Requires every test block to contain at least one std.testing.expect call
- Rejects if/while/switch and extra for loops at the top level of a test body
- Rejects production code @import-ing test files

## Hidden Dependency Bans

- Rejects std.time wall-clock reads outside infra/clock
- Rejects RNG construction outside infra/random
- Rejects std.fs I/O calls outside infra/fs
- Rejects std.net and std.http use outside adapters/http or infra/net
- Rejects environment-variable reads outside config or main
- Rejects sleep calls outside test infrastructure
- Rejects mutable pub var globals outside wiring/main
- Rejects hardcoded absolute paths and URLs in string literals
