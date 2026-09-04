#!/usr/bin/env python3
"""Parse an upstream FVS source list and emit Meson-friendly output.

Upstream ``USDAForestService/ForestVegetationSimulator`` releases drive
their build from per-variant manifests at
``bin/FVS<variant>_sourceList.txt``, including Canadian variants ``bc``
and ``on`` whose lists live under ``bin/`` (paths under ``canada/`` use
``../canada/<v>/...`` from ``bin/``). A separate
``canada/bin/FVSon_sourceList.txt`` exists upstream but is a shorter
subset for an internal Canada build; this tool always reads the
canonical ``bin/`` manifest.

Each manifest is a newline-delimited list of paths relative to ``bin/``,
typically ``../<dir>/<file>``.

The tool resolves entries to absolute paths, categorizes them by
extension (mirroring upstream ``bin/CMakeLists.txt``), and prints a
delimited text schema that ``meson.build`` can consume without JSON.

Note:
    Output sections (header ``### <name>`` then paths, in order):
    ``fortran_sources``, ``main_source``, ``c_sources_sql``,
    ``c_sources_fofem``, ``include_dirs``, ``mod_sources``. The CLI exits
    with code ``1`` if the manifest is missing or contains no main source
    (see :func:`parse`).

Warning:
    Missing files are reported on stderr but still listed so Meson can
    fail with a concrete path.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path
from typing import TextIO

SQL_C_BASENAMES: frozenset[str] = frozenset(
    {"sqlite3.c", "fvsqlite3.c", "apisubsc.c"},
)

INCLUDE_EXTENSIONS: frozenset[str] = frozenset({".f77", ".inc", ".h"})
FORTRAN_EXTENSIONS: frozenset[str] = frozenset({".f", ".for", ".f90"})
C_EXTENSIONS: frozenset[str] = frozenset({".c", ".cpp"})

# Program entry point: main.f up to FS2026.2, main.f90 after the upstream rename.
MAIN_BASENAMES: frozenset[str] = frozenset({"main.f", "main.f90"})


def manifest_path(source_dir: Path, variant: str) -> Path:
    """Return ``bin/FVS<variant>_sourceList.txt`` under ``source_dir``.

    Canonical source lists live under ``bin/`` for every variant,
    including ``bc`` and ``on``.

    Args:
        source_dir: Root of a checked-out ForestVegetationSimulator
            tree.
        variant: Two-letter variant code (e.g. ``"pn"``, ``"bc"``).

    Returns:
        ``<source_dir>/bin/FVS<variant>_sourceList.txt``.
    """
    return source_dir / "bin" / f"FVS{variant}_sourceList.txt"


def parse(source_dir: Path, variant: str) -> dict[str, list[str]]:
    """Parse the manifest for ``variant`` into categorized path lists.

    Args:
        source_dir: Root of a checked-out ForestVegetationSimulator
            tree.
        variant: Two-letter variant code.

    Returns:
        Mapping from section name to absolute paths, suitable for
        :func:`emit`.

    Raises:
        FileNotFoundError: If the manifest file is missing.
        ValueError: If no entry in :data:`MAIN_BASENAMES` is present after
            parsing.
    """
    sl_path = manifest_path(source_dir, variant)
    if not sl_path.is_file():
        raise FileNotFoundError(str(sl_path))

    sl_dir = sl_path.parent

    fortran_sources: list[str] = []
    main_source: str | None = None
    c_sources_sql: list[str] = []
    c_sources_fofem: list[str] = []
    include_dirs: list[str] = []
    seen_include_dirs: set[str] = set()
    mod_sources: list[str] = []

    for raw in sl_path.read_text().splitlines():
        entry = raw.strip()
        if not entry:
            continue

        path = (sl_dir / entry).resolve()
        ext = path.suffix.lower()
        name = path.name
        parent = str(path.parent)

        if not path.exists():
            sys.stderr.write(f"warning: file not on disk: {path}\n")

        if ext in INCLUDE_EXTENSIONS:
            if parent not in seen_include_dirs:
                seen_include_dirs.add(parent)
                include_dirs.append(parent)
        elif ext in FORTRAN_EXTENSIONS:
            if name.lower() in MAIN_BASENAMES:
                if main_source is not None:
                    sys.stderr.write(
                        "warning: multiple main source entries; keeping "
                        f"{main_source}, ignoring {path}\n",
                    )
                else:
                    main_source = str(path)
            else:
                fortran_sources.append(str(path))
                if name.lower().endswith("_mod.f"):
                    mod_sources.append(str(path))
        elif ext in C_EXTENSIONS:
            if name in SQL_C_BASENAMES:
                c_sources_sql.append(str(path))
            else:
                c_sources_fofem.append(str(path))
        else:
            sys.stderr.write(f"warning: unrecognized extension on {path}\n")

    if main_source is None:
        msg = (
            f"no main source ({', '.join(sorted(MAIN_BASENAMES))}) found in "
            f"{sl_path}; refusing to emit incomplete schema"
        )
        raise ValueError(msg)

    return {
        "fortran_sources": fortran_sources,
        "main_source": [main_source],
        "c_sources_sql": c_sources_sql,
        "c_sources_fofem": c_sources_fofem,
        "include_dirs": include_dirs,
        "mod_sources": mod_sources,
    }


def emit(sections: dict[str, list[str]], out: TextIO | None = None) -> None:
    """Write the ``###``-delimited schema consumed by ``meson.build``.

    Args:
        sections: Categorized absolute paths, as returned by
            :func:`parse`.
        out: Text stream to write to; defaults to ``sys.stdout``.
    """
    if out is None:
        out = sys.stdout
    order = (
        "fortran_sources",
        "main_source",
        "c_sources_sql",
        "c_sources_fofem",
        "include_dirs",
        "mod_sources",
    )
    for section in order:
        out.write(f"### {section}\n")
        for item in sections[section]:
            out.write(f"{item}\n")


def main(argv: list[str] | None = None) -> int:
    """CLI entrypoint for :mod:`argparse`.

    Args:
        argv: Argument vector (excluding the program name). When
            ``None``, :class:`argparse.ArgumentParser` uses
            ``sys.argv[1:]``.

    Returns:
        ``0`` on success, ``1`` if ``--source-dir`` is not a directory or
        :func:`parse` raises :exc:`FileNotFoundError` / :exc:`ValueError`.

    Raises:
        SystemExit: If the user passes invalid flags (handled inside
            :meth:`argparse.ArgumentParser.parse_args`, exit code
            ``2``).
    """
    parser = argparse.ArgumentParser(
        description=(
            "Parse a USFS FVS source list and emit a delimited text schema "
            "for consumption by meson.build."
        ),
    )
    parser.add_argument(
        "--source-dir",
        required=True,
        type=Path,
        help=(
            "Absolute path to a checked-out USDAForestService/"
            "ForestVegetationSimulator tree."
        ),
    )
    parser.add_argument(
        "--variant",
        required=True,
        help=(
            "Variant code (e.g. 'pn', 'nc', 'wc', 'bc', 'on'). Reads "
            "<source_dir>/bin/FVS<variant>_sourceList.txt."
        ),
    )
    args = parser.parse_args(argv)

    src = args.source_dir.resolve()
    if not src.is_dir():
        sys.stderr.write(f"error: source dir does not exist: {src}\n")
        return 1

    try:
        sections = parse(src, args.variant)
    except FileNotFoundError as err:
        sys.stderr.write(f"error: source list not found: {err}\n")
        return 1
    except ValueError as err:
        sys.stderr.write(f"error: {err}\n")
        return 1
    emit(sections)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
