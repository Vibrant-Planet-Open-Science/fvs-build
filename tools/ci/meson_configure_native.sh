#!/usr/bin/env bash
# Configure (or reconfigure) the Meson build directory for native CI build jobs.
# VARIANTS is space-separated; OVERLAY_DIR is the fvs-build checkout.
set -euo pipefail

BUILD_DIR="${BUILD_DIR:-_build}"
OVERLAY_DIR="${OVERLAY_DIR:-fvs-build}"
FVS_SOURCE="${FVS_SOURCE:?FVS_SOURCE is required}"
VARIANTS="${VARIANTS:?VARIANTS is required}"
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
  -Dvariants="${VARIANTS// /,}"
  -Dprofile="${PROFILE}"
)

if [ -d "${BUILD_DIR}" ]; then
  meson setup --reconfigure "${BUILD_DIR}" "${OVERLAY_DIR}" "${ARGS[@]}"
else
  meson setup "${BUILD_DIR}" "${OVERLAY_DIR}" "${ARGS[@]}"
fi
