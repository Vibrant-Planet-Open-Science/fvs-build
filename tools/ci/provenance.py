#!/usr/bin/env python3
"""Assemble a native FVS bundle, and read its manifest back (stdlib only).

`bundle` runs as the last step of each native build job. It reads its inputs
from the environment (see `Config`), copies the executables and stripped
shared libraries from the Meson build directory into
`fvs-native-<os>-<arch>-<run_id>/`, and writes `provenance/manifest.json`,
`provenance/per-variant/FVS<v>.json`, `provenance/meson-log.tail.txt` and
the SPDX SBOM. It appends `artifact_name=<that name>` to `$GITHUB_OUTPUT`.

`manifest-to-github-env` exports manifest fields for the container workflows.
"""

from __future__ import annotations

import argparse
import ctypes
import hashlib
import json
import os
import platform
import re
import shlex
import shutil
import subprocess
import sys
from collections.abc import Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

_SHA = r"[0-9a-f]{40}"
_NUM = r"[0-9]+"
_ANY = r".+"
_OS = {"linux": "linux", "win32": "windows", "darwin": "macos"}
_ARCH = {
    "x86_64": "x86_64",
    "amd64": "x86_64",
    "aarch64": "aarch64",
    "arm64": "aarch64",
}
SBOM = "sbom/fvs-native.spdx.json"


@dataclass(frozen=True)
class Config:
    """Bundle inputs, read once from the environment."""

    os: str
    arch: str
    variants: tuple[str, ...]
    variants_input: str
    profile: str
    source_repo: str
    source_ref: str
    source_sha: str
    fvs_build_repo: str
    fvs_build_ref: str
    fvs_build_sha: str
    runner_image: str
    gcc_major: str
    gfortran_package: str
    gpp_package: str
    compilers: tuple[str, str, str]
    run_id: str
    run_attempt: str
    run_url: str
    build_dir: Path
    source_dir: Path

    @property
    def artifact_name(self) -> str:
        """The bundle's directory and artifact name."""
        return f"fvs-native-{self.os}-{self.arch}-{self.run_id}"

    @classmethod
    def from_env(
        cls,
        env: Mapping[str, str] = os.environ,
        sys_platform: str = sys.platform,
        machine: str = platform.machine(),
    ) -> Config:
        """Read and check every input, reporting all bad ones at once.

        `FVS_BUILD_REF` may be `job.workflow_ref`
        (`<owner>/<repo>/<path>@<ref>`); only `<ref>` is kept.
        """
        errors: list[str] = []
        os_name, arch = _OS.get(sys_platform), _ARCH.get(machine.lower())
        if not os_name:
            errors.append(f"sys.platform={sys_platform!r}")
        if not arch:
            errors.append(f"platform.machine()={machine!r}")

        def get(name: str, pattern: str = _ANY, default: str = "") -> str:
            val = env.get(name, default).strip()
            if not re.fullmatch(pattern, val):
                errors.append(f"{name}={val!r}")
            return val

        run_id = get("GITHUB_RUN_ID", _NUM)
        cfg = cls(
            os=os_name or "",
            arch=arch or "",
            variants=tuple(get("VARIANTS", r"[a-z0-9]+( [a-z0-9]+)*").split()),
            variants_input=get("VARIANTS_INPUT", ".*"),
            profile=get("BUILD_PROFILE", "reference|debug"),
            source_repo=get("SOURCE_REPO"),
            source_ref=get("SOURCE_REF"),
            source_sha=get("SOURCE_SHA", _SHA),
            fvs_build_repo=get("FVS_BUILD_REPO"),
            fvs_build_ref=get("FVS_BUILD_REF").rpartition("@")[2],
            fvs_build_sha=get("FVS_BUILD_SHA", _SHA),
            runner_image=get("RUNNER_IMAGE"),
            gcc_major=get("GCC_MAJOR", _NUM),
            gfortran_package=get("GFORTRAN_PKG"),
            gpp_package=get("GPP_PKG"),
            compilers=(get("FC"), get("CC"), get("CXX")),
            run_id=run_id,
            run_attempt=get("GITHUB_RUN_ATTEMPT", _NUM),
            run_url=(
                f"{get('GITHUB_SERVER_URL')}/{get('GITHUB_REPOSITORY')}"
                f"/actions/runs/{run_id}"
            ),
            build_dir=Path(get("BUILD_DIR", default="_build")),
            source_dir=Path(get("FVS_SOURCE", default="fvs-source")),
        )
        if errors:
            sys.exit(
                "error: missing or invalid environment variables: " + ", ".join(errors)
            )
        return cfg


