#!/usr/bin/env python3
"""Decide whether a CI job should run from actions-toolbox path metadata."""

from __future__ import annotations

import json
import os
import sys
from pathlib import PurePosixPath


ALL_TERMUX_HELPERS = {
    ".github/scripts/ci-should-run.py",
    ".github/scripts/run-termux-pacman.sh",
}


def normalize(path: str) -> str:
    path = path.strip().replace("\\", "/")
    while path.startswith("./"):
        path = path[2:]
    return path


def paths_from_env(name: str) -> list[str] | None:
    value = os.environ.get(name)
    if value is None or value.strip() == "":
        return None

    value = value.strip()
    try:
        parsed = json.loads(value)
    except json.JSONDecodeError:
        return None

    if not isinstance(parsed, list) or not all(isinstance(item, str) for item in parsed):
        return None

    return [normalize(item) for item in parsed]


def under(path: str, directory: str) -> bool:
    directory = directory.rstrip("/")
    return path == directory or path.startswith(f"{directory}/")


def is_c_source(path: str) -> bool:
    return under(path, "lib") and PurePosixPath(path).suffix in {".c", ".h"}


def is_shell_source(path: str) -> bool:
    if under(path, "examples") or under(path, "docs"):
        return False
    return PurePosixPath(path).suffix in {".sh", ".bash", ".ksh"}


def is_pr_workflow(path: str) -> bool:
    return path == ".github/workflows/pr-check.yml"


def is_workflow(path: str) -> bool:
    return under(path, ".github/workflows")


def is_termux_helper(path: str) -> bool:
    return path in ALL_TERMUX_HELPERS


def c_format_path(path: str) -> bool:
    return (
        is_c_source(path)
        or path in {".clang-format", ".clang-tidy"}
        or is_pr_workflow(path)
        or is_termux_helper(path)
    )


def c_static_path(path: str) -> bool:
    return c_format_path(path)


def termux_compile_path(path: str) -> bool:
    return is_c_source(path) or is_pr_workflow(path) or is_termux_helper(path)


def build_package_path(path: str) -> bool:
    return path == "build.sh" or under(path, "lib") or is_pr_workflow(path) or is_termux_helper(path)


def installer_smoke_path(path: str) -> bool:
    return path == "install.sh" or is_pr_workflow(path) or is_termux_helper(path)


def shellcheck_path(path: str) -> bool:
    return (
        is_shell_source(path)
        or path == ".github/workflows/shellcheck.yml"
        or is_termux_helper(path)
    )


def actionlint_path(path: str) -> bool:
    return is_workflow(path) or path == ".github/scripts/ci-should-run.py"


PREDICATES = {
    "c-format": c_format_path,
    "c-static": c_static_path,
    "termux-compile": termux_compile_path,
    "build-package": build_package_path,
    "installer-smoke": installer_smoke_path,
    "shellcheck": shellcheck_path,
    "actionlint": actionlint_path,
}


def emit_output(name: str, value: str) -> None:
    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            handle.write(f"{name}={value}\n")


def main() -> int:
    if len(sys.argv) != 2 or sys.argv[1] not in PREDICATES:
        modes = ", ".join(sorted(PREDICATES))
        print(f"usage: {sys.argv[0]} <{modes}>", file=sys.stderr)
        return 2

    changed = paths_from_env("FILES_CHANGED")
    deleted = paths_from_env("FILES_DELETED")
    if changed is None or deleted is None:
        reason = "changed-file metadata unavailable; running fail-open"
        emit_output("should_run", "true")
        emit_output("reason", reason)
        print(reason)
        return 0

    paths = sorted(set(changed + deleted))
    if not paths:
        reason = "no changed-file metadata entries; running fail-open"
        emit_output("should_run", "true")
        emit_output("reason", reason)
        print(reason)
        return 0

    predicate = PREDICATES[sys.argv[1]]
    matches = [path for path in paths if predicate(path)]
    should_run = bool(matches)
    reason = (
        "matched relevant paths: " + ", ".join(matches)
        if should_run
        else "no relevant paths changed"
    )

    emit_output("should_run", "true" if should_run else "false")
    emit_output("reason", reason)
    print(reason)
    return 0


if __name__ == "__main__":
    sys.exit(main())
