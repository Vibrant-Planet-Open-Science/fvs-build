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
#   5. jupyter-server-proxy serves the app at the /fvs-gui/ subpath, under a
#      base_url prefix like the one JupyterHub assigns (proxy config +
#      SHINY_PORT online mode + prefix handling).
#   6. jupyterhub-singleuser exists. BinderHub never runs `jupyter lab` or
#      `jupyter notebook` -- JupyterHub spawns jupyterhub-singleuser. Check 5
#      passes without it, so nothing else here catches its absence; when it is
#      missing the single-user server never starts and every /user/<id>/ path
#      404s on Binder while the image looks perfectly healthy locally.
#   7. the proxy registration still applies with /etc/jupyter masked, and the
#      launcher icon is served. mybinder mounts a Kubernetes ConfigMap there,
#      replacing the whole directory from the image; a registration that lives
#      in a config file under /etc/jupyter vanishes on Binder and /fvs-gui/ 404s
#      while checks 1-6 all still pass.
#   8. the jupyter_serverproxy_servers entry point is registered and loads.
#      jupyter-server-proxy warn()s and skips an entry point that raises, so a
#      broken one is a SILENT 404 -- no startup error, no failed check anywhere
#      else. This is the cheap static guard for that path.
#   9. launch.R's supervise loop relaunches the app after stopApp(). fvsOL calls
#      stopApp() from onSessionEnded on EVERY ordinary session end (closed tab,
#      reload, uncaught observer error), which makes runApp() return; and
#      jupyter-server-proxy never respawns a process that exits cleanly. Without
#      the loop, closing the tab bricks the session until the Jupyter server
#      itself restarts.
#
# Usage: tools/ci/smoke_fvs_gui.sh [IMAGE_REF]     (default: usfs-fvs-gui:local)
# Env:   SMOKE_VARIANT=<code>  override the variant used in check 2 (default:
#                              auto-detected from /opt/fvs/FVSbin).
set -euo pipefail

IMAGE="${1:-usfs-fvs-gui:local}"
APP_PORT="${SMOKE_APP_PORT:-3838}"
JUP_PORT="${SMOKE_JUP_PORT:-8888}"
MASK_PORT="${SMOKE_MASK_PORT:-8890}"
SUP_PORT="${SMOKE_SUP_PORT:-8891}"

