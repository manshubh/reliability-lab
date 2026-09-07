from pathlib import Path

import pytest

from repo_checks.cli import main
from repo_checks.workflows import check_workflow, is_make_call

FIXTURES = Path(__file__).parent / "fixtures"


@pytest.mark.parametrize(
    "command",
    [
        "make pr",
        "make gameday GROUP=app-faults",
        "make gameday GROUP=app-faults EXP=e02",
        "  make lint\n",
        "make nightly REUSE_CLUSTER=1",
    ],
)
def test_allows_a_single_make_call(command: str) -> None:
    assert is_make_call(command)


@pytest.mark.parametrize(
    "command",
    [
        "yamllint .",
        "make",
        "make lint && make test",
        "make lint; make test",
        "make lint\nmake test",
        "make gameday GROUP=${{ matrix.group }}",
        "make gameday GROUP=$(whoami)",
        "make lint | tee lint.log",
        "make -C app test",
        "sudo make lint",
    ],
)
def test_rejects_anything_else(command: str) -> None:
    assert not is_make_call(command)


def test_good_workflow_has_no_violations() -> None:
    assert list(check_workflow(FIXTURES / "good.yml")) == []


@pytest.mark.parametrize(
    ("fixture", "command"),
    [
        ("bad-shell.yml", "yamllint ."),
        ("bad-chained.yml", "make lint && make test"),
        ("bad-expression.yml", "make gameday GROUP=${{ matrix.group }}"),
    ],
)
def test_bad_workflow_is_reported(fixture: str, command: str) -> None:
    violations = list(check_workflow(FIXTURES / fixture))
    assert [v.command for v in violations] == [command]


def test_violation_message_names_the_file_job_and_step() -> None:
    (violation,) = check_workflow(FIXTURES / "bad-shell.yml")
    message = str(violation)
    assert "bad-shell.yml" in message
    assert "job 'checks'" in message
    assert "step 2 ('Lint')" in message


def test_cli_exit_codes(capsys: pytest.CaptureFixture[str]) -> None:
    assert main(["workflows", str(FIXTURES / "good.yml")]) == 0
    assert main(["workflows", str(FIXTURES / "bad-shell.yml")]) == 1
    assert "a run step must be a single make target" in capsys.readouterr().err


def test_cli_rejects_a_missing_path() -> None:
    with pytest.raises(SystemExit) as excinfo:
        main(["workflows", "does-not-exist"])
    assert excinfo.value.code == 2
