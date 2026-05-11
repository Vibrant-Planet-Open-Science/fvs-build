#!/usr/bin/env python3
"""Expand comma-separated FVS variant codes into JSON for GitHub Actions matrix jobs.

This script is the single implementation shared by the Linux, Windows, and macOS
native build workflows' preflight jobs.

Behavior:

* Split the input on commas, strip surrounding whitespace from each token, and
  skip empty tokens after stripping.
* Deduplicate while preserving the order of first appearance (same semantics as
  the former Linux ``jq`` pipeline and the inline Python on other platforms).
* Print ``Expanded variants: <json>`` to stdout.
* Unless ``--dry-run`` is set, append ``matrix_variants=<json>`` to the file
  named by ``GITHUB_OUTPUT`` (GitHub Actions step output contract).
"""

from __future__ import annotations

import argparse
import json
import os
import sys


def expand_variants(csv: str) -> list[str]:
    """Parse a comma-separated variant list into an ordered, unique code list.

    Args:
        csv: Raw comma-separated string (may include spaces around commas).

    Returns:
        Variant codes in first-seen order, with no duplicates or empty entries.
    """
    return list(dict.fromkeys(p.strip() for p in csv.split(",") if p.strip()))


def _append_github_output(name: str, value: str) -> None:
    """Append one ``name=value`` line to GitHub Actions' ``GITHUB_OUTPUT`` file.

    Values must be single-line; this script only emits compact JSON arrays.

    Args:
        name: Output key (e.g. ``matrix_variants``).
        value: Single-line value to record for that key.

    Raises:
        SystemExit: If ``GITHUB_OUTPUT`` is unset or empty.
    """
    path = os.environ.get("GITHUB_OUTPUT")
    if not path:
        sys.stderr.write("error: GITHUB_OUTPUT is not set (use --dry-run locally)\n")
        raise SystemExit(1)
    with open(path, "a", encoding="utf-8") as fh:
        fh.write(f"{name}={value}\n")


def main() -> int:
    """CLI entrypoint: read variants, validate, print, and optionally write outputs.

    On a normal path without ``--dry-run``, calls :func:`_append_github_output`,
    which terminates the process with ``SystemExit`` if ``GITHUB_OUTPUT`` is
    unset.

    Returns:
        ``0`` on success; ``1`` if the variants string is missing or expands to
        an empty list.
    """
    parser = argparse.ArgumentParser(
        description="Expand VARIANTS_CSV into a JSON array for workflow matrices.",
    )
    parser.add_argument(
        "--variants-csv",
        default=os.environ.get("VARIANTS_CSV"),
        metavar="CSV",
        help="Comma-separated variants (default: VARIANTS_CSV environment variable).",
    )
    parser.add_argument(
        "--dry-run",
        action="store_true",
        help="Print JSON only; do not write GITHUB_OUTPUT.",
    )
    args = parser.parse_args()
    if args.variants_csv is None:
        sys.stderr.write("error: pass --variants-csv or set VARIANTS_CSV\n")
        return 1
    variants = expand_variants(args.variants_csv)
    if not variants:
        sys.stderr.write("ERROR: variants input expanded to an empty list\n")
        return 1
    matrix_json = json.dumps(variants)
    print(f"Expanded variants: {matrix_json}")
    if args.dry_run:
        return 0
    _append_github_output("matrix_variants", matrix_json)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
