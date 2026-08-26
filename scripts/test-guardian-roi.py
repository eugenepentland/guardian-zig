#!/usr/bin/env python3
"""Black-box self-tests for scripts/guardian-roi."""

from __future__ import annotations

import fcntl
import json
import subprocess
import tempfile
import time
import unittest
from pathlib import Path
from typing import Any


SCRIPT = Path(__file__).with_name("guardian-roi")
CATEGORIES = (
    "defect",
    "useful-review",
    "intentional-change",
    "false-positive",
)


def write_jsonl(path: Path, records: list[Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("w", encoding="utf-8") as stream:
        for record in records:
            if isinstance(record, str):
                stream.write(record + "\n")
            else:
                stream.write(json.dumps(record) + "\n")


class GuardianRoiTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.project = Path(self.temp.name)
        self.cache = self.project / ".guardian" / "cache"
        write_jsonl(
            self.cache / "check-roi.jsonl",
            [
                "not json",
                {"type": "future_event", "schema": 1},
                {
                    "type": "accept",
                    "schema": 1,
                    "guardian_digest": "guardian-a",
                    "phase": "complete",
                    "outcome": "green",
                    "duration_ms": 9,
                    "observation_ids": ["event-only-observation"],
                },
                {
                    "type": "commit",
                    "schema": 1,
                    "guardian_digest": "guardian-a",
                    "phase": "complete",
                    "outcome": "green",
                    "duration_ms": 100,
                    "gate_duration_ms": 40,
                    "test_duration_ms": 60,
                },
                {
                    "type": "commit",
                    "schema": 1,
                    "guardian_digest": "guardian-a",
                    "phase": "gate",
                    "outcome": "red",
                    "duration_ms": 21,
                    "gate_duration_ms": 20,
                },
                {
                    "type": "check_run",
                    "schema": 2,
                    "checks": [{"check": "future", "findings": 99}],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "scope_mode": "full",
                    "outcome": "failed",
                    "cached": False,
                    "checks": [{"check": "bad-run-outcome"}],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "scope_mode": "cache",
                    "outcome": "green",
                    "cached": True,
                    "checks": [{"check": "bad-run-scope"}],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 100,
                    "commit": "abc123",
                    "guardian_digest": "guardian-a",
                    "origin": "all",
                    "phase": "gate",
                    "scope_mode": "full",
                    "outcome": "red",
                    "duration_ms": 50,
                    "check_phase_ms": 30,
                    "cached": False,
                    "checks": [
                        {
                            "check": "alpha",
                            "policy": "block",
                            "outcome": "failed",
                            "duration_ms": 10,
                            "findings": 2,
                            "warnings": 1,
                            "deferred": 1,
                            "observations": [
                                {
                                    "observation_id": "obs-a",
                                    "finding_key": "src/a.zig|first",
                                    "file": "src/a.zig",
                                    "line": 4,
                                },
                                {
                                    "id": "obs-b",
                                    "finding_key": "src/b.zig|second",
                                    "file": "src/b.zig",
                                    "line": 8,
                                },
                            ],
                        },
                        {
                            "check": "beta",
                            "policy": "report",
                            "outcome": "passed",
                            "duration_ms": 30,
                            "findings": 0,
                            "warnings": 1,
                            "observations": [
                                {
                                    "observation_id": "obs-warning",
                                    "finding_key": "beta|src/warn.zig|advisory",
                                    "file": "src/warn.zig",
                                    "line": 9,
                                }
                            ],
                        },
                    ],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 200,
                    "commit": "abc123",
                    "guardian_digest": "guardian-a",
                    "origin": "accept",
                    "phase": "preview",
                    "scope_mode": "full",
                    "outcome": "red",
                    "duration_ms": 25,
                    "check_phase_ms": 20,
                    "cached": False,
                    "checks": [
                        {
                            "check": "alpha",
                            "policy": "block",
                            "outcome": "failed",
                            "duration_ms": 20,
                            "findings": 1,
                            "warnings": 0,
                            "observations": [
                                {
                                    "observation_id": "obs-a",
                                    "finding_key": "src/a.zig|first",
                                    "file": "src/a.zig",
                                    "line": 5,
                                }
                            ],
                        }
                    ],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 300,
                    "commit": "abc123",
                    "guardian_digest": "guardian-a",
                    "origin": "accept",
                    "phase": "update",
                    "scope_mode": "filtered",
                    "outcome": "green",
                    "duration_ms": 9,
                    "check_phase_ms": 7,
                    "cached": False,
                    "checks": [
                        {
                            "check": "alpha",
                            "policy": "block",
                            "outcome": "passed",
                            "duration_ms": 7,
                            "findings": 0,
                            "warnings": 0,
                            "observations": [],
                        }
                    ],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 400,
                    "commit": "abc123",
                    "guardian_digest": "guardian-a",
                    "origin": "accept",
                    "phase": "verify",
                    "scope_mode": "filtered",
                    "outcome": "green",
                    "duration_ms": 10,
                    "check_phase_ms": 8,
                    "cached": False,
                    "checks": [
                        {
                            "check": "alpha",
                            "policy": "block",
                            "outcome": "passed",
                            "duration_ms": 8,
                            "findings": 0,
                            "warnings": 1,
                            "observations": [
                                {
                                    "observation_id": "obs-a",
                                    "finding_key": "src/a.zig|first",
                                    "file": "src/a.zig",
                                    "line": 6,
                                }
                            ],
                        }
                    ],
                },
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 500,
                    "commit": "abc123",
                    "guardian_digest": "guardian-a",
                    "origin": "all",
                    "phase": "gate",
                    "scope_mode": "full",
                    "outcome": "green",
                    "duration_ms": 2,
                    "check_phase_ms": 0,
                    "cached": True,
                    "checks": [
                        {
                            "check": "stale-cache-data",
                            "duration_ms": 999,
                            "findings": 99,
                        }
                    ],
                },
            ],
        )

    def tearDown(self) -> None:
        self.temp.cleanup()

    def run_cli(self, *args: str, success: bool = True) -> subprocess.CompletedProcess[str]:
        result = subprocess.run(
            [str(SCRIPT), *args],
            check=False,
            text=True,
            capture_output=True,
        )
        if success and result.returncode != 0:
            self.fail(f"command failed: {result.stderr}")
        return result

    def append_alpha_occurrence(
        self,
        observation_id: str,
        *,
        timestamp_ms: int,
        commit: str,
        guardian_digest: str = "guardian-a",
    ) -> None:
        with (self.cache / "check-roi.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {
                        "type": "check_run",
                        "schema": 1,
                        "timestamp_ms": timestamp_ms,
                        "commit": commit,
                        "guardian_digest": guardian_digest,
                        "origin": "all",
                        "phase": "gate",
                        "scope_mode": "full",
                        "outcome": "red",
                        "duration_ms": 12,
                        "check_phase_ms": 10,
                        "cached": False,
                        "checks": [
                            {
                                "check": "alpha",
                                "policy": "block",
                                "outcome": "failed",
                                "duration_ms": 10,
                                "findings": 1,
                                "warnings": 0,
                                "observations": [
                                    {
                                        "observation_id": observation_id,
                                        "finding_key": "src/a.zig|first",
                                        "file": "src/a.zig",
                                        "line": 6,
                                    }
                                ],
                            }
                        ],
                    }
                )
                + "\n"
            )

    def test_pending_lists_unique_unlabeled_observations(self) -> None:
        result = self.run_cli("pending", str(self.project), "--observations")
        self.assertEqual(1, result.stdout.count("obs-a"))
        self.assertEqual(1, result.stdout.count("obs-b"))
        self.assertEqual(1, result.stdout.count("obs-warning"))
        self.assertIn("src/a.zig:6", result.stdout)
        self.assertIn("guardian-a", result.stdout)
        self.assertIn("direct:accept,all", result.stdout)
        self.assertNotIn("event-only-observation", result.stdout)
        self.assertNotIn("future", result.stdout)

    def test_pending_groups_recurring_observations_and_subject_label_persists(self) -> None:
        self.append_alpha_occurrence(
            "obs-a-next", timestamp_ms=800, commit="def456"
        )
        pending = self.run_cli("pending", str(self.project))
        self.assertEqual(3, pending.stdout.count("subj_"))
        alpha_line = next(
            line for line in pending.stdout.splitlines() if "src/a.zig" in line
        )
        fields = [field.strip() for field in alpha_line.split("|")]
        subject_id = fields[1]
        self.assertEqual("2", fields[4])

        self.run_cli(
            "label-subject",
            str(self.project),
            subject_id,
            "defect",
            "--minutes",
            "5",
        )
        self.append_alpha_occurrence(
            "obs-a-future", timestamp_ms=900, commit="ghi789"
        )
        after = self.run_cli("pending", str(self.project))
        self.assertNotIn(subject_id, after.stdout)
        observation_view = self.run_cli(
            "pending", str(self.project), "--observations"
        )
        self.assertNotIn("obs-a-future", observation_view.stdout)

        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        self.assertEqual(4, alpha["unique_observations"])
        self.assertEqual(2, alpha["unique_subjects"])
        self.assertEqual(1, alpha["labeled_subjects"])
        self.assertEqual(3, alpha["labeled_observations"])
        self.assertEqual(1, alpha["categories"]["defect"])
        self.assertEqual(5, alpha["triage_minutes_total"])

        (self.cache / "check-roi.jsonl").unlink()
        rotated = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        self.assertEqual(1, rotated["historical_labels"]["labeled_observations"])
        self.assertEqual(1, rotated["historical_labels"]["categories"]["defect"])
        self.run_cli(
            "label-subject", str(self.project), subject_id, "useful-review"
        )

    def test_latest_subject_or_observation_label_wins_for_the_subject(self) -> None:
        pending = self.run_cli("pending", str(self.project))
        alpha_line = next(
            line for line in pending.stdout.splitlines() if "src/a.zig" in line
        )
        subject_id = [field.strip() for field in alpha_line.split("|")][1]
        self.run_cli(
            "label-subject", str(self.project), subject_id, "defect"
        )
        self.run_cli("label", str(self.project), "obs-a", "useful-review")
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        self.assertEqual(0, alpha["categories"]["defect"])
        self.assertEqual(1, alpha["categories"]["useful-review"])

        self.run_cli(
            "label-subject", str(self.project), subject_id, "false-positive"
        )
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        self.assertEqual(0, alpha["categories"]["useful-review"])
        self.assertEqual(1, alpha["categories"]["false-positive"])

    def test_same_finding_key_in_a_new_guardian_digest_is_a_new_subject(self) -> None:
        before = self.run_cli("pending", str(self.project))
        old_line = next(
            line for line in before.stdout.splitlines() if "src/a.zig" in line
        )
        old_subject = [field.strip() for field in old_line.split("|")][1]
        self.append_alpha_occurrence(
            "obs-a-new-digest",
            timestamp_ms=950,
            commit="new123",
            guardian_digest="guardian-new",
        )
        current = self.run_cli("pending", str(self.project))
        new_line = next(
            line for line in current.stdout.splitlines() if "src/a.zig" in line
        )
        new_subject = [field.strip() for field in new_line.split("|")][1]
        self.assertNotEqual(old_subject, new_subject)
        self.assertNotIn(old_subject, current.stdout)
        retained = self.run_cli("pending", str(self.project), "--all")
        self.assertIn(old_subject, retained.stdout)
        self.assertIn(new_subject, retained.stdout)

    def test_label_appends_and_latest_valid_label_wins(self) -> None:
        self.run_cli(
            "label",
            str(self.project),
            "obs-a",
            "defect",
            "--minutes",
            "4.5",
            "--cycles",
            "1",
            "--note",
            "fixed locally",
        )
        self.run_cli(
            "label",
            str(self.project),
            "obs-a",
            "useful-review",
            "--reason",
            "reclassified",
        )
        write_jsonl(
            self.cache / "extra-labels.jsonl",
            [],
        )
        with (self.cache / "check-roi-labels.jsonl").open("a", encoding="utf-8") as stream:
            stream.write("malformed\n")
            stream.write(
                json.dumps(
                    {
                        "type": "label",
                        "schema": 2,
                        "observation_id": "obs-b",
                        "category": "defect",
                    }
                )
                + "\n"
            )

        pending = self.run_cli("pending", str(self.project), "--observations")
        self.assertNotIn("obs-a", pending.stdout)
        self.assertIn("obs-b", pending.stdout)

        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        self.assertEqual(1, alpha["categories"]["useful-review"])
        self.assertEqual(100.0, alpha["category_rates_pct"]["useful-review"])
        self.assertEqual(0, alpha["categories"]["defect"])
        self.assertIsNone(alpha["actionable_per_100_runs"])
        self.assertEqual(100.0, alpha["known_actionable_per_100_runs"])
        self.assertIsNone(alpha["triage_minutes_total"])
        self.assertIsNone(alpha["known_triage_minutes_total"])
        self.assertEqual(1, alpha["missing_triage_minutes"])
        with (self.cache / "check-roi-labels.jsonl").open(encoding="utf-8") as stream:
            lines = stream.readlines()
        latest = json.loads(lines[1])
        self.assertEqual("alpha", latest["check"])
        self.assertEqual("abc123", latest["commit"])
        self.assertEqual("guardian-a", latest["guardian_digest"])
        self.assertEqual("src/a.zig|first", latest["finding_key"])
        self.assertEqual("src/a.zig", latest["file"])
        self.assertEqual(6, latest["line"])

    def test_json_summary_counts_invocations_without_summing_parallel_times(self) -> None:
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        self.assertEqual("guardian-a", summary["headline_guardian_digest"])
        self.assertEqual(2, summary["invocations"])
        self.assertEqual(1, summary["cached_invocations"])
        self.assertEqual(2, summary["check_executions"])
        self.assertEqual(
            {"median": 26.0, "p95": 50.0, "samples": 2},
            summary["duration_ms"],
        )
        self.assertEqual(3, summary["unique_observations"])
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        beta = next(row for row in summary["checks"] if row["check"] == "beta")
        self.assertEqual(1, alpha["executions"])
        self.assertEqual(1, alpha["analysis_runs"])
        self.assertEqual(2, alpha["internal_followup_executions"])
        self.assertEqual(2, alpha["observation_occurrences"])
        self.assertEqual(0, alpha["recurrences"])
        self.assertEqual(2, alpha["unique_subjects"])
        self.assertEqual(1, alpha["deferred"])
        self.assertEqual(
            {"gate": 1, "preview": 1, "update": 1, "verify": 1},
            alpha["phases"],
        )
        self.assertEqual(100.0, alpha["firing_rate_pct"])
        self.assertEqual(
            {"median": 10.0, "p95": 10.0, "samples": 1},
            alpha["duration_ms"],
        )
        self.assertEqual(0, alpha["slowest_run_count"])
        self.assertEqual(4, alpha["all_retained"]["executions"])
        self.assertEqual(2, alpha["all_retained"]["analysis_runs"])
        self.assertEqual(1, alpha["all_retained"]["recurrences"])
        self.assertEqual(3, alpha["origin_breakdown"]["accept"]["executions"])
        self.assertEqual(1, alpha["origin_breakdown"]["accept"]["analysis_runs"])
        self.assertEqual(100.0, beta["firing_rate_pct"])
        self.assertEqual(1, beta["warnings"])
        self.assertEqual(1, beta["slowest_run_count"])
        self.assertFalse(
            any(row["check"] == "stale-cache-data" for row in summary["checks"])
        )
        self.assertFalse(
            any(row["check"].startswith("bad-run-") for row in summary["checks"])
        )
        self.assertNotIn("total_duration_ms", summary)
        self.assertEqual(3, summary["events"]["count"])
        self.assertNotIn("future_event", summary["events"]["by_type"])
        commit = summary["events"]["by_type"]["commit"]
        self.assertEqual({"green": 1, "red": 1}, commit["outcomes"])
        self.assertEqual(
            {"median": 30.0, "p95": 40.0, "samples": 2},
            commit["gate_duration_ms"],
        )
        self.assertEqual(
            {"median": 60.0, "p95": 60.0, "samples": 1},
            commit["test_duration_ms"],
        )

    def test_markdown_is_default_and_explains_unknown_costs(self) -> None:
        result = self.run_cli("summary", str(self.project))
        self.assertIn("# Guardian check ROI", result.stdout)
        self.assertIn("## Workflow events", result.stdout)
        self.assertIn("green=1, red=1", result.stdout)
        self.assertIn("missing cost remains unknown", result.stdout)

    def test_unknown_observation_and_bad_cost_fail_without_writing(self) -> None:
        unknown = self.run_cli(
            "label", str(self.project), "missing", "defect", success=False
        )
        self.assertEqual(2, unknown.returncode)
        self.assertIn("unknown observation ID", unknown.stderr)
        invalid = self.run_cli(
            "label",
            str(self.project),
            "obs-a",
            "defect",
            "--minutes",
            "-1",
            success=False,
        )
        self.assertEqual(2, invalid.returncode)
        self.assertFalse((self.cache / "check-roi-labels.jsonl").exists())

    def test_concurrent_labels_are_complete_json_lines(self) -> None:
        processes = [
            subprocess.Popen(
                [
                    str(SCRIPT),
                    "label",
                    str(self.project),
                    "obs-a",
                    CATEGORIES[index % len(CATEGORIES)],
                    "--note",
                    f"writer {index}",
                ],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            for index in range(12)
        ]
        for process in processes:
            stdout, stderr = process.communicate(timeout=10)
            self.assertEqual(0, process.returncode, stderr)
            self.assertIn("Labeled obs-a", stdout)

        with (self.cache / "check-roi-labels.jsonl").open(encoding="utf-8") as stream:
            records = [json.loads(line) for line in stream]
        self.assertEqual(12, len(records))
        self.assertTrue(all(record["observation_id"] == "obs-a" for record in records))

    def test_label_context_survives_raw_rotation_and_old_labels_still_work(self) -> None:
        self.run_cli(
            "label", str(self.project), "obs-a", "defect", "--minutes", "3"
        )
        with (self.cache / "check-roi-labels.jsonl").open("a", encoding="utf-8") as stream:
            # Backward-compatible v1 label written before context snapshots.
            stream.write(
                json.dumps(
                    {
                        "type": "label",
                        "schema": 1,
                        "observation_id": "obs-b",
                        "category": "false-positive",
                    }
                )
                + "\n"
            )
        before = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha_before = next(
            row for row in before["checks"] if row["check"] == "alpha"
        )
        self.assertEqual(2, alpha_before["labeled_observations"])

        (self.cache / "check-roi.jsonl").unlink()
        after = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha_after = next(
            row for row in after["checks"] if row["check"] == "alpha"
        )
        self.assertEqual(0, after["all_retained"]["labeled_observations"])
        self.assertEqual(1, after["historical_labels"]["labeled_observations"])
        self.assertEqual(0, after["retained_labeled_observations"])
        self.assertEqual(1, after["unattributed_labels"])
        self.assertEqual(
            1,
            alpha_after["cohorts"]["guardian-a"]["historical_labels"][
                "categories"
            ]["defect"],
        )
        self.assertEqual(1, alpha_after["historical_labels"]["labeled_observations"])

    def test_accept_only_newest_digest_leaves_direct_headline_empty(self) -> None:
        with (self.cache / "check-roi.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {
                        "type": "check_run",
                        "schema": 1,
                        "timestamp_ms": 900,
                        "guardian_digest": "guardian-new",
                        "origin": "accept",
                        "phase": "preview",
                        "scope_mode": "filtered",
                        "cached": False,
                        "outcome": "red",
                        "duration_ms": 11,
                        "check_phase_ms": 10,
                        "checks": [
                            {
                                "check": "zeta",
                                "policy": "block",
                                "outcome": "failed",
                                "duration_ms": 10,
                                "findings": 1,
                                "warnings": 0,
                                "observations": [
                                    {
                                        "observation_id": "obs-accept-only",
                                        "finding_key": "zeta|workflow",
                                        "file": "src/zeta.zig",
                                        "line": 1,
                                    }
                                ],
                            }
                        ],
                    }
                )
                + "\n"
            )
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        self.assertEqual("guardian-new", summary["headline_guardian_digest"])
        self.assertEqual(["all", "build"], summary["headline_origins"])
        self.assertEqual(0, summary["invocations"])
        self.assertEqual(0, summary["check_executions"])
        self.assertEqual(0, summary["unique_observations"])
        zeta = next(row for row in summary["checks"] if row["check"] == "zeta")
        self.assertEqual(0, zeta["executions"])
        self.assertEqual(1, zeta["cohorts"]["guardian-new"]["executions"])

    def test_historical_label_never_enters_current_rate_denominator(self) -> None:
        self.run_cli("label", str(self.project), "obs-a", "defect")
        write_jsonl(
            self.cache / "check-roi.jsonl",
            [
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 1000,
                    "guardian_digest": "guardian-a",
                    "origin": "all",
                    "phase": None,
                    "scope_mode": "full",
                    "cached": False,
                    "outcome": "red",
                    "duration_ms": 12,
                    "check_phase_ms": 10,
                    "checks": [
                        {
                            "check": "alpha",
                            "policy": "block",
                            "outcome": "failed",
                            "duration_ms": 10,
                            "findings": 1,
                            "warnings": 0,
                            "observations": [
                                {
                                    "observation_id": "obs-new",
                                    "finding_key": "alpha|new",
                                    "file": "src/new.zig",
                                    "line": 2,
                                }
                            ],
                        }
                    ],
                }
            ],
        )
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        alpha = next(row for row in summary["checks"] if row["check"] == "alpha")
        self.assertEqual(1, summary["unique_observations"])
        self.assertEqual(0, summary["labeled_observations"])
        self.assertEqual(1, summary["pending_observations"])
        self.assertEqual(0.0, summary["label_coverage_pct"])
        self.assertEqual(0, summary["retained_labeled_observations"])
        self.assertEqual(0, alpha["retained_labeled_observations"])
        self.assertEqual(0, alpha["categories"]["defect"])
        self.assertIsNone(alpha["actionable_per_100_runs"])
        self.assertEqual(1, alpha["historical_labels"]["categories"]["defect"])
        self.assertEqual(1, summary["historical_labels"]["categories"]["defect"])

    def test_aged_contextual_label_can_be_reclassified_but_legacy_cannot(self) -> None:
        self.run_cli("label", str(self.project), "obs-a", "defect")
        with (self.cache / "check-roi-labels.jsonl").open("a", encoding="utf-8") as stream:
            stream.write(
                json.dumps(
                    {
                        "type": "label",
                        "schema": 1,
                        "observation_id": "obs-b",
                        "category": "defect",
                    }
                )
                + "\n"
            )
        (self.cache / "check-roi.jsonl").unlink()

        self.run_cli("label", str(self.project), "obs-a", "useful-review")
        legacy = self.run_cli(
            "label",
            str(self.project),
            "obs-b",
            "false-positive",
            success=False,
        )
        self.assertEqual(2, legacy.returncode)
        self.assertIn("legacy label captured attribution", legacy.stderr)
        with (self.cache / "check-roi-labels.jsonl").open(encoding="utf-8") as stream:
            records = [json.loads(line) for line in stream]
        latest = records[-1]
        self.assertEqual("obs-a", latest["observation_id"])
        self.assertEqual("useful-review", latest["category"])
        self.assertTrue(latest["direct_seen"])
        self.assertEqual(["accept", "all"], latest["origins"])

    def test_summary_waits_for_an_in_progress_label_append(self) -> None:
        self.run_cli("label", str(self.project), "obs-a", "defect")
        label_path = self.cache / "check-roi-labels.jsonl"
        process: subprocess.Popen[str] | None = None
        with label_path.open("a", encoding="utf-8") as stream:
            fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
            process = subprocess.Popen(
                [str(SCRIPT), "summary", str(self.project), "--json"],
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
            )
            time.sleep(0.05)
            self.assertIsNone(process.poll())
            fcntl.flock(stream.fileno(), fcntl.LOCK_UN)
        stdout, stderr = process.communicate(timeout=10)
        self.assertEqual(0, process.returncode, stderr)
        self.assertEqual(1, json.loads(stdout)["labeled_observations"])

    def test_empty_project_reports_cleanly(self) -> None:
        empty = self.project / "empty"
        empty.mkdir()
        pending = self.run_cli("pending", str(empty))
        self.assertIn("No pending", pending.stdout)
        summary = json.loads(self.run_cli("summary", str(empty), "--json").stdout)
        self.assertEqual(0, summary["invocations"])
        self.assertIsNone(summary["label_coverage_pct"])

    def test_summary_includes_the_retained_rotated_generation(self) -> None:
        write_jsonl(
            Path(f"{self.cache / 'check-roi.jsonl'}.1"),
            [
                {
                    "type": "check_run",
                    "schema": 1,
                    "timestamp_ms": 50,
                    "guardian_digest": "guardian-old",
                    "origin": "all",
                    "scope_mode": "full",
                    "cached": False,
                    "outcome": "green",
                    "duration_ms": 5,
                    "check_phase_ms": 4,
                    "checks": [
                        {
                            "check": "gamma",
                            "policy": "report",
                            "outcome": "reported",
                            "duration_ms": 4,
                            "findings": 1,
                            "warnings": 0,
                            "observations": [
                                {
                                    "observation_id": "obs-c",
                                    "finding_key": "gamma|src/c.zig|subject",
                                    "file": "src/c.zig",
                                    "line": 3,
                                }
                            ],
                        }
                    ],
                }
            ],
        )
        pending = self.run_cli("pending", str(self.project), "--all", "--observations")
        self.assertIn("obs-c", pending.stdout)
        summary = json.loads(
            self.run_cli("summary", str(self.project), "--json").stdout
        )
        self.assertEqual(2, summary["invocations"])
        self.assertEqual(6, summary["all_retained"]["invocations"])
        self.assertTrue(any(row["check"] == "gamma" for row in summary["checks"]))


if __name__ == "__main__":
    unittest.main()
