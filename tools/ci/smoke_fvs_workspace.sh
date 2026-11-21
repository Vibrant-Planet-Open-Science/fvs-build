#!/usr/bin/env bash
# Smoke test for the FVS workspace image (docker/Dockerfile.fvs-workspace), run against an
# already-built image. The checks are described in docs/fvs-workspace-container.md.
#
# Usage: tools/ci/smoke_fvs_workspace.sh [IMAGE_REF]     (default: fvs-workspace:local)
# Env:   SMOKE_VARIANT=<code>  override the auto-detected variant used by checks 2, 12 and 13.
set -euo pipefail

IMAGE="${1:-fvs-workspace:local}"
# Host ports, one per check that serves, so a slow container teardown can't clash.
APP_PORT=3838 JUP_PORT=8888 MASK_PORT=8890 SUP_PORT=8891 DEFAULT_PORT=8892

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

# Fail with the container's log tail, which is where a server that never came up
# says why.
die_logs() {
  echo "--- container logs (tail) ---" >&2
  docker logs "$1" 2>&1 | tail -40 >&2
  die "$2"
}

# wait_or_die CID URL TIMEOUT MESSAGE: poll URL until it answers. Connection
# resets while the app starts are expected noise, so curl's errors are muted.
wait_or_die() {
  local waited=0
  until curl -fs -o /dev/null --max-time 5 "$2" 2>/dev/null; do
    [ "$waited" -lt "$3" ] || die_logs "$1" "$4"
    sleep 3
    waited=$((waited + 3))
  done
}

# expect_shiny CID URL MESSAGE: URL must return 200 and a Shiny page. A first
# hit through the proxy launches the app, so allow the proxy's own timeout.
expect_shiny() {
  local html code
  html=$(mktemp)
  TMPFILES+=("$html")
  code=$(curl -s -o "$html" -w '%{http_code}' -L --max-time 150 "$2")
  [ "$code" = 200 ] || die_logs "$1" "$3 (HTTP ${code}, expected 200)"
  grep -qi 'shiny' "$html" || {
    head -c 800 "$html" >&2
    die "$3 (response is not a Shiny page)"
  }
}

info "FVS workspace image smoke test: ${IMAGE}"
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
    'ls /usr/local/lib/FVS*.so 2>/dev/null | head -1 | sed "s#.*/FVS##; s#\.so\$##"')
fi
[ -n "$VARIANT" ] || die "no FVS<v>.so found under /usr/local/lib"
docker run --rm -e VARIANT="$VARIANT" "$IMAGE" Rscript -e \
  'suppressPackageStartupMessages(library(rFVS)); rFVS::fvsLoad(fvsProgram=paste0("FVS",Sys.getenv("VARIANT")), bin=Sys.getenv("FVS_BIN")); cat("soload-ok\n")' \
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
wait_or_die "$cid" "http://localhost:${APP_PORT}/" 150 "launch.R app did not serve within timeout"
expect_shiny "$cid" "http://localhost:${APP_PORT}/" "launch.R app did not serve fvsOL"
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
wait_or_die "$cid" "http://localhost:${JUP_PORT}${BASE_URL}api" 90 "jupyter server did not come up"
expect_shiny "$cid" "http://localhost:${JUP_PORT}${BASE_URL}fvs-gui/" "${BASE_URL}fvs-gui/ did not serve fvsOL"
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
wait_or_die "$cid" "http://localhost:${MASK_PORT}${BASE_URL}api" 90 "jupyter server did not come up with /etc/jupyter masked"
expect_shiny "$cid" "http://localhost:${MASK_PORT}${BASE_URL}fvs-gui/" \
  "with /etc/jupyter masked, ${BASE_URL}fvs-gui/ did not serve fvsOL: the fvs-gui route must be registered by the jupyter_serverproxy_servers entry point, which no mount can shadow"

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
wait_or_die "$cid" "http://localhost:${SUP_PORT}/" 180 "app did not serve before the supervise-loop test could start"
docker exec "$cid" touch /tmp/fvs-stop
deadline=$((SECONDS + 120))
until docker logs "$cid" 2>&1 | grep -q 'relaunching on port'; do
  [ "$SECONDS" -lt "$deadline" ] \
    || die_logs "$cid" "launch.R did not relaunch fvsOL after stopApp(): a closed tab would brick the Binder session"
  sleep 2
