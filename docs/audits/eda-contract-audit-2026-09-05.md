# EDA operation-contract audit — 2026-09-05

EDA revision: `66fb227ee898c7931afb8130fc9af7f1c9e20994` (clean checkout before and after the scan).
Profile: [`examples/eda-contracts.toml`](../../examples/eda-contracts.toml).
Raw report: [`eda-contract-audit-2026-09-05.json`](eda-contract-audit-2026-09-05.json).

**40 policy violations + 3 advisory review items, across 29 functions.** These are actionable rows, not 43 independent bugs. Counts collapse repeated calls within a function by operation and failure class.

| Check | Violations | Review items |
| --- | ---: | ---: |
| `durable-write-errors` | 8 | 0 |
| `persistent-read-errors` | 0 | 2 |
| `mutation-boundary` | 13 | 0 |
| `request-decoding` | 19 | 0 |
| `edit-identity` | 0 | 1 |

## What to resolve first

1. **Preserve save failures.** Four layout-write wrappers return `void`; two swallow both serialization and file-write errors. Together these account for 8 rows. Return errors through the save API and acknowledge a revision only after persistence succeeds.
2. **Keep corrupt/unreadable state distinct from absence.** `readSidecarDoc` swallows read and JSON parse failures. Its 2 advisory rows identify paths that can replace previously saved layouts with an empty document on a later save. The analyzer conservatively requests review for `return doc`, because it cannot generally distinguish a default value from a returned error alias; inspecting this function confirms that `doc` is an ordinary sidecar document.
3. **Replace the handwritten request decoder.** Nineteen functions call `parseJsonString`. Fixing the shared decoder and migrating its callers addresses this class together; each caller is not evidence of a distinct JSON bug.
4. **Centralize source transactions.** Thirteen functions write directly or call the atomic-write helper. Review each for lock ownership, stale-revision rejection and atomic replacement. Existing atomic replacement solves only one of these requirements; new-file creation may warrant a separate approved contract.
5. **Validate edit identity.** `findInstanceOpen` selects by source offset without a declared identity/revision validator. This is advisory because static call presence cannot prove identity semantics or safe validator-result use. The profile names a proposed resolver API, not an API already present in EDA.

## Existing numeric findings

`int-from-float-budget --list` reports **0 new, 16 live, 0 resolved**. These 16 entries were already accepted into EDA’s baseline; they are separate from the 43 rows above. One is `src/kicad_pcb/project_rules.zig:153`, the unchecked conversion discussed in the audit. Other live sites are in `eval/design_block.zig` and placement/router geometry. Review their actual finite/range guarantees before calling them defects.

## Inventory