def extract_resolved_fortran_args(build_dir: Path) -> list[str]:
    """Return project Fortran flags from the first matching compile command.

    `meson-log.txt` lacks per-target Fortran arguments, so this reads
    `compile_commands.json`, which exists only once Ninja has run.
    """
    cc_path = build_dir / "compile_commands.json"
    if not cc_path.is_file():
        return []
    entries = json.loads(cc_path.read_text(encoding="utf-8"))
    marker = "-cpp"
    for entry in entries:
        cmd = entry.get("command", "")
        if marker not in cmd or "-DCMPgcc" not in cmd:
            continue
        parts = shlex.split(cmd)
        try:
            start = parts.index(marker)
        except ValueError:
            continue
        flags: list[str] = []
        for arg in parts[start:]:
            if arg.startswith("-I") or arg.startswith("-J") or arg == "-o":
                break
            if arg.endswith((".f", ".F", ".f90", ".F90", ".F77", ".for")):
                break
            flags.append(arg)
        if flags:
            return flags
    return []


def _first_line(cmd: list[str]) -> str:
    out = subprocess.run(
        cmd, check=True, capture_output=True, text=True, timeout=60
    ).stdout
    return out.splitlines()[0].strip() if out else ""


def _hashes(path: Path) -> dict[str, str]:
    data = path.read_bytes()
    return {
        "SHA1": hashlib.sha1(data, usedforsecurity=False).hexdigest(),
        "SHA256": hashlib.sha256(data).hexdigest(),
    }


def _utc(ts: datetime) -> str:
    return ts.strftime("%Y-%m-%dT%H:%M:%SZ")


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def _spdx_package(
    spdx_id: str, name: str, version: str, location: str, license_id: str
) -> dict[str, Any]:
    return {
        "name": name,
        "SPDXID": f"SPDXRef-Package-{spdx_id}",
        "versionInfo": version,
        "downloadLocation": location,
        "filesAnalyzed": False,
        "licenseConcluded": license_id,
        "licenseDeclared": license_id,
        "copyrightText": "NOASSERTION",
    }


def spdx_document(
    manifest: dict[str, Any], files: dict[str, dict[str, str]], os_name: str
) -> dict[str, Any]:
    """Return the bundle's SPDX 2.3 document.

    Meson-built binaries carry no package metadata a scanner could find, so the
    components compiled into them come from the manifest.

    Args:
        manifest: The bundle's `manifest.json` content.
        files: Bundled file name to `{"SHA1": ..., "SHA256": ...}`.
        os_name: `linux`, `windows` or `macos`.
    """
    name, build = manifest["artifact_name"], manifest["build"]
    src, nvel = manifest["source"], manifest["source"]["nvel"]
    gcc = re.search(r"\) (\d+\.\d+\.\d+)", manifest["toolchain"]["gcc_version"])
    fvs_url = f"git+https://github.com/{src['repo']}@{src['sha']}"
    nvel_url = f"git+{nvel['url']}@{nvel['sha']}"
    sources = [
        _spdx_package(*row)
        for row in [
            ("FVS", "ForestVegetationSimulator", src["ref"], fvs_url, "CC0-1.0"),
            ("NVEL", "VolumeLibrary", nvel["sha"], nvel_url, "CC0-1.0"),
            ("SQLite", "SQLite", src["sqlite_version"], "NOASSERTION", "blessing"),
        ]
    ]
    gcc_runtime = _spdx_package(
        "GCC-runtime",
        "GCC runtime libraries (libgfortran, libgcc, libquadmath)",
        gcc[1] if gcc else "NOASSERTION",
        "https://gcc.gnu.org/",
        "GPL-3.0-or-later WITH GCC-exception-3.1 AND LGPL-2.1-or-later",
    )
    entries = []
    links = []
    for file_name, sums in files.items():
        spdx_id = f"SPDXRef-File-{file_name}"
        entries.append(
            {
                "fileName": f"./{file_name}",
                "SPDXID": spdx_id,
                "checksums": [
                    {"algorithm": alg, "checksumValue": val}
                    for alg, val in sums.items()
                ],
                "licenseConcluded": "NOASSERTION",
                "copyrightText": "NOASSERTION",
            }
        )
        # Only the Linux shared libraries load the GCC runtime dynamically.
        dynamic = os_name == "linux" and file_name.endswith(".so")
        links += [
            ("SPDXRef-DOCUMENT", "DESCRIBES", spdx_id),
            *((spdx_id, "GENERATED_FROM", p["SPDXID"]) for p in sources),
            (
                spdx_id,
                "DYNAMIC_LINK" if dynamic else "STATIC_LINK",
                gcc_runtime["SPDXID"],
            ),
        ]
    return {
        "spdxVersion": "SPDX-2.3",
        "dataLicense": "CC0-1.0",
        "SPDXID": "SPDXRef-DOCUMENT",
        "name": name,
        "documentNamespace": (
            f"{build['workflow_run_url']}/attempts/{build['workflow_run_attempt']}"
            f"/{name}"
        ),
        "creationInfo": {
            "created": build["generated_at_utc"],
            "creators": [f"Tool: fvs-build-{manifest['fvs_build']['sha']}"],
        },
        "packages": [*sources, gcc_runtime],
        "files": entries,
        "relationships": [
            {"spdxElementId": a, "relationshipType": kind, "relatedSpdxElement": b}
            for a, kind, b in links
        ],
    }


