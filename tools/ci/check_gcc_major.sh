#!/usr/bin/env bash
# Fail unless every given artifact was compiled by exactly one GCC version whose
# major is GCC_MAJOR. Objects from a second GCC (e.g. a stale cache, or MSYS2
# runtime packages from a newer toolchain) show up as a second "GCC: (...) X.Y.Z"
# string; see USDAForestService/ForestVegetationSimulator#71.
#
# Usage: GCC_MAJOR=15 check_gcc_major.sh FILE...
# Mach-O artifacts may carry no GCC ident strings; then the version of $FC
# (default gfortran), the compiler that built them, is checked instead.
set -euo pipefail

: "${GCC_MAJOR:?GCC_MAJOR must be set}"
status=0
for f in "$@"; do
  test -f "$f"
  versions="$(strings "$f" | grep -oE 'GCC: \([^)]*\) [0-9]+(\.[0-9]+)*' | sed 's/.* //' | sort -u || true)"
  if [ -z "$versions" ]; then
    versions="$("${FC:-gfortran}" -dumpfullversion)"
    echo "$f: no GCC ident strings; checking ${FC:-gfortran} ${versions}"
  fi
  echo "$f: GCC ${versions//$'\n'/, }"
  if [ "$(printf '%s\n' "$versions" | wc -l)" -ne 1 ]; then
    echo "ERROR: $f mixes objects from more than one GCC version" >&2
    status=1
  elif [ "${versions%%.*}" != "$GCC_MAJOR" ]; then
    echo "ERROR: $f was built by GCC ${versions}, expected major ${GCC_MAJOR}" >&2
    status=1
  fi
done
exit $status