| Check | Location | Finding |
| --- | --- | --- |
| durable-write-errors | [writeLayouts:407](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:407) | `no-write-result` — `src/layout_sidecar_store.zig::writeLayouts` |
| durable-write-errors | [writeLayoutsSub:412](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:412) | `no-write-result` — `src/layout_sidecar_store.zig::writeLayoutsSub` |
| durable-write-errors | [writeLayoutsSubRev:435](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:435) | `failure-erased` — `src/layout_sidecar_store.zig::writeLayoutsFileJsonRev` |
| durable-write-errors | [writeLayoutsSubRev:436](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:436) | `failure-erased` — `src/layout_sidecar_store.zig::writeFileAll` |
| durable-write-errors | [writeLayoutsSubRev:423](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:423) | `no-write-result` — `src/layout_sidecar_store.zig::writeLayoutsSubRev` |
| durable-write-errors | [writeLayoutsFile:451](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:451) | `failure-erased` — `src/layout_sidecar_store.zig::writeLayoutsFileJsonRev` |
| durable-write-errors | [writeLayoutsFile:452](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:452) | `failure-erased` — `src/layout_sidecar_store.zig::writeFileAll` |
| durable-write-errors | [writeLayoutsFile:440](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:440) | `no-write-result` — `src/layout_sidecar_store.zig::writeLayoutsFile` |
| persistent-read-errors | [readSidecarDoc:381](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:381) | `handler-unverified` — `external.readFileAlloc` |
| persistent-read-errors | [readSidecarDoc:385](/home/epentland/ai/canopy/eda/src/layout_sidecar_store.zig:385) | `handler-unverified` — `external.parseFromSliceLeaky` |
| mutation-boundary | [editValueApi:195](/home/epentland/ai/canopy/eda/src/serve/edit.zig:195) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [editFootprintApi:441](/home/epentland/ai/canopy/eda/src/serve/edit.zig:441) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [addInstanceApi:682](/home/epentland/ai/canopy/eda/src/serve/edit.zig:682) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [newDesignApi:749](/home/epentland/ai/canopy/eda/src/serve/edit.zig:749) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [removeInstanceApi:1459](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1459) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [rewirePinApi:1724](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1724) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [bindDecoupleApi:1860](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1860) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [duplicateInstanceApi:1957](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1957) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [renameNetApi:2023](/home/epentland/ai/canopy/eda/src/serve/edit.zig:2023) | `boundary-bypass` — `external.writeFile` |
| mutation-boundary | [writeAndRebuild:2328](/home/epentland/ai/canopy/eda/src/serve/edit.zig:2328) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [writeLibComponent:2801](/home/epentland/ai/canopy/eda/src/serve/edit.zig:2801) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [writeNotesFile:265](/home/epentland/ai/canopy/eda/src/serve/notes.zig:265) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| mutation-boundary | [saveNotesApi:355](/home/epentland/ai/canopy/eda/src/serve/notes.zig:355) | `boundary-bypass` — `src/infra/atomic_write.zig::writeFile` |
| request-decoding | [editValueApi:136](/home/epentland/ai/canopy/eda/src/serve/edit.zig:136) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [editFootprintApi:347](/home/epentland/ai/canopy/eda/src/serve/edit.zig:347) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [addInstanceApi:528](/home/epentland/ai/canopy/eda/src/serve/edit.zig:528) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [newDesignApi:706](/home/epentland/ai/canopy/eda/src/serve/edit.zig:706) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [setBoardRoleApi:904](/home/epentland/ai/canopy/eda/src/serve/edit.zig:904) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [addSectionApi:996](/home/epentland/ai/canopy/eda/src/serve/edit.zig:996) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [renameSectionApi:1053](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1053) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [removeSectionApi:1110](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1110) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [addPortApi:1171](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1171) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [removePortApi:1226](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1226) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [renameRefdesApi:1274](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1274) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [setDnpApi:1345](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1345) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [removeInstanceApi:1414](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1414) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [rewirePinApi:1675](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1675) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [bindDecoupleApi:1791](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1791) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [duplicateInstanceApi:1886](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1886) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [renameNetApi:1983](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1983) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [movePinApi:2051](/home/epentland/ai/canopy/eda/src/serve/edit.zig:2051) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| request-decoding | [swapPinsApi:2127](/home/epentland/ai/canopy/eda/src/serve/edit.zig:2127) | `boundary-bypass` — `src/serve/edit.zig::parseJsonString` |
| edit-identity | [findInstanceOpen:1508](/home/epentland/ai/canopy/eda/src/serve/edit.zig:1508) | `identity-unverified` — `external.lastIndexOf` |

## Reproduce and interpret

```sh
zig-out/bin/guardian-check contract-audit /home/epentland/ai/canopy/eda --contracts examples/eda-contracts.toml --json
zig-out/bin/guardian-check int-from-float-budget /home/epentland/ai/canopy/eda --list
```

The new audit is independent of accepted baselines. It examines the declarations selected by the profile, not every possible persistence or request path in EDA. The profile is shipped in Guardian; EDA configuration was not changed, no findings were accepted there, and no EDA build or deployment was performed. Copy reviewed contracts into EDA’s `guardian.toml` to enforce them on future builds.

Contract violations are definite relative to this profile’s architectural policy. Runtime data loss, concurrency behavior and validator correctness still require the fault-injection and behavioral tests described in [the contract documentation](../operation-contracts.md).

Verification: 1,390 Zig tests passed; the 88-check Guardian gate had no blocking findings; CLI integration verified report counts, JSON framing, exit statuses, shared gate execution and read-only target behavior.
