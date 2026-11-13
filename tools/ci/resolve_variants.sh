#!/usr/bin/env bash
# Normalize VARIANTS_CSV (the workflows' comma-separated `variants` input):
# drop blanks and duplicates (first occurrence wins). Empty means the 22 US
# variants that build cleanly (bc and on: see README.md).
# Writes space-separated VARIANTS to $GITHUB_ENV and a dash-joined `id` (for
# cache keys, which cannot contain commas) to $GITHUB_OUTPUT.
set -euo pipefail
csv="${VARIANTS_CSV:-ak,bm,ca,ci,cr,cs,ec,em,ie,kt,ls,nc,ne,oc,op,pn,sn,so,tt,ut,wc,ws}"
v="$(printf '%s\n' "$csv" | tr ',' '\n' | tr -d ' \t\r' | awk 'NF && !seen[$0]++' | paste -sd ' ' -)"
if [ -z "$v" ]; then echo "ERROR: variants input expanded to an empty list" >&2; exit 1; fi
echo "Variants: $v"
echo "VARIANTS=$v" >> "$GITHUB_ENV"
echo "id=${v// /-}" >> "$GITHUB_OUTPUT"
