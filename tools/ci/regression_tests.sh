#!/usr/bin/env bash
# Run the FVS source's tests/FVS<v>/makefile against the built executables and
# compare every output with a .save beside it, ignoring run stamps (-999
# lines, the page header) and sqlite3 CLI quoting and type case. A missing
# output fails; a differing one fails under REGRESSION_TESTS=strict and is a
# warning under REGRESSION_TESTS=warn.
set -uo pipefail
shopt -s nullglob

VARIANTS="${VARIANTS:?VARIANTS is required}"
FVS_SOURCE="${FVS_SOURCE:-${GITHUB_WORKSPACE:?set FVS_SOURCE or GITHUB_WORKSPACE}/fvs-source}"
BUILD_DIR="${BUILD_DIR:-_build}"
REGRESSION_TESTS="${REGRESSION_TESTS:-strict}"
case "$REGRESSION_TESTS" in
  warn | strict) ;;
  *) echo "REGRESSION_TESTS must be warn or strict, not '${REGRESSION_TESTS}'" >&2; exit 2 ;;
esac

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
    elif changes="$(diff -U0 -w -i --strip-trailing-cr --label "${name}.save" --label "$name" \
      <(normalized "$golden") <(normalized "$output"))"; then
      echo "PASS ${name}"
    elif [ "$REGRESSION_TESTS" = warn ]; then
      title="${name} differs from its .save on ${RUNNER_OS:-$(uname -s)}"
      # shellcheck disable=SC2016 # literal markdown code fence
      [ -z "${GITHUB_STEP_SUMMARY:-}" ] \
        || printf '### %s\n\n```diff\n%s\n```\n\n' "$title" "$changes" >> "$GITHUB_STEP_SUMMARY"
      echo "::warning title=${title}::See the job summary"
    else
      echo "$changes"
      echo "FAIL ${name} (differs from its .save)"
      status=1
    fi
  done
done
exit "$status"
