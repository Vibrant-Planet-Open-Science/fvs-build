#!/usr/bin/env bash
# Fail unless every artifact was compiled by exactly one GCC version of major
# GCC_MAJOR. A second GCC (stale cache, newer MSYS2 runtime packages) shows up as
# a second "GCC: (...) X.Y.Z" ident; see USDAForestService/ForestVegetationSimulator#71.
# Usage: GCC_MAJOR=15 check_gcc_major.sh FILE...
# Mach-O artifacts may carry no idents; then $FC's version is checked instead.
# On Linux, glibc's startup objects (crt1.o, Scrt1.o, libc_nonshared.a) carry the
# ident of the compiler that built glibc (GCC 8.5 in manylinux_2_28), so those
# versions are ignored. Not on Windows, where the CRT is exactly what #71 is about.
set -euo pipefail

: "${GCC_MAJOR:?GCC_MAJOR must be set}"
idents() { strings -a "$@" | grep -oE 'GCC: \([^)]*\) [0-9]+(\.[0-9]+)*' | sed 's/.* //' | sort -u || true; }

libc_versions=""
if [ "$(uname -s)" = Linux ]; then
  for o in crt1.o Scrt1.o libc_nonshared.a; do
    p="$("${CC:-gcc}" -print-file-name="$o")"
    if [ -f "$p" ]; then libc_versions+="$(idents "$p")"$'\n'; fi
  done
fi

status=0
for f in "$@"; do
  test -f "$f"
  versions="$(idents "$f" | grep -vxF -f <(printf '%s' "$libc_versions") || true)"
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