def cmd_bundle(_args: argparse.Namespace) -> int:
    """Assemble the bundle described in the module docstring."""
    cfg = Config.from_env()
    out = Path(cfg.artifact_name)
    fc, cc, cxx = cfg.compilers
    nvel_dir = str(cfg.source_dir / "volume/NVEL")
    sqlite_c = (cfg.source_dir / "dbsqlite/sqlite3.c").read_text(errors="replace")
    source = {
        "repo": cfg.source_repo,
        "ref": cfg.source_ref,
        "sha": cfg.source_sha,
        "nvel": {
            "url": _first_line(["git", "-C", nvel_dir, "remote", "get-url", "origin"]),
            "sha": _first_line(["git", "-C", nvel_dir, "rev-parse", "HEAD"]),
        },
        "sqlite_version": re.search(r'#define SQLITE_VERSION\s+"([^"]+)"', sqlite_c)[1],
    }
    fvs_build = {
        "repo": cfg.fvs_build_repo,
        "ref": cfg.fvs_build_ref,
        "sha": cfg.fvs_build_sha,
    }
    toolchain = {
        "runner_image": cfg.runner_image,
        "gcc_major": cfg.gcc_major,
        "gfortran_package": cfg.gfortran_package,
        "gpp_package": cfg.gpp_package,
        "meson_pin": re.search(
            r"^meson==(\S+)",
            (Path(__file__).parent / "requirements-build.txt").read_text(),
            re.M,
        )[1],
        "gfortran_version": _first_line([fc, "--version"]),
        "gcc_version": _first_line([cc, "--version"]),
        "gpp_version": _first_line([cxx, "--version"]),
        "ninja_version": _first_line(["ninja", "--version"]),
        "meson_version": _first_line(["meson", "--version"]),
        "python_version": platform.python_version(),
    }
    build = {
        "workflow_run_id": cfg.run_id,
        "workflow_run_attempt": cfg.run_attempt,
        "profile": cfg.profile,
        "buildtype": "plain",
        "fortran_args": extract_resolved_fortran_args(cfg.build_dir),
    }
    out.mkdir(exist_ok=True)
    files: dict[str, dict[str, str]] = {}
    binaries, libraries = [], []
    for variant in cfg.variants:
        if cfg.os == "windows":
            exe, lib = f"FVS{variant}.exe", f"FVS{variant}.dll"
        else:
            exe, lib = f"FVS{variant}", f"FVS{variant}.so"
        shutil.copy2(cfg.build_dir / exe, out / exe)
        shutil.copy2(cfg.build_dir / lib, out / lib)
        # -S is --strip-debug in GNU strip (Linux, MSYS2) and Apple's strip alike.
        subprocess.run(["strip", "-S", str(out / lib)], check=True)
        # Stripping rewrites the file (and on macOS its ad-hoc signature): make
        # sure the shipped library still loads.
        ctypes.CDLL(str((out / lib).resolve()))
        files[exe], files[lib] = _hashes(out / exe), _hashes(out / lib)
        binaries.append(exe)
        libraries.append(lib)
        # copy2 keeps the link time; Ninja leaves unchanged outputs alone, so on
        # a build cache hit this stays the original link time.
        linked = datetime.fromtimestamp((out / exe).stat().st_mtime, timezone.utc)
        _write_json(
            out / f"provenance/per-variant/FVS{variant}.json",
            {
                "schema_version": 1,
                "variant": variant,
                "arch": cfg.arch,
                "binary": exe,
                "shared_library": lib,
                "binary_sha256": files[exe]["SHA256"],
                "shared_library_sha256": files[lib]["SHA256"],
                "compiled_at_utc": _utc(linked),
                "source": source,
                "fvs_build": fvs_build,
                "toolchain": toolchain,
                "build": build,
            },
        )

    meson_log = cfg.build_dir / "meson-logs/meson-log.txt"
    if meson_log.is_file():
        tail = meson_log.read_bytes()[-200_000:]
        (out / "provenance/meson-log.tail.txt").write_bytes(tail)

    manifest = {
        "schema_version": 1,
        "artifact_name": cfg.artifact_name,
        "arch": cfg.arch,
        "build": {
            **build,
            "workflow_run_url": cfg.run_url,
            "generated_at_utc": _utc(datetime.now(timezone.utc)),
            "variants_input": cfg.variants_input,
            "variants_built": list(cfg.variants),
        },
        "source": source,
        "fvs_build": fvs_build,
        "toolchain": toolchain,
        "artifacts": {
            "binaries": binaries,
            "shared_libraries": libraries,
            "sbom": SBOM,
        },
    }
    _write_json(out / "provenance/manifest.json", manifest)
    _write_json(out / SBOM, spdx_document(manifest, files, cfg.os))
    if github_output := os.environ.get("GITHUB_OUTPUT"):
        with open(github_output, "a", encoding="utf-8") as fh:
            fh.write(f"artifact_name={cfg.artifact_name}\n")
    print(f"bundled {len(cfg.variants)} variants into {out}/")
    return 0


