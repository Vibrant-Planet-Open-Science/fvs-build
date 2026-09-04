#!/usr/bin/env python3
"""Derive FVS build-provenance macros from a source tree's git metadata.

Upstream ``USDAForestService/ForestVegetationSimulator`` exposes build
provenance through ``base/version.f90``, which defines ``MODULE FVSVERSION``
from six ``#ifndef``-guarded preprocessor macros. Upstream's own
``bin/makefile`` and ``bin/CMakeLists.txt`` each derive the values from git
and inject them with ``-D``; this tool is the Meson overlay's equivalent.

Every macro falls back to ``unknown`` when git is unavailable, the directory
is not a repository, or the query fails, mirroring upstream. A ``-dirty``
suffix on ``FVS_GIT_VERSION`` and ``FVS_GIT_HASH`` marks an uncommitted
working tree; such a build should not ship as a deliverable.

Output is one compiler flag per line, ready for ``meson.build`` to append to
``fortran_args`` verbatim::

    -DFVS_GIT_VERSION="FS2026.2"
    -DFVS_GIT_ORG="USDAForestService"
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

UNKNOWN = "unknown"

# Owner segment of a clone URL, for both SSH (git@host:owner/repo.git) and
# HTTPS (https://host/owner/repo) forms. Mirrors the sed expression in
# bin/makefile and the string(REGEX REPLACE) in bin/CMakeLists.txt.
ORG_RE = re.compile(r".*[:/]([^/]+)/[^/]*?(?:\.git)?$")


def _git(source_dir: Path, *args: str) -> str | None:
    """Run one git query against ``source_dir``.

    Args:
        source_dir: Root of the FVS source checkout.
        *args: Arguments following ``git -C <source_dir>``.

    Returns:
        Stripped stdout, or ``None`` if git is missing or exits non-zero.
    """
    try:
        proc = subprocess.run(
            ["git", "-C", str(source_dir), *args],
            capture_output=True,
            text=True,
            check=False,
        )
    except OSError:
        return None
    if proc.returncode != 0:
        return None
    return proc.stdout.strip() or None


def _org(remote: str) -> str:
    """Extract the owner segment from a clone URL."""
    match = ORG_RE.fullmatch(remote)
    return match.group(1) if match else UNKNOWN


def collect(source_dir: Path) -> dict[str, str]:
    """Return the six ``FVS_GIT_*`` values for a source tree.

    A tree with uncommitted changes -- including untracked files -- gets
    ``-dirty`` appended to both version and hash. Submodule worktree changes
    do not count: ``volume/NVEL`` tracks ``*.mod`` files that every build
    strips before configure, which would otherwise mark every build dirty. A
    changed submodule *commit* is still a real difference and does count.

    Args:
        source_dir: Root of the FVS source checkout.

    Returns:
        Mapping of macro suffix (e.g. ``"VERSION"``) to value.
    """
    remote = _git(source_dir, "remote", "get-url", "origin") or UNKNOWN
    version = (
        _git(source_dir, "describe", "--tags", "--exact-match")
        or _git(source_dir, "describe", "--tags")
        or UNKNOWN
    )
    commit = _git(source_dir, "rev-parse", "--short", "HEAD") or UNKNOWN

    if _git(source_dir, "status", "--porcelain", "--ignore-submodules=dirty"):
        version = f"{version}-dirty"
        commit = f"{commit}-dirty"

    return {
        "VERSION": version,
        "ORG": _org(remote),
        "HASH": commit,
        "DATE": _git(
            source_dir,
            "log",
            "-1",
            "--format=%cd",
            "--date=format:%Y%m%d",
        )
        or UNKNOWN,
        "BRANCH": _git(source_dir, "rev-parse", "--abbrev-ref", "HEAD") or UNKNOWN,
        "REMOTE": remote,
    }


def main(argv: list[str] | None = None) -> int:
    """CLI entry point. Returns a process exit code."""
    parser = argparse.ArgumentParser(
        description="Emit -DFVS_GIT_* flags derived from a source tree's git metadata.",
    )
    parser.add_argument(
        "--source-dir",
        required=True,
        type=Path,
        help="Root of a checked-out FVS source tree.",
    )
    args = parser.parse_args(argv)

    source_dir: Path = args.source_dir
    if not source_dir.is_dir():
        sys.stderr.write(f"error: not a directory: {source_dir}\n")
        return 1

    for key, value in collect(source_dir).items():
        sys.stdout.write(f'-DFVS_GIT_{key}="{value}"\n')
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
