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

## File Size

- Checks source files against configurable line limit
- Respects file_size_exclude patterns

## Boundaries

- Extracts @import paths from source files
- Checks against boundary rules defined in guardian.toml
- Reports forbidden import violations
