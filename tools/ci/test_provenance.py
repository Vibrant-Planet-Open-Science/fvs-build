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


def test_config_reports_every_bad_variable() -> None:
    """One error lists each missing or malformed input."""
    try:
        Config.from_env({"FVS_NATIVE_PLATFORM": "solaris", "SOURCE_SHA": "abc"})
    except SystemExit as exc:
        msg = str(exc)
    else:
        raise AssertionError("expected SystemExit")
    for name in ("FVS_NATIVE_PLATFORM='solaris'", "SOURCE_SHA='abc'", "ARTIFACT_NAME"):
        assert name in msg, msg


if __name__ == "__main__":
    test_sbom_is_valid_spdx()
    test_config_reports_every_bad_variable()
    print("ok")
