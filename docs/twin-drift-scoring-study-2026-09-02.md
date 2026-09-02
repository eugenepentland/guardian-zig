# twin-drift scoring stability — measurement report

**Status: measurement only.** The prototype lives uncommitted in the worktree
`/home/epentland/ai/canopy/guardian-zig/.claude/worktrees/agent-ae881ab291caeb4ee`
(branch `worktree-agent-ae881ab291caeb4ee`), behind `GUARDIAN_TWIN_SCORE`, and
is not for merge. The shipped default path is byte-unchanged: with the variable
unset the check reproduces state 1's 125 frozen pairs exactly.

## Executive summary

1. **The instability is real, but it is a knife-edge, not a landslide.** Across
   the five merges, the corpus-wide idf produced exactly **one** finding whose
   two files had not changed a byte: `module_policy.stripUpper` ↔
   `pin_roles.normalizeIdent`, which crossed at state 3. Nothing ever
   *disappeared* from an untouched file.
2. **What makes it a knife-edge is that idf moves EVERY score, all the time.**
   Under idf, **128 of 174** untouched surviving pairs (74%) changed score
   across a step. The moves are small (mean 0.0004, max 0.0088) — but the
   at-risk population is 5 pairs sitting within 0.02 of the floor, and the two
   pairs the task names sat at **0.4927** and **0.4999** against a 0.5 floor.
   `writeJsonString`↔`route_review` was *one ten-thousandth* below blocking.
   That pair's score is a coin balanced on its edge; the only reason it never
   fell is that its own body was deleted at state 3.
