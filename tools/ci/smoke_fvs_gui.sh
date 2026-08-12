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
#      absolute_url=False prefix handling).
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
#   8. the jupyter_serverproxy_servers entry point is registered and loads, and
#      it does NOT set SHINY_PORT (which would flip fvsOL back to Online mode
#      and leave three Manage Projects controls inert). jupyter-server-proxy
#      warn()s and skips an entry point that raises, so a broken one is a SILENT
#      404 -- no startup error, no failed check anywhere else. This is the cheap
#      static guard for both.
#   9. launch.R's supervise loop relaunches the app after stopApp(). fvsOL calls
#      stopApp() from onSessionEnded on EVERY ordinary session end (closed tab,
#      reload, uncaught observer error), which makes runApp() return; and
#      jupyter-server-proxy never respawns a process that exits cleanly. Without
#      the loop, closing the tab bricks the session until the Jupyter server
#      itself restarts.
#  10. the patches (docker/fvs-gui/patches/) are present in the STAGED sources
#      baked into the image, so a published image can be audited after the fact
#      rather than only while it is being built.
#  11. Local mode reaches a working session: isLocal() is TRUE and
#      getVolumes2()() returns a non-empty volume list. getVolumes2() calls
#      fs::dir_exists unqualified and fvsOL does not declare fs, so without
#      launch.R attaching it the session dies at construction with `could not
#      find function "dir_exists"` -- and nothing else here reaches that: the
#      app boots and serves either way, and only a real browser session fails.
#  12. getProjectList() returns instead of erroring with the open project locked
#      -- i.e. the Manage Projects tab does not grey out on first click. Its
#      observer (server.R:8721) calls straight into getProjectList(), and checks
#      4, 5 and 7 all boot the app happily without reaching that path.
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
#
# SHINY_PORT must stay UNSET: fvsOL's isLocal() is Sys.getenv('SHINY_PORT')=="",
# so setting it flips the app to Online mode, where "Change Working Directory",
# "Upload project backup zip file" and "Open selected project" all render and do
# nothing (their server handlers are isLocal()-gated while the UI object's
# branches were frozen TRUE at package install). That regression is invisible to
# every other check -- the app boots and serves identically in both modes.
info "8. jupyter_serverproxy_servers entry point registered, loadable, Local mode"
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
assert not sp.environment.get("SHINY_PORT"), "SHINY_PORT must stay unset (Local mode)"; \
assert os.path.exists(sp.launcher_entry.icon_path), "launcher icon missing"; \
print("entrypoint-ok")' | grep -q '^entrypoint-ok$' \
  || die "fvs-gui entry point missing, invalid, or setting SHINY_PORT: an invalid entry point leaves a silent 404 on ${BASE_URL}fvs-gui/, and a set SHINY_PORT flips fvsOL to Online mode, where the working-directory chooser, backup upload and project switching all render but do nothing"
pass "fvs-gui entry point registered, valid, and Local mode (SHINY_PORT unset)"

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

# --- 10. the patches landed in the shipped sources -------------------
# Dockerfile.fvs-gui applies docker/fvs-gui/patches/ and asserts the result at
# BUILD time, which protects the build but says nothing about an image someone
# already pulled. Re-grep the source code baked into the image so a published
# ref can be audited on its own.
info "10. vendored fvsOL patches present in the image's staged sources"
docker run --rm "$IMAGE" sh -c '
  set -e
  test -d /opt/fvs/interface/fvsOL/R
  if grep -rq "\"/www/s" /opt/fvs/interface/fvsOL/R; then
    echo "found origin-absolute /www/ stand-image URL"; exit 1
  fi
  if grep -rq "ProjectIsLocked" /opt/fvs/interface/fvsOL/R; then
    echo "found mis-cased ProjectIsLocked.txt"; exit 1
  fi
  echo patched-ok' 2>&1 | grep -q '^patched-ok$' \
  || die "the vendored fvsOL patches are missing from this image: the View On Maps popup graphs will 404 under the /fvs-gui/ proxy subpath, and leaving a project will strand a lock file that hides it from the project picker. Rebuild from a Dockerfile.fvs-gui that applies docker/fvs-gui/patches/"
pass "vendored patches present in /opt/fvs/interface/fvsOL/R"

# --- 11. Local mode can construct a session ----------------------------------
# The image runs with SHINY_PORT unset, so isLocal() is TRUE and server.R:421
# calls getVolumes2()() while building the server function. getVolumes2()
# (change_project_dir.R) uses fs::dir_exists / fs::dir_ls UNQUALIFIED, and fvsOL
# neither Depends on nor Imports fs -- so unless something attaches fs, every
# session dies at construction with `could not find function "dir_exists"`.
# launch.R is what attaches it.
#
# So the attachment must come from launch.R, not from this check: parse the
# installed shim and evaluate only its library()/require() calls, then make the
# call a session would.
info "11. Local mode: isLocal() TRUE and getVolumes2() usable (fs attached by launch.R)"
docker run --rm "$IMAGE" Rscript -e '
  attaches <- Filter(function(e) is.call(e) && is.name(e[[1]]) &&
      as.character(e[[1]]) %in%
        c("library", "require", "suppressPackageStartupMessages"),
    as.list(parse("/opt/fvs/launch.R")))
  stopifnot(length(attaches) > 0)
  for (e in attaches) eval(e, globalenv())
  stopifnot(fvsOL:::isLocal())
  volumes <- c(fvsOL:::getVolumes2()())
  stopifnot(length(volumes) > 0, all(nzchar(volumes)))
  cat("local-ok", paste(volumes, collapse=","), "\n")' 2>&1 | grep -q '^local-ok ' \
  || die "Local mode cannot construct a session with only the packages launch.R attaches: isLocal() is FALSE, or getVolumes2() failed (it calls fs::dir_exists unqualified and fvsOL declares no fs dependency, so launch.R must attach fs). The app would still boot and serve, then grey out the instant a browser opens a session"
pass "Local mode constructs from launch.R's attachments: volume list non-empty"

# --- 12. Manage Projects does not grey out ------------------------------------
# The Manage Projects observer (server.R:8721) calls straight into
# getProjectList(), so an error there greys out the app on the tab's first click.
# This reproduces a live session's on-disk state exactly -- the projectId.txt
# fvsOL writes at first start plus the lock file it holds for the life of the
# session (server.R:224) -- and asserts the call returns.
info "12. Manage Projects project list survives a locked open project"
docker run --rm "$IMAGE" Rscript -e '
  suppressPackageStartupMessages({library(fs); library(fvsOL)})
  prjDir <- Sys.getenv("FVSOL_PRJDIR", "/home/jovyan/project")
  stopifnot(dir.exists(prjDir))
  setwd(prjDir)
  stopifnot(fvsOL:::isLocal())
  if (!file.exists("projectId.txt")) cat("title= ", basename(getwd()), "\n", file="projectId.txt")
  cat(file="projectIsLocked.txt", date(), "\n")
  on.exit(unlink("projectIsLocked.txt"), add=TRUE)
  rtn <- try(fvsOL:::getProjectList(), silent=TRUE)
  if (inherits(rtn, "try-error")) {
    cat("getProjectList() failed:", conditionMessage(attr(rtn, "condition")), "\n")
    quit(status=1)
  }
  cat("prjlist-ok\n")' 2>&1 | grep -q '^prjlist-ok$' \
  || die "getProjectList() errored with the open project locked: the Manage Projects tab will grey out on first click"
pass "project list resolves with the open project locked (Manage Projects usable)"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m (%s)\n' "$IMAGE"
