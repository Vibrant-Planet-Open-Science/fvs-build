#!/usr/bin/env bash
# Verify the native build's artifacts before they are bundled: every executable
# and shared library needs only what an end user's system provides, and all come
# from one GCC of major GCC_MAJOR (check_gcc_major.sh).
# Usage: VARIANTS="pn wc" GCC_MAJOR=14 verify_native.sh
# BUILD_DIR defaults to _build. macOS also needs MACOSX_DEPLOYMENT_TARGET.
set -euo pipefail

VARIANTS="${VARIANTS:?VARIANTS is required}"
BUILD_DIR="${BUILD_DIR:-_build}"
status=0
fail() {
  echo "ERROR: $*" >&2
  status=1
}

# Linux: the .so links libgfortran.so.5 dynamically (libgfortran.a is not PIC).
# ELF NEEDED records sonames, never absolute paths, so unlike macOS the leak to
# guard against is an RPATH/RUNPATH. aarch64 binaries record the glibc loader as
# NEEDED. Nothing may need a GLIBC_ symbol newer than the manylinux_2_28 floor.
verify_linux() {
  local f="$1" glibc='libc\.so\.6|libm\.so\.6|ld-linux-aarch64\.so\.1' allowed extra glibc_max floor=2.28
  case "$f" in
    *.so) allowed="^(${glibc}|libgfortran\.so\.5|libgcc_s\.so\.1)$" ;;
    *) allowed="^(${glibc})$" ;;
  esac
  echo "----- readelf -d $f -----"
  readelf -d "$f" | grep -E 'NEEDED|RPATH|RUNPATH' || true
  if readelf -d "$f" | grep -qE '\((RPATH|RUNPATH)\)'; then
    fail "$f has a baked-in RPATH/RUNPATH"
  fi
  extra="$(readelf -d "$f" | sed -n 's/.*(NEEDED).*\[\(.*\)\]/\1/p' | grep -Ev "$allowed" || true)"
  if [ -n "$extra" ]; then
    fail "$f needs libraries outside the allowlist: ${extra//$'\n'/ }"
  fi
  glibc_max="$(objdump -T "$f" | grep -oE 'GLIBC_[0-9.]+' | sed 's/GLIBC_//' | sort -V | tail -n 1)"
  echo "highest GLIBC_ symbol version: ${glibc_max}"
  if [ "$(printf '%s\n%s\n' "$glibc_max" "$floor" | sort -V | tail -n 1)" != "$floor" ]; then
    fail "$f needs GLIBC_${glibc_max}, newer than the GLIBC_${floor} floor"
  fi
}

# macOS: a leaked Homebrew GCC runtime path or unresolved @rpath entry is absent
# on end-user Macs and fails at dlopen; with the static GCC runtime only /usr/lib
# and /System deps should remain. The library's own install-id is skipped,
# matched by basename so an @rpath/-prefixed id is handled too.
verify_macos() {
  local f="$1" base leaks minos
  base="$(basename "$f")"
  echo "----- otool -L $f -----"
  otool -L "$f"
  leaks="$(otool -L "$f" | tail -n +2 | awk '{print $1}' \
    | awk -v b="$base" '{ n=$0; sub(/.*\//,"",n); if (n != b) print }' \
    | grep -Ev '^(/usr/lib/|/System/)' || true)"
  if [ -n "$leaks" ]; then
    fail "$f has non-system runtime dependencies: ${leaks//$'\n'/ }"
  fi
  minos="$(otool -l "$f" | awk '/LC_BUILD_VERSION/ {b=1} b && $1 == "minos" {print $2; exit}')"
  echo "minos: ${minos}"
  if [ "$minos" != "$MACOSX_DEPLOYMENT_TARGET" ]; then
    fail "$f targets macOS ${minos}, expected ${MACOSX_DEPLOYMENT_TARGET}"
  fi
}

# Windows: denylist the MinGW runtime DLLs rather than allowlist the (large,
# unstable) Windows system set. msvcrt.dll means a MINGW64 object slipped into
# this UCRT64 build. The executable must not import its own variant's DLL.
verify_windows() {
  local f="$1" deny='libgfortran|libgcc_s|libquadmath|libwinpthread|libstdc\+\+|libssp|msvcrt\.dll'
  case "$f" in
    *.exe) deny="$(basename "${f%.exe}")\.dll|${deny}" ;;
  esac
  echo "----- objdump -p $f (DLL imports) -----"
  objdump -p "$f" | grep 'DLL Name:' || true
  if objdump -p "$f" | grep 'DLL Name:' | grep -qiE "$deny"; then
    fail "$f imports a runtime/embedder DLL it must not"
  fi
}

case "$(uname -s)" in
  Linux) os=linux exe='' lib='.so' ;;
  Darwin) os=macos exe='' lib='.so' ;;
  MINGW* | MSYS*) os=windows exe='.exe' lib='.dll' ;;
  *)
    echo "ERROR: unsupported platform $(uname -s)" >&2
    exit 1
    ;;
esac

files=()
for v in $VARIANTS; do files+=("${BUILD_DIR}/FVS${v}${exe}" "${BUILD_DIR}/FVS${v}${lib}"); done
for f in "${files[@]}"; do
  [ -f "$f" ] || {
    echo "ERROR: $f not found" >&2
    exit 1
  }
  case "$os" in
    linux) verify_linux "$f" ;;
    macos) verify_macos "$f" ;;
    windows) verify_windows "$f" ;;
  esac
done

bash "$(dirname "$0")/check_gcc_major.sh" "${files[@]}" || status=1
exit $status
