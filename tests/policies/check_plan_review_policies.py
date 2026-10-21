"""Runs the terraform-plan-review Tirith policies against the plan fixtures and
checks each exit code: 0 passed, 3 failed, 1 could not evaluate.

Usage: python tests/policies/check_plan_review_policies.py
Needs Tirith on PATH: pip install "git+https://github.com/StackGuardian/tirith.git@1.2.1"
"""

import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
POLICIES = ROOT / "standalone" / "terraform-plan-review" / "assets" / "policies"
FIXTURES = ROOT / "tests" / "fixtures" / "plans"

EXPECTED = {
    "no-deletes": {
        "create-only": 0,
        "update-in-place": 0,
        "replace-db": 3,
        "delete-bucket": 3,
        "sensitive": 0,
        "no-stateful-types": 3,
        "replace-create-first": 3,
        "malformed": 1,
    },
    "no-replacements": {
        "create-only": 0,
        "update-in-place": 0,
        "replace-db": 3,
        "delete-bucket": 0,
        "sensitive": 0,
        "no-stateful-types": 0,
        "replace-create-first": 3,
        "malformed": 1,
    },
    "no-stateful-deletes": {
        "create-only": 0,
        "update-in-place": 0,
        "replace-db": 3,
        "delete-bucket": 3,
        "sensitive": 0,
        # None of the watched types is in the plan, so every check is skipped.
        "no-stateful-types": 1,
        "replace-create-first": 1,
        "malformed": 1,
    },
}


def main() -> int:
    failures = []

    lint = subprocess.run(["tirith", "lint", str(POLICIES)], capture_output=True, text=True)
    print(lint.stdout.strip())
    if lint.returncode != 0:
        failures.append(f"tirith lint exited {lint.returncode}: {lint.stderr.strip()}")

    policies = sorted(p.stem for p in POLICIES.glob("*.json"))
    fixtures = sorted(p.stem for p in FIXTURES.glob("*.json"))
    if policies != sorted(EXPECTED):
        failures.append(f"policies {policies} differ from the expectations {sorted(EXPECTED)}")

    for policy, expected in sorted(EXPECTED.items()):
        if sorted(expected) != fixtures:
            failures.append(f"{policy}: expectations cover {sorted(expected)}, fixtures are {fixtures}")
        for fixture, want in sorted(expected.items()):
            run = subprocess.run(
                [
                    "tirith",
                    "-policy-path",
                    str(POLICIES / f"{policy}.json"),
                    "-input-path",
                    str(FIXTURES / f"{fixture}.json"),
                    "--json",
                    "--fail-on-error",
                ],
                capture_output=True,
                text=True,
            )
            mark = "ok" if run.returncode == want else "FAIL"
            print(f"{mark:4} {policy:20} {fixture:18} exit {run.returncode} (want {want})")
            if run.returncode != want:
                failures.append(f"{policy} on {fixture}: exit {run.returncode}, want {want}")

    for failure in failures:
        print(f"error: {failure}", file=sys.stderr)
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
