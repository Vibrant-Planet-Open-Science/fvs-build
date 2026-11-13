#!/usr/bin/env python3
"""Stage per-variant FVS binaries and shared libs, then write ``build-info.json``.

Executables keep their debug info, so a crash seen through a stripped library
can be reproduced with the executable for file:line. Reads its configuration
from the environment variables ``provenance.py write-build-info`` needs.
"""

from __future__ import annotations

import ctypes
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

from provenance import _variant_artifact_staging_prefix


def _require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        sys.stderr.write(f"error: missing environment variable: {name}\n")
        raise SystemExit(1)
    return val


def _sha256_file(path: Path) -> str:
    """Return the SHA-256 hex digest of a file."""
    digest = hashlib.sha256()
    with path.open("rb") as fh:
        for chunk in iter(lambda: fh.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _first_line(cmd: list[str]) -> str:
    """Run a command and return the first line of stdout."""
    proc = subprocess.run(cmd, check=True, capture_output=True, text=True, timeout=60)
    if not proc.stdout:
        return ""
    return proc.stdout.splitlines()[0].strip()


def _compiler_versions(platform: str) -> tuple[str, str, str]:
    """Return (gfortran_version_line, gcc_version_line, g++_version_line)."""
    if platform == "windows":
        return (
            _first_line(["gfortran", "--version"]),
            _first_line(["gcc", "--version"]),
            _first_line(["g++", "--version"]),
        )
    fc = _require_env("FC")
    cc = _require_env("CC")
    cxx = _require_env("CXX")
    return (
        _first_line([fc, "--version"]),
        _first_line([cc, "--version"]),
        _first_line([cxx, "--version"]),
    )


def _artifact_paths(
    platform: str,
    variant: str,
    build_dir: Path,
) -> tuple[Path, Path, str, str]:
    """Return source paths and staging basenames for the binary and shared lib."""
    if platform == "windows":
        return (
            build_dir / f"FVS{variant}.exe",
            build_dir / f"FVS{variant}.dll",
            f"FVS{variant}.exe",
            f"FVS{variant}.dll",
        )
    return (
        build_dir / f"FVS{variant}",
        build_dir / f"FVS{variant}.so",
        f"FVS{variant}",
        f"FVS{variant}.so",
    )


def _stage(variant: str) -> int:
    """Copy one variant's artifacts into staging and invoke ``write-build-info``."""
    platform = _require_env("FVS_NATIVE_PLATFORM").lower()
    if platform not in {"linux", "windows", "darwin"}:
        sys.stderr.write(f"error: unsupported FVS_NATIVE_PLATFORM: {platform!r}\n")
        return 1
    build_dir = Path(os.environ.get("BUILD_DIR", "_build"))
    fvs_build = Path(os.environ.get("FVS_BUILD_DIR", "fvs-build"))
    stage = Path("staging") / f"{_variant_artifact_staging_prefix()}{variant}"
    provenance_py = fvs_build / "tools/ci/provenance.py"
    if not provenance_py.is_file():
        sys.stderr.write(f"error: missing {provenance_py}\n")
        return 1

    bin_src, shlib_src, st_bin, st_shlib = _artifact_paths(platform, variant, build_dir)
    if not shlib_src.is_file():
        msg = f"error: expected shared library missing: {shlib_src}\n"
        if platform == "linux":
            msg += (
                "       (meson.build must keep a single unversioned "
                f"FVS{variant}.so per variant; name_prefix '')\n"
            )
        sys.stderr.write(msg)
        return 1
    if platform == "windows":
        if not bin_src.is_file():
            sys.stderr.write(f"error: {bin_src} missing\n")
            return 1
    elif not bin_src.is_file() or not os.access(bin_src, os.X_OK):
        sys.stderr.write(f"error: {bin_src} missing or not executable\n")
        return 1

    stage.mkdir(parents=True, exist_ok=True)
    (stage / "provenance/meson-logs").mkdir(parents=True, exist_ok=True)
    dst_bin = stage / st_bin
    dst_lib = stage / st_shlib
    shutil.copy2(bin_src, dst_bin)
    shutil.copy2(shlib_src, dst_lib)
    # -S is --strip-debug in GNU strip (Linux, MSYS2) and Apple's strip alike.
    subprocess.run(["strip", "-S", str(dst_lib)], check=True)
    # Stripping rewrites the file (and on macOS its ad-hoc signature): make
    # sure the shipped library still loads.
    ctypes.CDLL(str(dst_lib.resolve()))
    if platform != "windows":
        mode = dst_bin.stat().st_mode
        dst_bin.chmod(mode | 0o111)

    bin_sha = _sha256_file(dst_bin)
    lib_sha = _sha256_file(dst_lib)
    gfortran_v, gcc_v, gpp_v = _compiler_versions(platform)
    ninja_ver = _first_line(["ninja", "--version"])
    meson_ver = _first_line(["meson", "--version"])
    # The executable's mtime is when it was linked: Ninja leaves unchanged
    # outputs alone, so on a build-cache hit this stays the original link time.
    timestamp = datetime.fromtimestamp(bin_src.stat().st_mtime, timezone.utc).strftime(
        "%Y-%m-%dT%H:%M:%SZ"
    )

    meson_log = build_dir / "meson-logs/meson-log.txt"
    tail_out = stage / "provenance/meson-logs/meson-log.tail.txt"
    if meson_log.is_file():
        data = meson_log.read_bytes()
        tail_out.write_bytes(data[-200_000:])

    flags_proc = subprocess.run(
        [
            sys.executable,
            str(provenance_py),
            "extract-fortran-args",
            "--build-dir",
            str(build_dir),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    fortran_args = json.loads(flags_proc.stdout)
    source_dir = Path(os.environ.get("FVS_SOURCE", "fvs-source"))
    nvel_dir = str(source_dir / "volume/NVEL")
    sqlite_c = (source_dir / "dbsqlite/sqlite3.c").read_text(errors="replace")
    sqlite_version = re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', sqlite_c)
    build_profile = os.environ.get("BUILD_PROFILE", "reference").strip() or "reference"
    meson_buildtype = os.environ.get("MESON_BUILDTYPE", "plain").strip() or "plain"

    out_json = stage / "provenance/build-info.json"
    env = os.environ.copy()
    env.update(
        {
            "VARIANT": variant,
            "BIN_SHA": bin_sha,
            "LIB_SHA": lib_sha,
            "TIMESTAMP": timestamp,
            "GFORTRAN_VERSION": gfortran_v,
            "GCC_VERSION": gcc_v,
            "GPP_VERSION": gpp_v,
            "NINJA_VERSION": ninja_ver,
            "MESON_VERSION_OUT": meson_ver,
            "BUILD_PROFILE": build_profile,
            "MESON_BUILDTYPE": meson_buildtype,
            "FORTRAN_ARGS_JSON": json.dumps(fortran_args),
            "NVEL_URL": _first_line(
                ["git", "-C", nvel_dir, "remote", "get-url", "origin"]
            ),
            "NVEL_SHA": _first_line(["git", "-C", nvel_dir, "rev-parse", "HEAD"]),
            "SQLITE_VERSION": sqlite_version[1],
        }
    )
    cmd = [
        sys.executable,
        str(provenance_py),
        "write-build-info",
        "--output",
        str(out_json),
    ]
    subprocess.run(cmd, env=env, check=True)

    print(f"----- staged {stage} -----")
    subprocess.run(["ls", "-laR", str(stage)], check=True)

    return 0


def main() -> int:
    """Stage every variant in ``VARIANTS``; stop at the first failure."""
    for variant in _require_env("VARIANTS").split():
        if rc := _stage(variant):
            return rc
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
