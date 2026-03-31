# Guardian for Zig

## Overview

Build-step quality gates for Zig projects. Integrates into build.zig as a package dependency — no external tool needed.

## Configuration

- Loads guardian.toml from target directory
- Falls back to defaults when no config file exists
- Supports boundary rules via [[boundary]] sections

## Spec Coverage

- Parses SPEC.md for section headers and behavior bullets
- Scans test and source files for // spec: tags
- Reports unverified behaviors and unlinked tags

## File Size

- Checks source files against configurable line limit
- Respects file_size_exclude patterns

## Boundaries

- Extracts @import paths from source files
- Checks against boundary rules defined in guardian.toml
- Reports forbidden import violations