done
wait_or_die "$cid" "http://localhost:${SUP_PORT}/" 180 "fvsOL relaunched but never served again after stopApp()"
docker rm -f "$cid" >/dev/null; CIDS=()
pass "supervise loop relaunches fvsOL after stopApp()"

# --- 10. the Interface release has the Local-mode fixes ----------------------
info "10. fvsOL sources include the Local-mode fixes from Interface 20261121"
docker run --rm "$IMAGE" sh -c \
  'cd /opt/fvs/interface/fvsOL/R && ! grep -rqE "\"/www/s|ProjectIsLocked|getVolumes2" .' \
  || die "this image was built from an interface_ref older than 20261121: View On Maps popup graphs will 404 under the /fvs-gui/ proxy subpath, leaving a project will strand a lock file that hides it from the project picker, and Change Working Directory will kill the session. Rebuild with interface_ref 20261121 or later"
pass "Local-mode fixes present in /opt/fvs/interface/fvsOL/R"

# --- 11. Manage Projects does not grey out ------------------------------------
# Reproduces a live session's on-disk state: the projectId.txt fvsOL writes at
# first start plus the lock file it holds for the life of the session.
info "11. Manage Projects project list survives a locked open project"
docker run --rm "$IMAGE" Rscript -e '
  suppressPackageStartupMessages(library(fvsOL))
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

# --- 12. FVS executable on PATH ----------------------------------------------
info "12. FVS${VARIANT} executable on PATH runs to STOP 20"
docker run --rm -w /tmp -e VARIANT="$VARIANT" "$IMAGE" sh -c \
  '"FVS$VARIANT" --version && { "FVS$VARIANT" </dev/null 2>&1 || true; }' \
  | grep -q 'STOP 20' || die "FVS${VARIANT} is missing from PATH or did not reach STOP 20 on empty input"
pass "FVS${VARIANT} runs from PATH"

# --- 13. fvs2py loads a variant from FVS_BIN ----------------------------------
info "13. fvs2py loads FVS${VARIANT}.so from \$FVS_BIN"
docker run --rm -e VARIANT="$VARIANT" "$IMAGE" python -c \
  'import os; from fvs2py import FVS; FVS(os.path.join(os.environ["FVS_BIN"], "FVS" + os.environ["VARIANT"] + ".so")); print("fvs2py-ok")' \
  2>&1 | grep -q '^fvs2py-ok$' || die "fvs2py could not load FVS${VARIANT}.so from \$FVS_BIN"
pass "fvs2py loads FVS${VARIANT}.so"

# --- 14. Jupyter R and Python kernels -----------------------------------------
info "14. Jupyter kernels: ir and python3"
kernels="$(docker run --rm "$IMAGE" jupyter kernelspec list 2>/dev/null)"
for k in ir python3; do
  printf '%s\n' "$kernels" | grep -qE "^ +${k} " || die "Jupyter kernel ${k} is not registered"
done
pass "ir and python3 kernels registered"

# --- 15. default command serves JupyterLab ------------------------------------
info "15. docker run with no command serves JupyterLab on 8888"
cid=$(docker run -d -p "${DEFAULT_PORT}:8888" "$IMAGE")
CIDS+=("$cid")
wait_or_die "$cid" "http://localhost:${DEFAULT_PORT}/api" 90 "the default command did not start JupyterLab on port 8888"
docker logs "$cid" 2>&1 | grep -q 'http://127.0.0.1:8888/lab?token=' \
  || die "JupyterLab did not print the http://127.0.0.1:8888/lab?token=... link the README tells users to open"
docker rm -f "$cid" >/dev/null; CIDS=()
pass "default command serves JupyterLab and prints the login link"

printf '\n\033[32mALL SMOKE TESTS PASSED\033[0m (%s)\n' "$IMAGE"
