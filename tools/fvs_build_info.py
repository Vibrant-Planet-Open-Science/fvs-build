#!/usr/bin/env python3
"""Print the `-DFVS_GIT_*` flags `base/version.f90` reads, one per line.

The Meson equivalent of upstream's `bin/makefile` git queries. Each value
falls back to `unknown` when git fails, as upstream does.
"""

from __future__ import annotations

import argparse
import re
import subprocess
import sys
from pathlib import Path

UNKNOWN = "unknown"

# Owner of an SSH or HTTPS clone URL; mirrors upstream bin/makefile's sed.
ORG_RE = re.compile(r".*[:/]([^/]+)/[^/]*?(?:\.git)?$")


def _git(source_dir: Path, *args: str) -> str | None:
    """Return stripped `git -C source_dir *args` stdout, or `None` on failure."""
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
    """Map each `FVS_GIT_*` suffix to its value; untracked files count as dirty."""
    remote = _git(source_dir, "remote", "get-url", "origin") or UNKNOWN
    version = (
        _git(source_dir, "describe", "--tags", "--exact-match")
        or _git(source_dir, "describe", "--tags")
        or UNKNOWN
    )
    commit = _git(source_dir, "rev-parse", "--short", "HEAD") or UNKNOWN

    if _git(source_dir, "status", "--porcelain"):
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
