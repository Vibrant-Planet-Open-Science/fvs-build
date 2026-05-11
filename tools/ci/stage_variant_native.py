#!/usr/bin/env python3
"""Stage per-variant FVS binaries and shared libs, then write ``build-info.json``.

Run from native matrix jobs after Meson has populated ``_build/``. Requires the
same environment variables previously exported for
``provenance.py write-build-info`` (``VARIANT``, ``FVS_NATIVE_PLATFORM``,
``SOURCE_*``, ``FVS_BUILD_*``, ``RUNNER_IMAGE``, toolchain package pins,
``GITHUB_RUN_ID``, ``GITHUB_RUN_ATTEMPT``, and on Linux/macOS ``FC``/``CC``/``CXX``).
"""

from __future__ import annotations

import hashlib
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path


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
            build_dir / f"libFVS{variant}.dll",
            f"FVS{variant}.exe",
            f"libFVS{variant}.dll",
        )
    ext = ".dylib" if platform == "darwin" else ".so"
    return (
        build_dir / f"FVS{variant}",
        build_dir / f"libFVS{variant}{ext}",
        f"FVS{variant}",
        f"libFVS{variant}{ext}",
    )


def main() -> int:
    """Copy artifacts into ``staging/<variant>/`` and invoke ``write-build-info``."""
    platform = _require_env("FVS_NATIVE_PLATFORM").lower()
    if platform not in {"linux", "windows", "darwin"}:
        sys.stderr.write(f"error: unsupported FVS_NATIVE_PLATFORM: {platform!r}\n")
        return 1
    variant = _require_env("VARIANT")
    build_dir = Path(os.environ.get("BUILD_DIR", "_build"))
    fvs_build = Path(os.environ.get("FVS_BUILD_DIR", "fvs-build"))
    stage = Path(os.environ.get("STAGE_DIR", f"staging/{variant}"))
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
                f"libFVS{variant}.so per variant)\n"
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
    if platform != "windows":
        mode = dst_bin.stat().st_mode
        dst_bin.chmod(mode | 0o111)

    bin_sha = _sha256_file(dst_bin)
    lib_sha = _sha256_file(dst_lib)
    gfortran_v, gcc_v, gpp_v = _compiler_versions(platform)
    ninja_ver = _first_line(["ninja", "--version"])
    meson_ver = _first_line(["meson", "--version"])
    timestamp = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")

    meson_log = build_dir / "meson-logs/meson-log.txt"
    tail_out = stage / "provenance/meson-logs/meson-log.tail.txt"
    if meson_log.is_file():
        data = meson_log.read_bytes()
        tail_out.write_bytes(data[-200_000:])

    out_json = stage / "provenance/build-info.json"
    env = os.environ.copy()
    env.update(
        {
            "BIN_SHA": bin_sha,
            "LIB_SHA": lib_sha,
            "TIMESTAMP": timestamp,
            "GFORTRAN_VERSION": gfortran_v,
            "GCC_VERSION": gcc_v,
            "GPP_VERSION": gpp_v,
            "NINJA_VERSION": ninja_ver,
            "MESON_VERSION_OUT": meson_ver,
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


if __name__ == "__main__":
    raise SystemExit(main())
