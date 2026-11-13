#!/usr/bin/env bash
# Smoke-test each variant executable after the native build. `STOP 20` is what
# FVS raises on EOF before reading a keyfile. Runs from a temp dir so fort.<N>
# spillover does not land next to the build outputs. VARIANTS is space-separated.
set -euo pipefail

VARIANTS="${VARIANTS:?VARIANTS is required}"
FVS_SOURCE="${FVS_SOURCE:-${GITHUB_WORKSPACE:?set FVS_SOURCE or GITHUB_WORKSPACE}/fvs-source}"
BUILD_DIR="${BUILD_DIR:-_build}"

# The executable must not load its own embedder library at runtime (on Windows
# the workflow's objdump import check covers this).
case "$(uname -s)" in
  Linux) suffix='' deps='ldd' ;;
  Darwin) suffix='' deps='otool -L' ;;
  MINGW* | MSYS*) suffix='.exe' deps='' ;;
  *)
    echo "ERROR: unsupported platform $(uname -s)" >&2
    exit 1
    ;;
esac

for v in $VARIANTS; do
  exe="FVS${v}${suffix}"
  [ -f "${BUILD_DIR}/${exe}" ] || {
    echo "ERROR: ${BUILD_DIR}/${exe} not found" >&2
    exit 1
  }
  if [ -n "$deps" ] && $deps "${BUILD_DIR}/${exe}" | grep -q "FVS${v}\.so"; then
    echo "ERROR: ${exe} must not depend on FVS${v}.so at runtime" >&2
    exit 1
  fi
  smoke_dir="$(mktemp -d)"
  cp "${BUILD_DIR}/${exe}" "$smoke_dir/"
  output="$( (cd "$smoke_dir" && "./${exe}" </dev/null 2>&1) || true)"
  if [ -f "${FVS_SOURCE}/base/version.f90" ]; then
    version="$(cd "$smoke_dir" && "./${exe}" --version)"
    echo "FVS${v} --version: ${version}"
    case "$version" in
      "" | unknown* | *-dirty*)
        echo "ERROR: unusable build info for FVS${v}: ${version}" >&2
        exit 1
        ;;
    esac
  fi
  rm -rf "$smoke_dir"
  echo "----- FVS${v} smoke output (first 30 lines) -----"
  printf '%s\n' "$output" | head -n 30
  echo "----- end smoke output -----"
  printf '%s\n' "$output" | grep -q 'STOP 20' || {
    echo "ERROR: smoke test for FVS${v} did not reach STOP 20" >&2
    exit 1
  }
done
