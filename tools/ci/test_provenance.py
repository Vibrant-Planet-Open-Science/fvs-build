#!/usr/bin/env python3
"""Check provenance.py's SBOM against the SPDX validator, and its env reading.

Runs as a pre-commit hook with spdx-tools installed; the build job itself
stays stdlib-only.
"""

from provenance import Config, spdx_document
from spdx_tools.spdx.parser.jsonlikedict.json_like_dict_parser import (
    JsonLikeDictParser,
)
from spdx_tools.spdx.validation.document_validator import (
    validate_full_spdx_document,
)

SHA = "0" * 39 + "1"
MANIFEST = {
    "artifact_name": "fvs-native-linux-x86_64-1",
    "build": {
        "workflow_run_url": "https://github.com/o/r/actions/runs/1",
        "workflow_run_attempt": "1",
        "generated_at_utc": "2026-01-01T00:00:00Z",
    },
    "source": {
        "repo": "USDAForestService/ForestVegetationSimulator",
        "ref": "2027.1.0",
        "sha": SHA,
        "nvel": {
            "url": "https://github.com/FMSC-Measurements/VolumeLibrary",
            "sha": SHA,
        },
        "sqlite_version": "3.33.0",
    },
    "fvs_build": {"sha": SHA},
    "toolchain": {"gcc_version": "gcc (GCC) 14.2.1 20250110 (Red Hat 14.2.1-11)"},
}
FILES = {
    name: {"SHA1": "a" * 40, "SHA256": "b" * 64}
    for name in ("FVSak", "FVSak.so", "FVSbm", "FVSbm.so")
}


def test_sbom_is_valid_spdx() -> None:
    """The document parses and validates, with the expected links."""
    doc = spdx_document(MANIFEST, FILES, "linux")
    errors = validate_full_spdx_document(JsonLikeDictParser().parse(doc))
    assert not errors, [e.validation_message for e in errors]
    kinds = [r["relationshipType"] for r in doc["relationships"]]
    assert kinds.count("DESCRIBES") == 4
    assert kinds.count("GENERATED_FROM") == 12
    assert kinds.count("DYNAMIC_LINK") == kinds.count("STATIC_LINK") == 2
    gcc = next(p for p in doc["packages"] if p["SPDXID"].endswith("GCC-runtime"))
    assert gcc["versionInfo"] == "14.2.1"


GOOD_ENV = {
    "GITHUB_RUN_ID": "7",
    "GITHUB_RUN_ATTEMPT": "1",
    "VARIANTS": "ak bm",
    "BUILD_PROFILE": "reference",
    "SOURCE_SHA": SHA,
    "FVS_BUILD_SHA": SHA,
    "FVS_BUILD_REF": "o/r/.github/workflows/b.yml@refs/tags/v1",
    "GCC_MAJOR": "14",
    "VARIANTS_INPUT": "",  # the default: resolve_variants.sh picks the list
    **{
        k: "x"
        for k in (
            "SOURCE_REPO SOURCE_REF FVS_BUILD_REPO RUNNER_IMAGE"
            " GFORTRAN_PKG GPP_PKG FC CC CXX GITHUB_SERVER_URL GITHUB_REPOSITORY"
        ).split()
    },
}


def test_bundle_names() -> None:
    """Every OS and arch spelling maps to fvs-native-<os>-<arch>-<run_id>."""
    for sys_platform, machine, name in [
        ("linux", "x86_64", "fvs-native-linux-x86_64-7"),
        ("linux", "aarch64", "fvs-native-linux-aarch64-7"),
        ("win32", "AMD64", "fvs-native-windows-x86_64-7"),
        ("darwin", "arm64", "fvs-native-macos-aarch64-7"),
    ]:
        cfg = Config.from_env(GOOD_ENV, sys_platform, machine)
        assert cfg.artifact_name == name, cfg.artifact_name
        assert cfg.fvs_build_ref == "refs/tags/v1", cfg.fvs_build_ref


def test_config_reports_every_bad_variable() -> None:
    """One error lists each missing or malformed input."""
    try:
        Config.from_env({"SOURCE_SHA": "abc"}, "solaris", "sparc")
    except SystemExit as exc:
        msg = str(exc)
    else:
        raise AssertionError("expected SystemExit")
    for name in (
        "sys.platform='solaris'",
        "'sparc'",
        "SOURCE_SHA='abc'",
        "FVS_BUILD_SHA",
    ):
        assert name in msg, msg


if __name__ == "__main__":
    test_sbom_is_valid_spdx()
    test_bundle_names()
    test_config_reports_every_bad_variable()
    print("ok")
