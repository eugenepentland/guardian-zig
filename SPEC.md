# Guardian for Zig

## Overview

A verification gate tool for AI-generated Zig code. Runs a multi-stage pipeline
and auto-commits on success or writes GUARDIAN_FEEDBACK.md on failure.

## Configuration

- Loads guardian.toml from target directory
- Falls back to defaults when no config file exists
- Supports boundary rules via [[boundary]] sections

## Spec Coverage

- Parses SPEC.md for section headers and behavior bullets
- Scans test and source files for // spec: tags
- Reports unverified behaviors and unlinked tags

## Pipeline

- Runs stages sequentially and stops at first failure
- Reports pass/fail status for each stage
- Auto-commits with receipt on success
- Writes GUARDIAN_FEEDBACK.md on failure
