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

want="$(mktemp)"
got="$(mktemp)"
trap 'rm -f "$want" "$got"' EXIT

status=0
for v in $VARIANTS; do
  for golden in "${FVS_SOURCE}/tests/FVS${v}/"*.save; do
    output="${golden%.save}"
    name="FVS${v}/$(basename "$output")"
    if [ ! -f "$output" ]; then
      echo "FAIL ${name} (not written)"
      status=1
    elif changes="$(diff -u -w -i --strip-trailing-cr --label "${name}.save" --label "$name" \
      <(normalized "$golden") <(normalized "$output"))"; then
      echo "PASS ${name}"
    elif [ "$DIFFS_WARN" = 1 ]; then
      title="${name} differs from its .save on ${RUNNER_OS:-$(uname -s)}"
      normalized "$golden" > "$want"
      normalized "$output" > "$got"
      # Marks the changed characters, e.g. 1897[-2-]{+1+}; sed drops the
      # header naming the temp files.
      changes="$(git diff --no-index -U0 -w --ignore-cr-at-eol --word-diff=plain --word-diff-regex='[^[:space:]]' \
        "$want" "$got" | sed 1,4d)"
      # shellcheck disable=SC2016 # literal markdown code fence
      [ -z "${GITHUB_STEP_SUMMARY:-}" ] \
        || printf '### %s\n\n```\n%s\n```\n\n' "$title" "$changes" >> "$GITHUB_STEP_SUMMARY"
      # Workflow commands take one line; GitHub decodes these escapes.
      changes="${changes//'%'/%25}"
      changes="${changes//$'\r'/%0D}"
      echo "::warning title=${title}::${changes//$'\n'/%0A}"
    else
      echo "$changes"
      echo "FAIL ${name} (differs from its .save)"
      status=1
    fi
  done
done
exit "$status"
