#!/usr/bin/env bash
# Configure (or reconfigure) the Meson build directory for native CI matrix jobs.
#
# Required environment variables:
#   BUILD_DIR   — Meson build directory (default: _build)
#   OVERLAY_DIR — path to fvs-build overlay (default: fvs-build)
#   FVS_SOURCE  — path to checked-out FVS source tree
#   VARIANT     — single variant code for this matrix leg
#   PROFILE     — reference or debug (default: reference)
#
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-_build}"
OVERLAY_DIR="${OVERLAY_DIR:-fvs-build}"
FVS_SOURCE="${FVS_SOURCE:?FVS_SOURCE is required}"
VARIANT="${VARIANT:?VARIANT is required}"
PROFILE="${PROFILE:-reference}"

case "${PROFILE}" in
  reference | debug) ;;
  *)
    echo "ERROR: unknown profile '${PROFILE}'; expected reference or debug" >&2
    exit 1
    ;;
esac

ARGS=(
  --buildtype=plain
  -Dfvs_source_dir="${FVS_SOURCE}"
  -Dvariants="${VARIANT}"
  -Dprofile="${PROFILE}"
)

if [ -d "${BUILD_DIR}" ]; then
  meson setup --reconfigure "${BUILD_DIR}" "${OVERLAY_DIR}" "${ARGS[@]}"
else
  meson setup "${BUILD_DIR}" "${OVERLAY_DIR}" "${ARGS[@]}"
fi
