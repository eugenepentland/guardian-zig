# Guardian for Zig

## Overview

Build-step quality gates for Zig projects. Runs on every `zig build` — invisible, opinionated, hard-blocking.

## Configuration

- Loads guardian.toml from target directory
- Falls back to defaults when no config file exists
- Supports boundary rules via [[boundary]] sections

## Spec Coverage

- Parses SPEC.md for section headers and behavior bullets
- Scans test and source files for // spec: tags
- Reports unverified behaviors and unlinked tags
- Enforces 1:1 mapping between spec behaviors and test tags
- Fails with clear error when SPEC.md is missing

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
- pub const struct/enum/union with fields must be PascalCase

## Function Size

- Caps parameter count per function

## Doc Comments

- Requires /// on every pub fn
- Requires /// on every pub struct/enum/union/opaque

## Imports

- Detects cycles in the @import graph

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

## Error Discipline

- Rejects inferred error sets on pub fn
- Rejects anyerror on pub fn

## Cognitive Complexity

- Caps per-function cognitive complexity score

## Anytype Budget

- Caps anytype parameter count per file

## Dead Pub

- Flags public declarations referenced only by themselves