CIDS=()
TMPFILES=()
TMPDIRS=()
cleanup() {
  local c f d
  for c in "${CIDS[@]:-}"; do [ -n "$c" ] && docker rm -f "$c" >/dev/null 2>&1 || true; done
  for f in "${TMPFILES[@]:-}"; do [ -n "$f" ] && rm -f "$f" || true; done
  for d in "${TMPDIRS[@]:-}"; do [ -n "$d" ] && rmdir "$d" 2>/dev/null || true; done
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
# Served under a base_url prefix, because that is what JupyterHub does: it
# assigns /user/<id>/ and the proxy must build asset URLs relative to it. A bare
# / prefix would not exercise that.
BASE_URL="/user/smoke/"
info "5. jupyter-server-proxy serves ${BASE_URL}fvs-gui/"
cid=$(docker run -d -p "${JUP_PORT}:${JUP_PORT}" "$IMAGE" \
  jupyter lab --ip=0.0.0.0 --no-browser --ServerApp.token='' --ServerApp.password='' \
  --ServerApp.base_url="${BASE_URL}")
CIDS+=("$cid")
if ! wait_http "http://localhost:${JUP_PORT}${BASE_URL}api" 90; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "jupyter server did not come up"
fi
# First hit launches the proxied app; the proxy waits up to its own timeout.
html=$(mktemp); TMPFILES+=("$html")
code=$(curl -s -o "$html" -w '%{http_code}' -L --max-time 150 "http://localhost:${JUP_PORT}${BASE_URL}fvs-gui/")
if [ "$code" != "200" ]; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "${BASE_URL}fvs-gui/ returned HTTP ${code} (expected 200)"
fi
grep -qi 'shiny' "$html" || { head -c 800 "$html" >&2; die "${BASE_URL}fvs-gui/ response is not a Shiny page"; }
docker rm -f "$cid" >/dev/null; CIDS=()
pass "jupyter-server-proxy serves fvsOL at ${BASE_URL}fvs-gui/"

# --- 6. Binder entrypoint present -------------------------------------------
# Checks 4 and 5 both start the server themselves, so neither notices that the
# binary BinderHub actually spawns is missing. Without this the image passes
# every other check and still 404s on every Binder path.
info "6. jupyterhub-singleuser on PATH (the binary BinderHub spawns)"
docker run --rm "$IMAGE" sh -c 'command -v jupyterhub-singleuser >/dev/null && echo hub-ok' \
  | grep -q '^hub-ok$' \
  || die "jupyterhub-singleuser not found: BinderHub cannot start this image (install the jupyterhub pip package)"
pass "jupyterhub-singleuser present"

# --- 7. proxy registration survives a masked /etc/jupyter --------------------
# mybinder.org mounts a Kubernetes ConfigMap at /etc/jupyter, which replaces the
# whole directory from the image. Mounting an empty dir there reproduces that
# faithfully: if the "fvs-gui" server were registered by a config file under
# /etc/jupyter, ServerProxy would come up with no named servers and /fvs-gui/
# would 302 to the slash-less path and 404 -- exactly the Binder failure, while
# every other check here still passes.
info "7. ${BASE_URL}fvs-gui/ still served with /etc/jupyter masked (Binder ConfigMap)"
maskdir=$(mktemp -d); TMPDIRS+=("$maskdir")
cid=$(docker run -d -p "${MASK_PORT}:${MASK_PORT}" -v "${maskdir}:/etc/jupyter:ro" "$IMAGE" \
  jupyter lab --ip=0.0.0.0 --port="${MASK_PORT}" --no-browser \
  --ServerApp.token='' --ServerApp.password='' --ServerApp.base_url="${BASE_URL}")
CIDS+=("$cid")
if ! wait_http "http://localhost:${MASK_PORT}${BASE_URL}api" 90; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "jupyter server did not come up with /etc/jupyter masked"
fi
html=$(mktemp); TMPFILES+=("$html")
code=$(curl -s -o "$html" -w '%{http_code}' -L --max-time 150 "http://localhost:${MASK_PORT}${BASE_URL}fvs-gui/")
if [ "$code" != "200" ]; then
  echo "--- jupyter container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "with /etc/jupyter masked, ${BASE_URL}fvs-gui/ returned HTTP ${code} (expected 200): the fvs-gui route must be registered by the jupyter_serverproxy_servers entry point, which no mount can shadow"
fi
grep -qi 'shiny' "$html" || { head -c 800 "$html" >&2; die "masked-config response is not a Shiny page"; }

# The launcher tile and the route come from the same registration, so a served
# icon is direct evidence the entry point loaded -- and it catches a package
# that installed without its icons/ data files.
ctype=$(curl -s -o /dev/null -w '%{content_type}' --max-time 30 \
  "http://localhost:${MASK_PORT}${BASE_URL}server-proxy/icon/fvs-gui")
case "$ctype" in
  image/png*) ;;
  *) die "launcher icon: expected image/png from ${BASE_URL}server-proxy/icon/fvs-gui, got '${ctype}'" ;;
esac
docker rm -f "$cid" >/dev/null; CIDS=()
pass "proxy registration survives a masked /etc/jupyter, icon served"

