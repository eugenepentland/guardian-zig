#!/usr/bin/env python3
"""Exercise real CLI framing, exit statuses and read-only contract audits."""
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import tempfile

binary = Path(sys.argv[1]).resolve()


def snapshot(root):
    return {
        str(path.relative_to(root)): hashlib.sha256(path.read_bytes()).hexdigest()
        for path in root.rglob("*") if path.is_file()
    }


with tempfile.TemporaryDirectory(prefix="guardian-contracts-") as temp:
    root = Path(temp)
    project = root / "project"
    (project / "src").mkdir(parents=True)
    (project / "src/main.zig").write_text(
        'fn save() void { disk.writeFile() catch return; }\n'
        'fn edit(id: u64, rev: u64) void { selectTarget(id); }\n'
    )
    profile = root / "contracts.toml"
    write_rule = '''[[contract]]
name = "durability"
kind = "durable_write"
functions = ["src/main.zig::save"]
operations = ["*.writeFile"]
reason = "Writes must preserve errors"
'''
    identity_rule = '''[[contract]]
name = "identity"
kind = "identity"
functions = ["src/main.zig::edit"]
operations = ["src/main.zig::selectTarget"]
validators = ["src/main.zig::validate"]
identity = ["id"]
revision = ["rev"]
reason = "Validate the target and revision"
'''
    profile.write_text(write_rule + identity_rule)
    before = snapshot(project)
    output = root / "report.json"
    # A regular file catches framing/positioning bugs that a pipe can conceal.
    with output.open("wb") as stream:
        result = subprocess.run(
            [binary, "contract-audit", project, "--contracts", profile, "--json"],
            stdout=stream, stderr=subprocess.PIPE, check=False,
        )
    assert result.returncode == 0, result.stderr.decode()
    report = json.loads(output.read_text())
    assert (report["violations"], report["review_items"]) == (2, 1), report
    assert snapshot(project) == before, "audit changed the target tree"
    # Overlays must never silently affect a real gate.
    result = subprocess.run(
        [binary, "durable-write-errors", project, "--contracts", profile],
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    assert b"only valid with contract-audit" in result.stderr
    result = subprocess.run(
        [binary, "contract-audit", project, "--contracts"],
        capture_output=True, check=False,
    )
    assert result.returncode != 0
    assert b"requires a profile path" in result.stderr
    # Inline contracts participate in real gates, while identity stays advisory.
    (project / "guardian.toml").write_text(write_rule + identity_rule)
    result = subprocess.run([binary, "durable-write-errors", project], capture_output=True)
    assert result.returncode != 0, result.stderr.decode()
    result = subprocess.run([binary, "edit-identity", project], capture_output=True)
    assert result.returncode == 0, result.stderr.decode()
    result = subprocess.run(
        [binary, "all", project, "--only", "durable-write-errors,edit-identity", "--gate"],
        capture_output=True,
    )
    assert result.returncode != 0, result.stderr.decode()
    assert b"durable-write-errors" in result.stderr
    # Parsing fails closed instead of generating a clean report.
    (project / "src/main.zig").write_text("fn broken( {\n")
    result = subprocess.run(
        [binary, "contract-audit", project, "--json"], capture_output=True,
    )
    assert result.returncode != 0
    assert b"cannot parse" in result.stderr
print("operation-contract CLI integration: PASS")
