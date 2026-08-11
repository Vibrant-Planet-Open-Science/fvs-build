#!/usr/bin/env bash
# Smoke test for the FVSOnLocal (fvsOL) GUI image (docker/Dockerfile.fvs-gui).
#
# Runs against an ALREADY-BUILT image (local `docker buildx --load` result or a
# pulled ref); it does NOT build the image. The same script is used two ways:
#   * locally, before committing/pushing:  tools/ci/smoke_fvs_gui.sh usfs-fvs-gui:local
#   * in CI (build-container-fvs-gui-linux.yml), against the freshly-built image
#     before the GHCR push, so a broken image is never published.
#
# Checks (see docs/workflow-interface.md "Smoke test"):
#   1. fvsOL + rFVS attach (catches Depends-not-attached, e.g. addResourcePath).
#   2. an FVS<v>.so loads via rFVS::fvsLoad with its expected C API symbols
#      (catches a copied .so that is not runnable in-image: glibc/libgfortran).
#   3. the temp-table write pattern fvsOL depends on still works against the
#      installed RSQLite + the default input DB opens. This is a FORWARD canary:
#      r2u installs RSQLite unpinned, and RSQLite once already broke the call
#      style fvsOL used (DBI::SQL("temp.X") -> "Named parameters not used in
#      query", fixed upstream by PR #29). If a future release breaks the
#      temporary=TRUE style too, fvsOL greys out on stand selection -- a path
#      checks 4 and 5 do NOT reach, since the app boots and serves fine either
#      way. Sources predating PR #29 are a separate concern, caught at build
#      time by Dockerfile.fvs-gui's guard, not here.
#   4. the app boots headless via launch.R and serves an HTTP 200 Shiny page.
#   5. jupyter-server-proxy serves the app at the /fvs-gui/ subpath (the Binder
#      entrypoint end-to-end: proxy config + SHINY_PORT online mode).
#
# Usage: tools/ci/smoke_fvs_gui.sh [IMAGE_REF]     (default: usfs-fvs-gui:local)
# Env:   SMOKE_VARIANT=<code>  override the variant used in check 2 (default:
#                              auto-detected from /opt/fvs/FVSbin).
set -euo pipefail

IMAGE="${1:-usfs-fvs-gui:local}"
APP_PORT="${SMOKE_APP_PORT:-3838}"
JUP_PORT="${SMOKE_JUP_PORT:-8888}"

CIDS=()
TMPFILES=()
cleanup() {
  local c f
  for c in "${CIDS[@]:-}"; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true; done
  for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f" || true; done
}
trap cleanup EXIT

info() { printf '\n== %s\n' "$1"; }
pass() { printf '   \033[32mPASS\033[0m %s\n' "$1"; }
die()  { printf '   \033[31mFAIL\033[0m %s\n' "$1" >&2; exit 1; }

