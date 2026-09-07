"""Check that GitHub workflows only schedule work and never do it.

Everything CI does must also run on a laptop with the same command. The rule
that keeps that true: a workflow ``run:`` step is exactly one ``make`` call.
Logic lives in the Makefile, where ``make pr`` (or any other target) runs it
locally too. ``uses:`` steps (checkout, tool setup, artifact upload) are fine,
because they move files or install tools rather than doing the work.

A step may pass plain ``VAR=value`` arguments to make. Values that come from
GitHub (matrix entries, inputs) go in the step's ``env:`` instead, because make
reads environment variables and because ``${{ }}`` inside a shell command is a
code-injection risk.
"""

import re
from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import Any

import yaml

# make, then one target, then optional VAR=value pairs with no shell syntax.
_MAKE_CALL = re.compile(
    r"""
    ^make
    \s+[a-z][a-z0-9-]*                          # the target
    (?:\s+[A-Z][A-Z0-9_]*=[A-Za-z0-9_./:,@%+-]*)*  # optional VAR=value arguments
    $
    """,
    re.VERBOSE,
)


@dataclass(frozen=True)
class Violation:
    """One step that breaks the rule."""

    path: Path
    job: str
    step: str
    command: str

    def __str__(self) -> str:
        return (
            f"{self.path}: job {self.job!r}, step {self.step}: "
            f"a run step must be a single make target, got {self.command!r}"
        )


def is_make_call(command: str) -> bool:
    """Return True if command is a single make call that the rule allows."""
    return _MAKE_CALL.match(command.strip()) is not None


def _step_label(index: int, step: dict[str, Any]) -> str:
    name = step.get("name")
    return f"{index} ({name!r})" if name else str(index)


def check_workflow(path: Path) -> Iterator[Violation]:
    """Yield every run step in one workflow file that isn't a single make call."""
    document = yaml.safe_load(path.read_text())
    jobs = document.get("jobs", {}) if isinstance(document, dict) else {}
    for job_id, job in jobs.items():
        # A job that calls a reusable workflow has no steps of its own.
        for index, step in enumerate(job.get("steps", []), start=1):
            command = step.get("run")
            if command is not None and not is_make_call(str(command)):
                yield Violation(path, job_id, _step_label(index, step), str(command).strip())


def workflow_files(paths: list[Path]) -> list[Path]:
    """Expand directories into the workflow files they contain."""
    files: list[Path] = []
    for path in paths:
        if path.is_dir():
            files.extend(sorted([*path.glob("*.yml"), *path.glob("*.yaml")]))
        else:
            files.append(path)
    return files
