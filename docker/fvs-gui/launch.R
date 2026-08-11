#!/usr/bin/env Rscript
# Launch shim for FVSOnLocal (fvsOL) behind jupyter-server-proxy.
#
# Invoked by jupyter-server-proxy as `Rscript /opt/fvs/launch.R {port}` (see
# docker/fvs-gui/jupyter-fvsol-proxy, the entry-point package that registers the
# "fvs-gui" server). fvsOL()'s app code calls shiny
# functions (addResourcePath, ...) unqualified, relying on its Depends
# packages (shiny, Cairo, ...) being ATTACHED. So this shim ATTACHES fvsOL with
# library() rather than reaching in with fvsOL::fvsOL -- `::` loads the
# namespace but does not attach Depends, which leaves addResourcePath unfound.
#
# fvsOL() returns a shiny.appobj built with launch.browser=TRUE and no
# host/port -- it does NOT call runApp itself (fvsOL/R/server.R). So this shim:
#   1. neutralizes the hardcoded launch.browser=TRUE (no browser in a container),
#   2. pins host 0.0.0.0 and the proxy-assigned port, and
#   3. calls shiny::runApp() with explicit host/port/launch.browser, which
#      override whatever appOptions the returned app object carried.
#
# SHINY_PORT is set to a non-empty value in the proxy config so fvsOL runs in
# "Online" mode (isLocal() == FALSE, server.R:113): behind the proxy subpath
# that is the mode whose SVS tree-diagram PNGs use proxy-relative URLs and
# render correctly. See the Binder section of the README for the Online-mode UX
# trade-off.
#
# The runApp() call is wrapped in a SUPERVISE LOOP. fvsOL is written for the
# desktop case where quitting the browser should quit R: its
# session$onSessionEnded handler (server.R:384) calls stopApp() whenever
# globals$reloadAppIsSet == 0, which is every ordinary session end -- a closed
# tab, a reload, or an uncaught error in an observer. stopApp() makes runApp()
# RETURN, so without this loop the R process exits and the app is gone.
#
# That is unrecoverable behind jupyter-server-proxy: its ensure_process() only
# clears state["proc"] when a process fails to START, so a process that exits
# cleanly later is never respawned and every subsequent request 500s with
# ConnectionRefused until the whole Jupyter server restarts. On Binder that
# means closing the tab bricks the session. Upstream flags this themselves --
# handlers.py carries a "FIXME: Handle graceful exits of spawned processes
# here" right above that block.
#
# So: relaunch on the same proxy-assigned port whenever runApp() returns. The
# fast-exit guard keeps a genuinely broken app (bad prjDir, missing .so) from
# spinning hot forever -- it fails loudly instead, which is what the proxy
# should surface.
#
# This is a workaround, not a fix: the loop makes a session end recoverable, it
# does not stop fvsOL from ending the process.

port <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(port)) {
  stop("launch.R: missing or non-integer port argument")
}

# An app that dies in under this many seconds is failing, not being closed.
fast_exit_seconds <- 5
max_fast_restarts <- 3

# fvsOL hardcodes launch.browser=TRUE; there is no browser in the container,
# so make the "open a browser" callback a no-op rather than let it error.
options(browser = function(url) invisible(NULL))
options(shiny.port = port, shiny.host = "0.0.0.0")

# Attach fvsOL (and, via its Depends, shiny/Cairo/... which the app calls
# unqualified). Startup messages go to stderr; keep them quiet.
suppressPackageStartupMessages(library(fvsOL))

fast_restarts <- 0

repeat {
  started <- Sys.time()

  # Rebuilt every iteration on purpose: the previous run's onSessionEnded has
  # already disconnected its SQLite handles and cleaned up ./www, so the old
  # app object must not be reused.
  app <- fvsOL(
    prjDir = Sys.getenv("FVSOL_PRJDIR", "/home/jovyan/project"),
    fvsBin = Sys.getenv("FVSOL_BIN", "/opt/fvs/FVSbin")
  )

  # Explicit host/port/launch.browser here win over the app object's appOptions.
  # try() so an error inside the app is treated like any other exit and retried
  # under the same guard, rather than killing the process outright.
  try(shiny::runApp(app, host = "0.0.0.0", port = port, launch.browser = FALSE))

  elapsed <- as.numeric(difftime(Sys.time(), started, units = "secs"))
  if (elapsed < fast_exit_seconds) {
    fast_restarts <- fast_restarts + 1
    if (fast_restarts >= max_fast_restarts) {
      stop(sprintf(
        paste("launch.R: fvsOL exited after %.1fs on %d consecutive attempts;",
              "not restarting again. The app is failing to start, not being",
              "closed -- check the log above for the underlying R error."),
        elapsed, fast_restarts
      ))
    }
  } else {
    fast_restarts <- 0
  }

  message(sprintf(
    "launch.R: fvsOL exited after %.0fs (stopApp on session end); relaunching on port %d",
    elapsed, port
  ))
}