3. **Removing idf does not help — it destroys the discrimination.** Both
   `quantized` and `flat` propose *both* known false positives at the 0.5 floor
   (padNets 0.85 / 0.81, placement 0.59 / 0.77, against idf's 0.44 / 0.33), and
   no floor rescues them: excluding padNets costs `quantized` 63 of its 125 true
   positives and `flat` 42. Their apparent stability is an artifact of scale —
   they were already pinned at 1.0000 on the very pairs that trouble idf.
4. **`frozen-idf` is the clean answer.** Freezing state 1's df table and reusing
   it for five subsequent merges reproduces `idf` **exactly** at every state,
   except that it never admits the one spurious pair. Recall 125/125, both known
   false positives rejected, score drift **identically zero** by construction,
   and +0.02 s per run.

---


Corpus: six read-only states of eda's `main`, extracted with `git archive`.

| state | commit | what merged | .zig files |
|---|---|---|---|
| 1 | `9a3da3e0` | before | 532 |
| 2 | `e1287ecd` | caches | 534 |
| 3 | `44978bfa` | escapers | 535 |
| 4 | `0b991aa6` | singles | 548 |
| 5 | `e6b1fc2b` | mid | 557 |
| 6 | `88b677f6` | DRC bridge | 563 |

Changed files between consecutive states (any src/*.zig whose bytes differ, including added/removed):

| step | files differing |
|---|---|
| 1->2 | 20 |
| 2->3 | 20 |
| 3->4 | 47 |
| 4->5 | 33 |
| 5->6 | 31 |

## Total pairs reported per state, and elapsed

| variant | s1 | s2 | s3 | s4 | s5 | s6 | elapsed s1 (s) | mean elapsed (s) |
|---|---|---|---|---|---|---|---|---|
| idf | 125 | 85 | 50 | 32 | 15 | 0 | 0.576 | 0.543 |
| quantized | 136 | 99 | 61 | 45 | 27 | 15 | 0.515 | 0.547 |
| quantized-norm | 125 | 92 | 57 | 40 | 22 | 10 | 0.518 | 0.503 |
| flat | 179 | 137 | 79 | 59 | 41 | 26 | 0.584 | 0.556 |
| flat-norm | 45 | 21 | 17 | 13 | 6 | 0 | 0.492 | 0.495 |
| samename | 69 | 31 | 23 | 19 | 12 | 7 | 0.474 | 0.477 |
| union | 139 | 97 | 57 | 39 | 22 | 7 | 0.546 | 0.599 |
| frozen-idf | 125 | 85 | 49 | 31 | 14 | 0 | 0.569 | 0.564 |

## Instability: pairs that move while BOTH their files stand still

A pair counted here appeared (or vanished) between two consecutive states even though neither of its two files changed a byte. Nothing about that pair was edited; only the rest of the corpus moved.

| variant | step | appeared-untouched | vanished-untouched | (appeared total) | (vanished total) |
|---|---|---|---|---|---|
| idf | 1->2 | 0 | 0 | 0 | 40 |
| idf | 2->3 | 1 | 0 | 1 | 36 |
| idf | 3->4 | 0 | 0 | 0 | 18 |
| idf | 4->5 | 0 | 0 | 0 | 17 |
| idf | 5->6 | 0 | 0 | 0 | 15 |
| quantized | 1->2 | 0 | 0 | 0 | 37 |
| quantized | 2->3 | 0 | 0 | 0 | 38 |
| quantized | 3->4 | 0 | 0 | 1 | 17 |
| quantized | 4->5 | 0 | 0 | 0 | 18 |
| quantized | 5->6 | 0 | 0 | 0 | 12 |
| quantized-norm | 1->2 | 1 | 0 | 1 | 34 |
| quantized-norm | 2->3 | 0 | 0 | 0 | 35 |
| quantized-norm | 3->4 | 0 | 0 | 0 | 17 |
| quantized-norm | 4->5 | 0 | 0 | 0 | 18 |
| quantized-norm | 5->6 | 0 | 0 | 0 | 12 |
| flat | 1->2 | 0 | 0 | 0 | 42 |
| flat | 2->3 | 0 | 0 | 0 | 58 |
| flat | 3->4 | 0 | 0 | 0 | 20 |
| flat | 4->5 | 0 | 0 | 0 | 18 |
| flat | 5->6 | 0 | 0 | 0 | 15 |
| flat-norm | 1->2 | 0 | 0 | 0 | 24 |
| flat-norm | 2->3 | 0 | 0 | 0 | 4 |
| flat-norm | 3->4 | 0 | 0 | 0 | 4 |
| flat-norm | 4->5 | 0 | 0 | 0 | 7 |
| flat-norm | 5->6 | 0 | 0 | 0 | 6 |
| samename | 1->2 | 0 | 0 | 0 | 38 |
| samename | 2->3 | 0 | 0 | 0 | 8 |
| samename | 3->4 | 0 | 0 | 0 | 4 |
| samename | 4->5 | 0 | 0 | 0 | 7 |
| samename | 5->6 | 0 | 0 | 0 | 5 |
| union | 1->2 | 0 | 0 | 0 | 42 |
| union | 2->3 | 1 | 0 | 1 | 41 |
| union | 3->4 | 0 | 0 | 0 | 18 |
| union | 4->5 | 0 | 0 | 0 | 17 |
| union | 5->6 | 0 | 0 | 0 | 15 |
| frozen-idf | 1->2 | 0 | 0 | 0 | 40 |
| frozen-idf | 2->3 | 0 | 0 | 0 | 36 |
| frozen-idf | 3->4 | 0 | 0 | 0 | 18 |
| frozen-idf | 4->5 | 0 | 0 | 0 | 17 |
| frozen-idf | 5->6 | 0 | 0 | 0 | 14 |

| variant | appeared-untouched (total) | vanished-untouched (total) | sum |
|---|---|---|---|
| idf | 1 | 0 | 1 |
| quantized | 0 | 0 | 0 |
| quantized-norm | 1 | 0 | 1 |
| flat | 0 | 0 | 0 |
| flat-norm | 0 | 0 | 0 |
| samename | 0 | 0 | 0 |
| union | 1 | 0 | 1 |
| frozen-idf | 0 | 0 | 0 |

### The untouched appearances, named

**idf**

| step | pair | LCS%% | score |
|---|---|---|---|
| 2->3 | `stripUpper|src/placement/module_policy.zig|normalizeIdent|src/placement/pin_roles.zig` | 90 | 0.5042 |

**quantized** — none.

**quantized-norm**

| step | pair | LCS%% | score |
|---|---|---|---|
| 1->2 | `kicadSchApi|src/serve/kicad_sch_export.zig|schematicPdfApi|src/serve/schematic_pdf.zig` | 72 | 0.5167 |

**flat** — none.

**flat-norm** — none.

**samename** — none.

**union**

| step | pair | LCS%% | score |
|---|---|---|---|
| 2->3 | `stripUpper|src/placement/module_policy.zig|normalizeIdent|src/placement/pin_roles.zig` | 90 | 0.5042 |

**frozen-idf** — none.

## Recall against state 1's 125 frozen pairs

| variant | frozen pairs proposed+reported | of 125 | extra pairs not in the baseline |
|---|---|---|---|
| idf | 125 | 100% | 0 |
| quantized | 117 | 94% | 19 |
| quantized-norm | 112 | 90% | 13 |
| flat | 125 | 100% | 54 |
| flat-norm | 45 | 36% | 0 |
| samename | 55 | 44% | 14 |
| union | 125 | 100% | 14 |
| frozen-idf | 125 | 100% | 0 |

### The named true positives (state 1)

| subject | idf | quantized | quantized-norm | flat | flat-norm | samename | union | frozen-idf |
|---|---|---|---|---|---|---|---|---|
| motivating pair | yes (0.68) | yes (0.96) | yes (0.89) | yes (0.98) | NO | yes (-1.00) | yes (0.68) | yes (0.68) |
| escaper family (21 in baseline) | 21 | 24 | 21 | 34 | 0 | 8 | 26 | 21 |
| shapeOfPoly / shapeFromWorldPoly / regionShape | 0 | 0 | 0 | 0 | 0 | 0 | 0 | 0 |
| isSafeLibName / isSafeFootprint | 1 | 1 | 1 | 1 | 1 | 0 | 1 | 1 |
| retainedSeedCopper / retainedCopper | 1 | 1 | 1 | 1 | 1 | 0 | 1 | 1 |

Escaper-family pairs in the state-1 baseline: `jsonString|src/kicad_sch/project.zig|writeJsonString|src/serve/library_3d.zig`, `jsonString|src/kicad_sch/project.zig|writeJsonStr|src/placement/progress.zig`, `jsonString|src/kicad_sch/project.zig|writeJsonStr|src/serve/pcb_fence.zig`, `jsonString|src/kicad_sch/project.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsString|src/render_html.zig|writeJsonString|src/serve/assembly_debug.zig`, `writeJsString|src/render_html.zig|writeJsonStr|src/serve/pcb_fence.zig`, `writeJsString|src/render_html.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsonString|src/serve/assembly_debug.zig|writeJsonStr|src/serve/pcb_fence.zig`, `writeJsonString|src/serve/assembly_debug.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsonString|src/serve/library_3d.zig|writeJsonStr|src/serve/pcb_fence.zig`, `writeJsonString|src/serve/library_3d.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsonStr|src/fab_readiness.zig|jsonString|src/kicad_sch/project.zig`, `writeJsonStr|src/fab_readiness.zig|writeJsString|src/render_html.zig`, `writeJsonStr|src/fab_readiness.zig|writeJsonString|src/serve/assembly_debug.zig`, `writeJsonStr|src/fab_readiness.zig|writeJsonString|src/serve/library_3d.zig`, `writeJsonStr|src/fab_readiness.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsonStr|src/placement/progress.zig|writeJsString|src/render_html.zig`, `writeJsonStr|src/placement/progress.zig|writeJsonString|src/serve/assembly_debug.zig`, `writeJsonStr|src/placement/progress.zig|writeJsonString|src/serve/library_3d.zig`, `writeJsonStr|src/placement/progress.zig|writeJsonStr|src/serve/trace_em_json.zig`, `writeJsonStr|src/serve/pcb_fence.zig|writeJsonStr|src/serve/trace_em_json.zig`

## Known false positives (state 1)

| variant | padNets reported | padNets cosine | placement reported | placement cosine |
|---|---|---|---|---|
| idf | no | 0.4410 | no | 0.3336 |
| quantized | yes: padNets|src/export_gerber.zig|padNets|src/placement/pour.zig | 0.8471 | yes: placement|src/placement/drc_keepout.zig|placement|src/subcircuit_silkscreen.zig | 0.5925 |
| quantized-norm | yes: padNets|src/export_gerber.zig|padNets|src/placement/pour.zig | 0.6930 | no | 0.4953 |
| flat | yes: padNets|src/export_gerber.zig|padNets|src/placement/pour.zig | 0.8102 | yes: placement|src/placement/drc_keepout.zig|placement|src/subcircuit_silkscreen.zig | 0.7714 |
| flat-norm | no | 0.2375 | no | 0.1566 |
| samename | yes: padNets|src/export_gerber.zig|padNets|src/placement/pour.zig | 0.4410 | yes: placement|src/placement/drc_keepout.zig|placement|src/subcircuit_silkscreen.zig | 0.3336 |
| union | yes: padNets|src/export_gerber.zig|padNets|src/placement/pour.zig | 0.4410 | yes: placement|src/placement/drc_keepout.zig|placement|src/subcircuit_silkscreen.zig | 0.3336 |
| frozen-idf | no | 0.4410 | no | 0.3336 |

## Score trace of the corpus-shift pairs (floor 0.5)

**module_policy.stripUpper <-> pin_roles.normalizeIdent**

| variant | s1 | s2 | s3 | s4 | s5 | s6 |
|---|---|---|---|---|---|---|
| idf | 0.4927 | 0.4996 | 0.5042 | 0.5047 | 0.5050 | 0.5051 |
| quantized | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| quantized-norm | 0.7643 | 0.7661 | 0.7843 | 0.7907 | 0.7907 | 0.7907 |
| flat | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 | 1.0000 |
| flat-norm | 0.2671 | 0.2731 | 0.2731 | 0.2731 | 0.2731 | 0.2731 |
| union | 0.4927 | 0.4996 | 0.5042 | 0.5047 | 0.5050 | 0.5051 |
| frozen-idf | 0.4927 | 0.4927 | 0.4927 | 0.4927 | 0.4927 | 0.4927 |

**assembly_debug.writeJsonString <-> route_review.writeJsonString**

| variant | s1 | s2 | s3 | s4 | s5 | s6 |
|---|---|---|---|---|---|---|
| idf | 0.4999 | 0.4998 | gone | gone | gone | gone |
| quantized | 0.5394 | 0.5394 | gone | gone | gone | gone |
| quantized-norm | 0.4013 | 0.4013 | gone | gone | gone | gone |
| flat | 0.8931 | 0.8931 | gone | gone | gone | gone |
| flat-norm | 0.2711 | 0.2711 | gone | gone | gone | gone |
| union | 0.4999 | 0.4998 | gone | gone | gone | gone |
| frozen-idf | 0.4999 | 0.4999 | gone | gone | gone | gone |

**drc_session.buildNetClassOverrides <-> wasm_drc.buildNetClassOverrides**

| variant | s1 | s2 | s3 | s4 | s5 | s6 |
|---|---|---|---|---|---|---|
| idf | 0.6819 | 0.6820 | 0.6818 | 0.6817 | 0.6817 | gone |
| quantized | 0.9554 | 0.9554 | 0.9554 | 0.9554 | 0.9554 | gone |
| quantized-norm | 0.8902 | 0.8902 | 0.8902 | 0.8902 | 0.8902 | gone |
| flat | 0.9817 | 0.9817 | 0.9817 | 0.9817 | 0.9817 | gone |
| flat-norm | 0.3952 | 0.3952 | 0.3952 | 0.3952 | 0.3952 | gone |
| union | 0.6819 | 0.6820 | 0.6818 | 0.6817 | 0.6817 | gone |
| frozen-idf | 0.6819 | 0.6819 | 0.6819 | 0.6819 | 0.6819 | gone |

## Score drift of pairs whose two files did not change

For every pair reported in BOTH state k and k+1 whose two files are byte-identical across the step, `|score(k+1) - score(k)|`. This is the corpus-shift effect measured directly: any nonzero value is a score that moved with no edit to either copy.

| variant | step | pairs compared | mean abs delta | max abs delta | pairs whose score moved at all |
|---|---|---|---|---|---|
| idf | 1->2 | 78 | 0.00048 | 0.00670 | 65 |
| idf | 2->3 | 49 | 0.00051 | 0.00880 | 29 |
| idf | 3->4 | 32 | 0.00030 | 0.00330 | 25 |
| idf | 4->5 | 15 | 0.00011 | 0.00050 | 9 |
| idf | 5->6 | 0 | - | - | - |
| quantized | 1->2 | 89 | 0.00036 | 0.02770 | 5 |
| quantized | 2->3 | 58 | 0.00037 | 0.00640 | 11 |
| quantized | 3->4 | 41 | 0.00007 | 0.00200 | 2 |
| quantized | 4->5 | 26 | 0.00022 | 0.00560 | 2 |
| quantized | 5->6 | 13 | 0.00110 | 0.00980 | 4 |
| quantized-norm | 1->2 | 83 | 0.00009 | 0.00220 | 8 |
| quantized-norm | 2->3 | 55 | 0.00084 | 0.01820 | 12 |
| quantized-norm | 3->4 | 37 | 0.00028 | 0.00640 | 3 |
| quantized-norm | 4->5 | 22 | 0.00028 | 0.00610 | 1 |
| quantized-norm | 5->6 | 8 | 0.00045 | 0.00360 | 1 |
| flat | 1->2 | 123 | 0.00060 | 0.04750 | 8 |
| flat | 2->3 | 74 | 0.00003 | 0.00100 | 2 |
| flat | 3->4 | 54 | 0.00003 | 0.00160 | 1 |
| flat | 4->5 | 39 | 0.00016 | 0.00640 | 1 |
| flat | 5->6 | 22 | 0.00000 | 0.00000 | 0 |
| flat-norm | 1->2 | 21 | 0.00020 | 0.00410 | 1 |
| flat-norm | 2->3 | 17 | 0.00000 | 0.00000 | 0 |
| flat-norm | 3->4 | 13 | 0.00000 | 0.00000 | 0 |
| flat-norm | 4->5 | 6 | 0.00000 | 0.00000 | 0 |
| flat-norm | 5->6 | 0 | - | - | - |
| union | 1->2 | 78 | 0.00048 | 0.00670 | 65 |
| union | 2->3 | 49 | 0.00051 | 0.00880 | 29 |
| union | 3->4 | 32 | 0.00030 | 0.00330 | 25 |
| union | 4->5 | 15 | 0.00011 | 0.00050 | 9 |
| union | 5->6 | 0 | - | - | - |
| frozen-idf | 1->2 | 78 | 0.00000 | 0.00000 | 0 |
| frozen-idf | 2->3 | 49 | 0.00000 | 0.00000 | 0 |
| frozen-idf | 3->4 | 31 | 0.00000 | 0.00000 | 0 |
| frozen-idf | 4->5 | 14 | 0.00000 | 0.00000 | 0 |
| frozen-idf | 5->6 | 0 | - | - | - |

| variant | mean abs delta (all steps) | max abs delta (all steps) |
|---|---|---|
| idf | 0.00042 | 0.00880 |
| quantized | 0.00034 | 0.02770 |
| quantized-norm | 0.00036 | 0.01820 |
| flat | 0.00027 | 0.04750 |
| flat-norm | 0.00007 | 0.00410 |
| union | 0.00042 | 0.00880 |
| frozen-idf | 0.00000 | 0.00000 |

## How many reported pairs sit within 0.02 of the 0.5 floor

The population at risk of crossing on the next unrelated deletion.

| variant | s1 | s2 | s3 | s4 | s5 | s6 |
|---|---|---|---|---|---|---|
| idf | 5 | 3 | 2 | 1 | 1 | 0 |
| quantized | 5 | 2 | 2 | 3 | 2 | 1 |
| quantized-norm | 4 | 4 | 4 | 4 | 2 | 1 |
| flat | 2 | 1 | 1 | 1 | 0 | 0 |
| flat-norm | 4 | 3 | 2 | 1 | 1 | 0 |
| union | 5 | 3 | 2 | 1 | 1 | 0 |
| frozen-idf | 5 | 4 | 3 | 2 | 0 | 0 |

## Floor sweep on state 1: can a higher floor rescue `quantized` / `flat`?

Raising the pair floor only removes pairs, so this is read straight off the state-1 run. `TP` = of the 125 frozen pairs; `FP` = the two known false positives still reported.

| variant | floor | TP of 125 | FPs still in | total pairs |
|---|---|---|---|---|
| idf | 0.50 | 125 | none | 125 |
| idf | 0.60 | 82 | none | 82 |
| idf | 0.70 | 46 | none | 46 |
| idf | 0.80 | 15 | none | 15 |
| idf | 0.85 | 8 | none | 8 |
| idf | 0.90 | 2 | none | 2 |
| idf | 0.95 | 0 | none | 0 |
| quantized | 0.50 | 117 | padNets, placement | 136 |
| quantized | 0.60 | 101 | padNets | 113 |
| quantized | 0.70 | 89 | padNets | 97 |
| quantized | 0.80 | 66 | padNets | 72 |
| quantized | 0.85 | 62 | none | 67 |
| quantized | 0.90 | 46 | none | 50 |
| quantized | 0.95 | 27 | none | 30 |
| quantized-norm | 0.50 | 112 | padNets | 125 |
| quantized-norm | 0.60 | 97 | padNets | 106 |
| quantized-norm | 0.70 | 56 | none | 60 |
| quantized-norm | 0.80 | 37 | none | 38 |
| quantized-norm | 0.85 | 28 | none | 28 |
| quantized-norm | 0.90 | 16 | none | 16 |
| quantized-norm | 0.95 | 2 | none | 2 |
| flat | 0.50 | 125 | padNets, placement | 179 |
| flat | 0.60 | 124 | padNets, placement | 165 |
| flat | 0.70 | 119 | padNets, placement | 153 |
| flat | 0.80 | 108 | padNets | 129 |
| flat | 0.85 | 83 | none | 94 |
| flat | 0.90 | 64 | none | 69 |
| flat | 0.95 | 44 | none | 47 |
| flat-norm | 0.50 | 45 | none | 45 |
| flat-norm | 0.60 | 29 | none | 29 |
| flat-norm | 0.70 | 5 | none | 5 |
| flat-norm | 0.80 | 1 | none | 1 |
| flat-norm | 0.85 | 0 | none | 0 |
| flat-norm | 0.90 | 0 | none | 0 |
| flat-norm | 0.95 | 0 | none | 0 |
| union | 0.50 | 125 | none | 125 |
| union | 0.60 | 82 | none | 82 |
| union | 0.70 | 46 | none | 46 |
| union | 0.80 | 15 | none | 15 |
| union | 0.85 | 8 | none | 8 |
| union | 0.90 | 2 | none | 2 |
| union | 0.95 | 0 | none | 0 |
| frozen-idf | 0.50 | 125 | none | 125 |
| frozen-idf | 0.60 | 82 | none | 82 |
| frozen-idf | 0.70 | 46 | none | 46 |
| frozen-idf | 0.80 | 15 | none | 15 |
| frozen-idf | 0.85 | 8 | none | 8 |
| frozen-idf | 0.90 | 2 | none | 2 |
| frozen-idf | 0.95 | 0 | none | 0 |

`union`'s name-proposed component carries no score, so every floor above 0.5 drops it and the `union` rows collapse onto `idf`. Read `union` only at floor 0.50.

## `frozen-idf`: what a five-merge-stale df table costs

The table is dumped from state 1 and reused unchanged for states 2-6; a shingle the table has never seen falls back to its live df.

Table: 264931 shingles, 5.9 MB on disk. Mean run time 0.564 s vs `idf`'s 0.543 s.

| state | idf pairs | frozen-idf pairs | only under idf | only under frozen-idf |
|---|---|---|---|---|
| 1 | 125 | 125 | - | - |
| 2 | 85 | 85 | - | - |
| 3 | 50 | 49 | `stripUpper|src/placement/module_policy.zig|normalizeIdent|src/placement/pin_roles.zig` | - |
| 4 | 32 | 31 | `stripUpper|src/placement/module_policy.zig|normalizeIdent|src/placement/pin_roles.zig` | - |
| 5 | 15 | 14 | `stripUpper|src/placement/module_policy.zig|normalizeIdent|src/placement/pin_roles.zig` | - |
| 6 | 0 | 0 | - | - |


---

## Reading notes and caveats

**`quantized` / `flat` as literally specified drop over-`max_df` shingles from
the norm as well as the numerator.** That is not what `idf` does — `idf` keeps
every boilerplate shingle's mass in the denominator, which deflates every one of
its cosines. Comparing the three at one 0.5 floor is therefore not
apples-to-apples, so `quantized-norm` and `flat-norm` were added: identical
weights, but the norm left complete so the vector geometry matches `idf`'s. The
result says the scale gap was indeed most of the story (`padNets` falls 0.85 →
0.69 under quantized-norm, and `placement` falls out of the report entirely at
0.4953) — but even norm-corrected, `quantized-norm` still reports `padNets`,
still loses 13 of the 125 true positives, and still produced an untouched
appearance of its own. `flat-norm` overcorrects: 36% recall, and it misses the
motivating `buildNetClassOverrides` pair outright (0.3952). **No unweighted or
step-weighted scheme reproduces idf's separation.** The separation is the
continuous idf.

**The `shapeOfPoly` / `shapeFromWorldPoly` / `regionShape` family is absent from
every variant, correctly.** All three bodies are byte-identical after
normalisation in state 1 (cosine 1.0000 under flat), so `report_identical =
false` suppresses them as duplication debt rather than drift. They are not in
state 1's baseline either. That row is a zero in every column by design, not a
recall failure.

**`assembly_debug.writeJsonString` is gone from state 3 onward** — the escapers
merge deleted it. The six snapshots are merge *endpoints*; the working tree
during a merge is a corpus the snapshots do not contain, which is the most
likely place the reported crossing of that pair actually happened. Its measured
0.4998 at state 2 is consistent with that: a partially-applied deletion moves the
score by more than the 0.0001 it needed.

**`samename` is v1 and reproduces v1's known shape**: 69 pairs, 55 of the 125
frozen (44%), and it reports both known false positives with no score to
threshold on — it cannot reject them at all, because it never measured anything.
It is perfectly stable (0 untouched moves, by construction: a name does not
depend on the corpus), and that stability is worthless because it is also blind
to the 70 renamed copies. `union` inherits idf's single instability event *and*
samename's two false positives: strictly the worst of both.

**Elapsed is flat across every variant** (0.47–0.61 s on the largest state, all
within noise of each other on a shared box). Scoring is not the cost; the LCS
and the parse are. Stability here is free.

**Method.** Each state was extracted read-only with `git archive <commit> src
guardian.toml SPEC.md .guardian`. Each variant ran
`guardian-check twin-drift <tree> --dry-run` (no baseline filtering, writes
nothing) with `GUARDIAN_TWIN_SCORE=<variant>`; the prototype dumps every
reported pair's **identity key** (`nameA|fileA|nameB|fileB`, the same string
`identityFor` builds and the baseline stores) plus its LCS percent and proposing
score, so set comparison never parses prose. "Untouched" means both of the
pair's files are byte-identical (md5) between the two states compared. Probes
(`GUARDIAN_TWIN_PROBE`) compute the same truncated cosine `cosinePairs`
accumulates for a named pair regardless of the floor, which is how below-floor
scores are traced. The df-table freeze is implemented by substituting the
weighting df (`Corpus.wdf`/`wn`) while the posting counts stay live, so the
index allocation is unaffected.

## Recommendation

**Keep the idf weighting, freeze the table, leave the floor at 0.5.** The idf is
not an incidental normalisation — it is the entire discriminator: it is the only
scheme measured that both keeps all 125 true positives and rejects both known
false positives at 0.5, and the margins it does that on (0.44 and 0.33 against a
0.5 floor) are far wider than the margins it holds its true positives by. Every
attempt to make the weight corpus-independent (`quantized`, `flat`, and their
norm-corrected forms) buys stability by giving that separation back, and no
floor recovers it. The instability is therefore not in the *shape* of the weight
but in the *liveness of the df table*, and freezing the table removes it exactly:
`frozen-idf` matched `idf` pair-for-pair across five merges of staleness while
being the only variant whose untouched scores are provably, identically
constant. The practical form is to store the df table (or a bucketed digest of
it — 265k shingles is 5.9 MB raw, and the study shows scores need only ~3 decimal
places of df fidelity) beside the baseline in `.guardian/`, refresh it on
`accept` alongside the snapshot, and fall back to live df for shingles the table
has never seen. **The sibling agent's diff-aware blocking is still needed on top,
and is the more important of the two.** Freezing the table fixes drift caused by
*Guardian's own scoring*; it does nothing about a pair that genuinely crosses
because someone edited a third file in a way that makes two others match, and
nothing about the far commoner case of a pre-existing pair surfacing under a
commit that did not touch either copy. A frozen table also has to be refreshed
eventually, and every refresh is a fresh opportunity for exactly this class of
appearance — diff-aware blocking is what makes that refresh safe to perform.
Freeze the table to reduce the noise; keep diff-aware blocking as the thing that
decides whether noise can fail a commit.
