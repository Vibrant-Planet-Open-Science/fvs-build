#!/usr/bin/env python3
"""GitHub Actions helpers for native bundle provenance JSON (stdlib only).

Platform-specific filenames and SBOM paths are selected with the environment
variable ``FVS_NATIVE_PLATFORM``: ``linux`` (default), ``windows``, or
``darwin``. Native workflows set this when staging artifacts and when running
``collect-bundle``.

* ``write-build-info`` — one per-variant ``build-info.json`` (schema_version 1).
* ``collect-bundle`` — fan ``staging/<os>-variant-*`` into a **flat** bundle
  root (``FVS<v>`` / ``libFVS<v>.*`` plus ``provenance/``, ``sbom/``).
  Per-variant staging keeps binaries and shared libs at the variant directory
  root (not under a ``lib/`` subdirectory). Artifact names use an ``<os>``
  prefix (``linux-``, ``macos-``, ``windows-``) so parallel reusable native
  workflows in the **same** GitHub Actions run do not collide on ``variant-<v>``.
* ``manifest-to-github-env`` — append Docker-related variables to
  ``$GITHUB_ENV`` from ``bundle/provenance/manifest.json``.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _require_env(name: str) -> str:
    val = os.environ.get(name, "").strip()
    if not val:
        sys.stderr.write(f"error: missing or empty environment variable: {name}\n")
        sys.exit(1)
    return val


def _native_platform() -> str:
    """Set FVS_NATIVE_PLATFORM in CI per runner OS."""
    raw = os.environ.get("FVS_NATIVE_PLATFORM", "linux").strip().lower()
    if raw not in ("linux", "windows", "darwin"):
        msg = (
            "error: FVS_NATIVE_PLATFORM must be linux, windows, or darwin; "
            f"got {raw!r}\n"
        )
        sys.stderr.write(msg)
        sys.exit(1)
    return raw


def _variant_artifact_staging_prefix() -> str:
    """Directory/artifact prefix for per-variant uploads (must match workflows)."""
    plat = _native_platform()
    if plat == "linux":
        return "linux-variant-"
    if plat == "darwin":
        return "macos-variant-"
    return "windows-variant-"


def _binary_filename(variant: str) -> str:
    if _native_platform() == "windows":
        return f"FVS{variant}.exe"
    return f"FVS{variant}"


def _shared_library_filename(variant: str) -> str:
    plat = _native_platform()
    if plat == "windows":
        return f"libFVS{variant}.dll"
    if plat == "darwin":
        return f"libFVS{variant}.dylib"
    return f"libFVS{variant}.so"


def _sbom_relative_path() -> str:
    plat = _native_platform()
    if plat == "windows":
        return "sbom/fvs-native-windows.spdx.json"
    if plat == "darwin":
        return "sbom/fvs-native-macos.spdx.json"
    return "sbom/fvs-native-linux.spdx.json"


def _per_variant_document() -> dict[str, Any]:
    """Build the per-variant provenance dict from the process environment."""
    variant = _require_env("VARIANT")
    return {
        "schema_version": 1,
        "variant": variant,
        "binary": _binary_filename(variant),
        "shared_library": _shared_library_filename(variant),
        "binary_sha256": _require_env("BIN_SHA"),
        "shared_library_sha256": _require_env("LIB_SHA"),
        "compiled_at_utc": _require_env("TIMESTAMP"),
        "source": {
            "repo": _require_env("SOURCE_REPO"),
            "ref": _require_env("SOURCE_REF"),
            "sha": _require_env("SOURCE_SHA"),
        },
        "fvs_build": {
            "repo": _require_env("FVS_BUILD_REPO"),
            "ref": _require_env("FVS_BUILD_REF"),
            "sha": _require_env("FVS_BUILD_SHA"),
        },
        "toolchain": {
            "runner_image": _require_env("RUNNER_IMAGE"),
            "gfortran_package": _require_env("GFORTRAN_PKG"),
            "gpp_package": _require_env("GPP_PKG"),
            "gfortran_version": _require_env("GFORTRAN_VERSION"),
            "gcc_version": _require_env("GCC_VERSION"),
            "gpp_version": _require_env("GPP_VERSION"),
            "ninja_version": _require_env("NINJA_VERSION"),
            "meson_version": _require_env("MESON_VERSION_OUT"),
            "meson_pin": _require_env("MESON_PIN"),
        },
        "build": {
            "workflow_run_id": _require_env("GITHUB_RUN_ID"),
            "workflow_run_attempt": _require_env("GITHUB_RUN_ATTEMPT"),
        },
    }


def _write_json(path: Path, data: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    path.write_text(text, encoding="utf-8")


def cmd_write_build_info(args: argparse.Namespace) -> int:
    """Write a single per-variant ``build-info.json`` file."""
    _write_json(Path(args.output), _per_variant_document())
    return 0


def _load_per_variant_jsons(per_variant_dir: Path) -> list[dict[str, Any]]:
    paths = sorted(per_variant_dir.glob("FVS*.json"))
    if not paths:
        sys.stderr.write(
            f"error: no per-variant JSON under {per_variant_dir}\n",
        )
        sys.exit(1)
    out: list[dict[str, Any]] = []
    for p in paths:
        out.append(json.loads(p.read_text(encoding="utf-8")))
    return out


def _bundle_manifest_document(
    per_variant: list[dict[str, Any]],
    *,
    artifact_name: str,
    variants_input: str,
    runner_image: str,
    gfortran_pkg: str,
    gpp_pkg: str,
    meson_pin: str,
    timestamp: str,
    run_id: str,
    run_attempt: str,
    server_url: str,
    repository: str,
) -> dict[str, Any]:
    first = per_variant[0]
    return {
        "schema_version": 1,
        "artifact_name": artifact_name,
        "build": {
            "workflow_run_id": run_id,
            "workflow_run_attempt": run_attempt,
            "workflow_run_url": f"{server_url}/{repository}/actions/runs/{run_id}",
            "generated_at_utc": timestamp,
            "variants_input": variants_input,
            "variants_built": [pv["variant"] for pv in per_variant],
        },
        "source": first["source"],
        "fvs_build": first["fvs_build"],
        "toolchain": {
            "runner_image": runner_image,
            "gfortran_package": gfortran_pkg,
            "gpp_package": gpp_pkg,
            "meson_pin": meson_pin,
            "gfortran_version": first["toolchain"]["gfortran_version"],
            "gcc_version": first["toolchain"]["gcc_version"],
            "gpp_version": first["toolchain"]["gpp_version"],
            "ninja_version": first["toolchain"]["ninja_version"],
            "meson_version": first["toolchain"]["meson_version"],
        },
        "artifacts": {
            "binaries": [pv["binary"] for pv in per_variant],
            "shared_libraries": [pv["shared_library"] for pv in per_variant],
            "sbom": _sbom_relative_path(),
        },
    }


def _make_executable(path: Path) -> None:
    mode = path.stat().st_mode
    path.chmod(mode | 0o111)


def _describe_path_entry(path: Path) -> str:
    """One-line description for diagnostic listings (collect-bundle)."""
    if path.is_symlink():
        try:
            target = path.readlink()
            tail = f"symlink -> {target}"
        except OSError as exc:
            tail = f"symlink (readlink failed: {exc})"
    elif path.is_dir():
        tail = "directory"
    elif path.is_file():
        tail = "file"
    else:
        tail = "other"
    return f"{path.name!r} ({tail})"


def _emit_collect_bundle_missing_file(
    *,
    role: str,
    variant: str,
    expected: Path,
    vd: Path,
    staging_dir: Path,
) -> None:
    plat = _native_platform()
    lib_expect = _shared_library_filename(variant)
    lines = [
        f"error: collect-bundle: {role} missing for variant {variant!r}",
        f"  FVS_NATIVE_PLATFORM={plat!r} "
        f"(expected shared library filename: {lib_expect!r})",
        f"  expected path: {expected}",
        f"  exists={expected.exists()}  is_file={expected.is_file()}  "
        f"is_symlink={expected.is_symlink()}",
    ]
    if vd.is_dir():
        lines.append(f"  contents of {vd}:")
        try:
            for child in sorted(vd.iterdir(), key=lambda p: p.name.lower()):
                lines.append(f"    {_describe_path_entry(child)}")
        except OSError as exc:
            lines.append(f"    (could not list directory: {exc})")
    else:
        lines.append(f"  variant directory missing or not a directory: {vd}")
    want = _variant_artifact_staging_prefix()
    lines.append(
        f"  sibling {want}* directories under {staging_dir}:",
    )
    try:
        sibs = sorted(
            staging_dir.glob(f"{want}*/"),
            key=lambda p: p.name.lower(),
        )
        if sibs:
            for s in sibs:
                lines.append(f"    {s.name}/")
        else:
            lines.append("    (none)")
    except OSError as exc:
        lines.append(f"    (could not list: {exc})")
    lines.append(
        "  hints: (1) open the matrix job log and confirm "
        "'----- staged staging/<code> -----' lists the same filenames; "
        "(2) download the linux-variant-* (or macos-/windows-) zip and check "
        "the shared library is inside; "
        "(3) merge-multiple=false (default) extracts each artifact under "
        "staging/<artifact-name>/; "
        "(4) if you see macos-variant-* while collecting a Linux bundle, "
        "another job in the same workflow run likely overwrote unprefixed "
        "variant-* artifacts — use OS-prefixed artifact names (this repo does)."
    )
    sys.stderr.write("\n".join(lines) + "\n")
    sys.exit(1)


def _collect_require_file(
    path: Path,
    *,
    role: str,
    variant: str,
    vd: Path,
    staging_dir: Path,
) -> None:
    if path.is_file():
        return
    _emit_collect_bundle_missing_file(
        role=role,
        variant=variant,
        expected=path,
        vd=vd,
        staging_dir=staging_dir,
    )


def cmd_collect_bundle(_args: argparse.Namespace) -> int:
    """Fan staging artifacts into the bundle directory and write manifest.json."""
    staging_dir = Path(os.environ.get("STAGING_DIR", "staging"))
    artifact_name = _require_env("ARTIFACT_NAME")
    bundle = Path(artifact_name)

    subdirs = (
        "provenance/per-variant",
        "provenance/meson-logs",
        "sbom",
    )
    for sub in subdirs:
        (bundle / sub).mkdir(parents=True, exist_ok=True)

    dir_prefix = _variant_artifact_staging_prefix()
    variant_dirs = sorted(staging_dir.glob(f"{dir_prefix}*/"))
    if not variant_dirs:
        sys.stderr.write(
            f"error: no directories matching {staging_dir}/{dir_prefix}*/\n",
        )
        abs_staging = staging_dir.resolve()
        if staging_dir.is_dir():
            sys.stderr.write(f"  contents of {abs_staging}:\n")
            try:
                for child in sorted(
                    staging_dir.iterdir(),
                    key=lambda p: p.name.lower(),
                ):
                    sys.stderr.write(f"    {_describe_path_entry(child)}\n")
            except OSError as exc:
                sys.stderr.write(f"    (could not list: {exc})\n")
            if dir_prefix == "linux-variant-" and list(
                staging_dir.glob("macos-variant-*/"),
            ):
                sys.stderr.write(
                    "  hint: found macos-variant-* but expected linux-variant-* — "
                    "download-artifact pattern should be linux-variant-* for "
                    "build-native-linux.yml.\n",
                )
            if dir_prefix == "linux-variant-" and list(
                staging_dir.glob("variant-*/"),
            ):
                sys.stderr.write(
                    "  hint: found legacy variant-* directories (no OS prefix). "
                    "Older workflows collided when Linux and macOS reusable jobs "
                    "ran in the same run; upgrade fvs-build workflows to "
                    "linux-variant-* / macos-variant-* artifact names.\n",
                )
        else:
            sys.stderr.write(
                f"  staging directory does not exist: {abs_staging}\n",
            )
        sys.stderr.write(
            "  hint: with multiple artifacts, download-artifact extracts each "
            "into staging/<artifact-name>/ by default. "
            "merge-multiple=true places all files directly in path/ and breaks "
            "this layout.\n",
        )
        sys.exit(1)

    abs_staging = staging_dir.resolve()
    print(
        "collect-bundle: "
        f"FVS_NATIVE_PLATFORM={_native_platform()!r} STAGING_DIR={abs_staging}",
    )
    print(
        "collect-bundle: variant directories: "
        + ", ".join(p.name for p in variant_dirs),
    )

    for vd in variant_dirs:
        variant = vd.name.removeprefix(dir_prefix)
        bin_name = _binary_filename(variant)
        lib_name = _shared_library_filename(variant)
        bin_path = vd / bin_name
        lib_path = vd / lib_name
        info_path = vd / "provenance" / "build-info.json"
        _collect_require_file(
            bin_path,
            role="executable",
            variant=variant,
            vd=vd,
            staging_dir=staging_dir,
        )
        _collect_require_file(
            lib_path,
            role="shared library",
            variant=variant,
            vd=vd,
            staging_dir=staging_dir,
        )
        _collect_require_file(
            info_path,
            role="provenance/build-info.json",
            variant=variant,
            vd=vd,
            staging_dir=staging_dir,
        )
        shutil.copy2(bin_path, bundle / bin_name)
        shutil.copy2(lib_path, bundle / lib_name)
        shutil.copy2(
            info_path,
            bundle / "provenance" / "per-variant" / f"FVS{variant}.json",
        )
        tail = vd / "provenance" / "meson-logs" / "meson-log.tail.txt"
        if tail.is_file():
            dest = (
                bundle
                / "provenance"
                / "meson-logs"
                / f"FVS{variant}.meson-log.tail.txt"
            )
            shutil.copy2(tail, dest)

    for exe in bundle.glob("FVS*"):
        if exe.suffix.lower() == ".exe" or exe.suffix == "":
            _make_executable(exe)

    per_variant = _load_per_variant_jsons(bundle / "provenance" / "per-variant")
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    manifest = _bundle_manifest_document(
        per_variant,
        artifact_name=artifact_name,
        variants_input=_require_env("VARIANTS_INPUT"),
        runner_image=_require_env("RUNNER_IMAGE"),
        gfortran_pkg=_require_env("GFORTRAN_PKG"),
        gpp_pkg=_require_env("GPP_PKG"),
        meson_pin=_require_env("MESON_PIN"),
        timestamp=ts,
        run_id=_require_env("GITHUB_RUN_ID"),
        run_attempt=_require_env("GITHUB_RUN_ATTEMPT"),
        server_url=_require_env("GITHUB_SERVER_URL"),
        repository=_require_env("GITHUB_REPOSITORY"),
    )
    _write_json(bundle / "provenance" / "manifest.json", manifest)

    print("----- bundle layout (top 80 lines) -----")
    proc = subprocess.run(
        ["ls", "-laR", str(bundle)],
        check=True,
        capture_output=True,
        text=True,
    )
    for line in proc.stdout.splitlines()[:80]:
        print(line)

    return 0


def _variants_built_csv(binaries: list[str]) -> str:
    codes = [name.removeprefix("FVS") for name in binaries]
    return ",".join(codes)


def cmd_manifest_to_github_env(args: argparse.Namespace) -> int:
    """Append provenance fields to GitHub Actions environment file."""
    manifest_path = Path(args.manifest)
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
        f"VARIANTS_BUILT={_variants_built_csv(binaries)}",
        f"VARIANTS_BINARIES={' '.join(binaries)}",
    ]
    ts = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    lines.append(f"TIMESTAMP={ts}")

    with Path(github_env).open("a", encoding="utf-8") as fh:
        for line in lines:
            fh.write(line + "\n")

    return 0


def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        description=(
            "Native bundle provenance helpers for GitHub Actions "
            "(Linux, Windows, macOS)."
        ),
    )
    sub = p.add_subparsers(dest="command", required=True)

    p_info = sub.add_parser(
        "write-build-info",
        help="Write per-variant build-info.json (env-driven).",
    )
    p_info.add_argument(
        "--output",
        required=True,
        type=Path,
        help="Path to write (e.g. staging/pn/provenance/build-info.json).",
    )
    p_info.set_defaults(func=cmd_write_build_info)

    p_coll = sub.add_parser(
        "collect-bundle",
        help=(
            "Assemble bundle from staging/<os>-variant-* "
            "(env-driven; see _variant_artifact_staging_prefix)."
        ),
    )
    p_coll.set_defaults(func=cmd_collect_bundle)

    p_env = sub.add_parser(
        "manifest-to-github-env",
        help="Export manifest fields to $GITHUB_ENV.",
    )
    p_env.add_argument(
        "--manifest",
        type=Path,
        default=Path("bundle/provenance/manifest.json"),
        help="Path to top-level manifest.json.",
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
