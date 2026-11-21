#!/usr/bin/env bash
# Run the FVS source's tests/FVS<v>/makefile against the built executables and
# fail unless every output with a .save beside it matches, ignoring run stamps
# (-999 lines, the page header) and sqlite3 CLI quoting and type case.
# DIFFS_WARN=1 reports a differing output as a warning instead of a failure.
set -uo pipefail
shopt -s nullglob

VARIANTS="${VARIANTS:?VARIANTS is required}"
FVS_SOURCE="${FVS_SOURCE:-${GITHUB_WORKSPACE:?set FVS_SOURCE or GITHUB_WORKSPACE}/fvs-source}"
BUILD_DIR="${BUILD_DIR:-_build}"
DIFFS_WARN="${DIFFS_WARN:-0}"

# The FVSie makefile reads iet01_Out_sqlite.sql, the file is
# iet01_out_sqlite.sql (USDAForestService/ForestVegetationSimulator#97).
# Already present where the filesystem ignores case.
ie_tests="${FVS_SOURCE}/tests/FVSie"
[ -e "${ie_tests}/iet01_Out_sqlite.sql" ] \
  || cp "${ie_tests}/iet01_out_sqlite.sql" "${ie_tests}/iet01_Out_sqlite.sql"

mkdir -p "${FVS_SOURCE}/bin"
targets=()
for v in $VARIANTS; do
  exe="${BUILD_DIR}/FVS${v}"
  [ -f "$exe" ] || exe+=".exe"
  cp "$exe" "${FVS_SOURCE}/bin/"
  targets+=("FVS${v}.test")
done
make -C "${FVS_SOURCE}/tests" "${targets[@]}"

normalized() {
  grep -v -e '-999' -e 'FOREST VEGETATION SIMULATOR *VERSION' "$1" | tr -d '"'
}

status=0
for v in $VARIANTS; do
  for golden in "${FVS_SOURCE}/tests/FVS${v}/"*.save; do
    output="${golden%.save}"
    name="FVS${v}/$(basename "$output")"
    if [ ! -f "$output" ]; then
      echo "FAIL ${name} (not written)"
      status=1
    elif diff -w -i --strip-trailing-cr <(normalized "$output") <(normalized "$golden"); then
      echo "PASS ${name}"
    elif [ "$DIFFS_WARN" = 1 ]; then
      echo "::warning title=Regression test differs::${name} differs from its .save"
    else
      echo "FAIL ${name} (differs from its .save)"
      status=1
    fi
  done
done
exit "$status"
