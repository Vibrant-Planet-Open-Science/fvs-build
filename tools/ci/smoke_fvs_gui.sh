#!/usr/bin/env bash
# Smoke test for the FVS GUI image (docker/Dockerfile.fvs-gui), run against an
# already-built image. The checks are described in docs/fvs-gui-container.md.
#
# Usage: tools/ci/smoke_fvs_gui.sh [IMAGE_REF]     (default: usfs-fvs-gui:local)
# Env:   SMOKE_VARIANT=<code>  override the auto-detected variant used by the .so check.
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

# Poll until success or timeout (seconds). Connection resets while the app starts
# are expected noise, so errors are muted here; the real fetch keeps -S.
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
  # the call style fvsOL uses for its scratch tables; if RSQLite breaks it,
  # the GUI dies on stand selection while still booting cleanly
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
# Under a JupyterHub-style /user/<id>/ base_url so prefix handling is exercised.
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
info "6. jupyterhub-singleuser on PATH (the binary BinderHub spawns)"
docker run --rm "$IMAGE" sh -c 'command -v jupyterhub-singleuser >/dev/null && echo hub-ok' \
  | grep -q '^hub-ok$' \
  || die "jupyterhub-singleuser not found: BinderHub cannot start this image (install the jupyterhub pip package)"
pass "jupyterhub-singleuser present"

# --- 7. proxy registration survives a masked /etc/jupyter --------------------
# An empty dir over /etc/jupyter reproduces mybinder's ConfigMap mount.
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

# A served icon also catches a package installed without its icons/ data files.
ctype=$(curl -s -o /dev/null -w '%{content_type}' --max-time 30 \
  "http://localhost:${MASK_PORT}${BASE_URL}server-proxy/icon/fvs-gui")
case "$ctype" in
  image/png*) ;;
  *) die "launcher icon: expected image/png from ${BASE_URL}server-proxy/icon/fvs-gui, got '${ctype}'" ;;
esac
docker rm -f "$cid" >/dev/null; CIDS=()
pass "proxy registration survives a masked /etc/jupyter, icon served"

# --- 8. entry point is registered and loads ----------------------------------
# Construct ServerProcess the way jupyter-server-proxy does, which also
# validates the returned traits.
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
# Rather than drive a real Shiny session over its websocket protocol, a wrapper
# schedules a one-shot `later` callback on runApp's event loop that calls
# stopApp() once a sentinel file appears; the sentinel is created only after the
# app is serving, so there is no timing race.
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
# Evaluate only the installed launch.R's library()/require() calls, so the fs
# attachment must come from the shim rather than from this check.
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
# Reproduces a live session's on-disk state: the projectId.txt fvsOL writes at
# first start plus the lock file it holds for the life of the session.
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

# --- 13. FVS executable on PATH ----------------------------------------------
info "13. FVS${VARIANT} executable on PATH runs to STOP 20"
docker run --rm -w /tmp -e VARIANT="$VARIANT" "$IMAGE" sh -c \
  '"FVS$VARIANT" --version && { "FVS$VARIANT" </dev/null 2>&1 || true; }' \
  | grep -q 'STOP 20' || die "FVS${VARIANT} is missing from PATH or did not reach STOP 20 on empty input"
pass "FVS${VARIANT} runs from PATH"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m (%s)\n' "$IMAGE"