# --- 8. entry point is registered and loads ----------------------------------
# get_entrypoint_server_processes() wraps entry_point.load() in a try/except that
# warn()s and continues, so a broken entry point produces a silent 404 rather
# than a startup failure. Construct ServerProcess exactly as it does, which also
# validates the returned traits.
info "8. jupyter_serverproxy_servers entry point registered and loadable"
docker run --rm "$IMAGE" python -c 'import os; \
from importlib.metadata import entry_points; \
from jupyter_server_proxy.config import ServerProcess; \
eps = {e.name: e for e in entry_points(group="jupyter_serverproxy_servers")}; \
assert "fvs-gui" in eps, "fvs-gui entry point is not registered"; \
sp = ServerProcess(name="fvs-gui", **eps["fvs-gui"].load()()); \
assert sp.command[0] == "Rscript", sp.command; \
assert os.path.exists(sp.command[1]), "launch shim missing: " + sp.command[1]; \
assert sp.timeout >= 60, sp.timeout; \
assert sp.absolute_url is False, "absolute_url must stay False"; \
assert sp.environment.get("SHINY_PORT"), "SHINY_PORT must be non-empty"; \
assert os.path.exists(sp.launcher_entry.icon_path), "launcher icon missing"; \
print("entrypoint-ok")' | grep -q '^entrypoint-ok$' \
  || die "fvs-gui entry point missing or invalid: jupyter-server-proxy would warn() and skip it, leaving a silent 404 on ${BASE_URL}fvs-gui/"
pass "fvs-gui entry point registered and valid"

# --- 9. supervise loop relaunches the app after stopApp() --------------------
# fvsOL's session$onSessionEnded calls stopApp() on every ordinary session end,
# which makes runApp() return; jupyter-server-proxy then never respawns it
# (ensure_process only clears state["proc"] on a failed START), so the app is
# gone until the Jupyter server restarts. launch.R wraps runApp in a supervise
# loop to survive that.
#
# Driving this through a real Shiny session would mean hand-rolling a websocket
# client against Shiny's wire protocol -- fragile, and it would break on any
# Shiny upgrade. Instead a wrapper schedules a `later` callback on the very
# event loop runApp services, which calls stopApp() when a sentinel file
# appears. That exercises the exact code path (runApp returns -> loop relaunches)
# with no timing race: the sentinel is only created once the app is confirmed
# serving. The callback does not reschedule itself after firing, so exactly one
# restart happens.
info "9. launch.R relaunches fvsOL after stopApp() (closed tab / observer error)"
wrap=$(mktemp); TMPFILES+=("$wrap"); chmod 644 "$wrap"
cat > "$wrap" <<'RWRAP'
watch <- function() {
  if (file.exists("/tmp/fvs-stop")) {
    shiny::stopApp()
    return(invisible(NULL))
  }
  later::later(watch, 1)
}
later::later(watch, 1)
source("/opt/fvs/launch.R")
RWRAP
cid=$(docker run -d -p "${SUP_PORT}:${SUP_PORT}" -v "${wrap}:/tmp/wrap.R:ro" "$IMAGE" \
  Rscript /tmp/wrap.R "${SUP_PORT}")
CIDS+=("$cid")
if ! wait_http "http://localhost:${SUP_PORT}/" 180; then
  echo "--- app container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "app did not serve before the supervise-loop test could start"
fi
docker exec "$cid" touch /tmp/fvs-stop
deadline=$((SECONDS + 120))
until docker logs "$cid" 2>&1 | grep -q 'relaunching on port'; do
  if [ "$SECONDS" -ge "$deadline" ]; then
    echo "--- app container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
    die "launch.R did not relaunch fvsOL after stopApp(): a closed tab would brick the Binder session"
  fi
  sleep 2
done
if ! wait_http "http://localhost:${SUP_PORT}/" 180; then
  echo "--- app container logs (tail) ---" >&2; docker logs "$cid" 2>&1 | tail -40 >&2
  die "fvsOL relaunched but never served again after stopApp()"
fi
docker rm -f "$cid" >/dev/null; CIDS=()
pass "supervise loop relaunches fvsOL after stopApp()"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m (%s)\n' "$IMAGE"