def cmd_manifest_to_github_env(_args: argparse.Namespace) -> int:
    """Append `bundle/provenance/manifest.json` fields to `$GITHUB_ENV`."""
    manifest_path = Path("bundle/provenance/manifest.json")
    github_env = os.environ.get("GITHUB_ENV", "").strip()
    if not github_env:
        sys.stderr.write("error: GITHUB_ENV is not set\n")
        return 1
    if not manifest_path.is_file():
        sys.stderr.write(f"error: manifest not found: {manifest_path}\n")
        return 1

    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    binaries: list[str] = data["artifacts"]["binaries"]
    lines = [
        f"SOURCE_REPO={data['source']['repo']}",
        f"SOURCE_REF={data['source']['ref']}",
        f"SOURCE_SHA={data['source']['sha']}",
        f"FVS_BUILD_REPO={data['fvs_build']['repo']}",
        f"FVS_BUILD_REF={data['fvs_build']['ref']}",
        f"FVS_BUILD_SHA={data['fvs_build']['sha']}",
        f"GFORTRAN_VERSION={data['toolchain']['gfortran_version']}",
        f"MESON_VERSION={data['toolchain']['meson_version']}",
        f"BUNDLE_ARCH={data['arch']}",
        f"VARIANTS_BUILT={','.join(b.removeprefix('FVS') for b in binaries)}",
    ]
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines.append(f"TIMESTAMP={ts}")

    with Path(github_env).open("a", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")

    return 0


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = p.add_subparsers(dest="command", required=True)

    p_bundle = sub.add_parser(
        "bundle", help="Assemble the bundle from the build directory (env-driven)."
    )
    p_bundle.set_defaults(func=cmd_bundle)

    p_env = sub.add_parser(
        "manifest-to-github-env",
        help="Export manifest fields to $GITHUB_ENV.",
    )
    p_env.set_defaults(func=cmd_manifest_to_github_env)

    return p


def main(argv: list[str] | None = None) -> int:
    """Parse CLI arguments and dispatch."""
    parser = _build_parser()
    args = parser.parse_args(argv)
    return int(args.func(args))


if __name__ == "__main__":
    raise SystemExit(main())
