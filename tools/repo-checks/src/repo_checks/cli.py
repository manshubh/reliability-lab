"""Command line entry point: ``repo-checks workflows [PATH ...]``."""

import argparse
import sys
from pathlib import Path

from repo_checks.workflows import check_workflow, workflow_files


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="repo-checks", description="Checks that keep the repository's own rules."
    )
    commands = parser.add_subparsers(dest="command", required=True)

    workflows = commands.add_parser(
        "workflows", help="check that every workflow run step is a single make target"
    )
    workflows.add_argument(
        "paths",
        nargs="*",
        type=Path,
        default=[Path(".github/workflows")],
        help="workflow files or folders (default: .github/workflows)",
    )

    args = parser.parse_args(argv)
    missing = [p for p in args.paths if not p.exists()]
    if missing:
        parser.error(f"no such file or folder: {', '.join(map(str, missing))}")

    files = workflow_files(args.paths)
    violations = [v for f in files for v in check_workflow(f)]
    for violation in violations:
        print(violation, file=sys.stderr)
    if violations:
        return 1
    print(f"workflows: {len(files)} file(s) checked, every run step is a single make target")
    return 0


if __name__ == "__main__":
    sys.exit(main())