# Poll an URL until it returns success or the timeout (seconds) elapses. While
# the app is still starting, docker-proxy accepts the connection but the app
# isn't listening yet, so attempts fail with "Recv failure: Connection reset by
# peer" (or "Connection refused"). That's expected poll noise -- suppress it
# here (no -S, stderr muted); the real fetch after the wait keeps -S for
# diagnostics.
wait_http() {
  local url="$1" timeout="${2:-120}" waited=0
  while [ "$waited" -lt "$timeout" ]; do
    if curl -fs -o /dev/null --max-time 5 "$url" 2>/dev/null; then return 0; fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

info "FVS GUI image smoke test: ${IMAGE}"
docker image inspect "$IMAGE" >/dev/null 2>&1 || die "image not found locally: ${IMAGE} (build it first, e.g. docker buildx build --load -t ${IMAGE} ...)"

# --- 1. R packages attach ---------------------------------------------------
info "1. fvsOL + rFVS attach"
docker run --rm "$IMAGE" Rscript -e \
  'suppressPackageStartupMessages({library(fvsOL); library(rFVS)}); cat("attach-ok\n")' \
  | grep -q '^attach-ok$' || die "fvsOL/rFVS failed to attach"
pass "fvsOL + rFVS attach"

# --- 2. FVS .so loads via rFVS::fvsLoad -------------------------------------
info "2. FVS shared library loads (rFVS::fvsLoad)"
VARIANT="${SMOKE_VARIANT:-}"
if [ -z "$VARIANT" ]; then
  VARIANT=$(docker run --rm "$IMAGE" sh -c \
    'ls /opt/fvs/FVSbin/FVS*.so 2>/dev/null | head -1 | sed "s#.*/FVS##; s#\.so\$##"')
fi
[ -n "$VARIANT" ] || die "no FVS<v>.so found under /opt/fvs/FVSbin"
docker run --rm -e VARIANT="$VARIANT" "$IMAGE" Rscript -e \
  'suppressPackageStartupMessages(library(rFVS)); rFVS::fvsLoad(fvsProgram=paste0("FVS",Sys.getenv("VARIANT")), bin="/opt/fvs/FVSbin"); cat("soload-ok\n")' \
  | grep -q '^soload-ok$' || die "FVS${VARIANT}.so did not load with its expected API symbols"
pass "FVS${VARIANT}.so loads with expected API symbols"

# --- 3. RSQLite temp-table write + default DB opens -------------------------
info "3. RSQLite temp-table write pattern + default FVS_Data.db"
docker run --rm "$IMAGE" Rscript -e '
  suppressPackageStartupMessages({library(DBI); library(RSQLite)})
  con <- dbConnect(SQLite(), ":memory:")
  # the call style fvsOL uses for its scratch tables; if a future RSQLite
  # breaks this the way 3.53.1 broke the previous style, the GUI dies on
  # stand selection while still booting cleanly
  dbWriteTable(con, "Grps", data.frame(Stand_ID="", Grp=""), temporary=TRUE, overwrite=TRUE)
  stopifnot(dbExistsTable(con, "Grps"))
  db <- system.file("extdata", "FVS_Data.db.default", package="fvsOL")
  stopifnot(nzchar(db), file.exists(db))
  c2 <- dbConnect(SQLite(), db)
  stopifnot(length(dbListTables(c2)) > 0)
  cat("db-ok\n")' \
  | grep -q '^db-ok$' || die "temp-table write failed or default FVS_Data.db missing/empty"
pass "temp-table write works + default FVS_Data.db opens"

# --- 4. headless app boot ---------------------------------------------------
info "4. headless app boot (launch.R) -> HTTP 200 Shiny page"
cid=$(docker run -d -p "${APP_PORT}:${APP_PORT}" "$IMAGE" Rscript /opt/fvs/launch.R "${APP_PORT}")
CIDS+=("$cid")
if ! wait_http "http://localhost:${APP_PORT}/" 150; then
  echo "--- app container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "launch.R app did not serve within timeout"
fi
html=$(mktemp); TMPFILES+=("$html")
curl -fsS --max-time 15 "http://localhost:${APP_PORT}/" -o "$html"
grep -qi 'shiny' "$html" || { head -c 800 "$html" >&2; die "app response is not a Shiny page"; }
docker rm -f "$cid" >/dev/null; CIDS=()
pass "launch.R serves a Shiny page on :${APP_PORT}"

# --- 5. jupyter-server-proxy path -------------------------------------------
info "5. jupyter-server-proxy serves /fvs-gui/"
cid=$(docker run -d -p "${JUP_PORT}:${JUP_PORT}" "$IMAGE" \
  jupyter lab --ip=0.0.0.0 --no-browser --ServerApp.token='' --ServerApp.password='')
CIDS+=("$cid")
if ! wait_http "http://localhost:${JUP_PORT}/api" 90; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "jupyter server did not come up"
fi
# First hit launches the proxied app; the proxy waits up to its own timeout.
html=$(mktemp); TMPFILES+=("$html")
code=$(curl -s -o "$html" -w '%{http_code}' -L --max-time 150 "http://localhost:${JUP_PORT}/fvs-gui/")
if [ "$code" != "200" ]; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "/fvs-gui/ returned HTTP ${code} (expected 200)"
fi
grep -qi 'shiny' "$html" || { head -c 800 "$html" >&2; die "/fvs-gui/ response is not a Shiny page"; }
docker rm -f "$cid" >/dev/null; CIDS=()
pass "jupyter-server-proxy serves fvsOL at /fvs-gui/"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m (%s)\n' "$IMAGE"
