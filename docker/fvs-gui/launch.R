#!/usr/bin/env Rscript
# Launch shim for fvsOL behind jupyter-server-proxy: `Rscript launch.R {port}`.
# See docs/fvs-gui-container.md for Local mode, the fs attachment and the loop.
#
# fvsOL is attached with library() rather than called as fvsOL::fvsOL: its app
# code calls its Depends (shiny, Cairo, ...) unqualified, and `::` does not
# attach Depends, which leaves addResourcePath unfound.
#
# Supervise loop: fvsOL's onSessionEnded calls stopApp() on every ordinary
# session end, which makes runApp() return, and jupyter-server-proxy never
# respawns a process that exits cleanly (upstream handlers.py: "FIXME: Handle
# graceful exits of spawned processes here"). So runApp() is relaunched on the
# same port; the fast-exit guard fails loudly instead of spinning.

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

# fs: getVolumes2() calls fs::dir_exists/dir_ls unqualified, and fvsOL does not
# declare fs.
suppressPackageStartupMessages({
  library(fs)
  library(fvsOL)
})

fast_restarts <- 0

repeat {
  started <- Sys.time()

  # Rebuilt every iteration on purpose: the previous run's onSessionEnded has
  # already disconnected its SQLite handles and cleaned up ./www, so the old
  # app object must not be reused.
  app <- fvsOL(
    prjDir = Sys.getenv("FVSOL_PRJDIR", "/home/jovyan/project"),
    fvsBin = Sys.getenv("FVS_BIN", "/usr/local/lib")
  )

  # Explicit host/port/launch.browser override the app object's appOptions.
  # try() so an app error is retried under the same guard like any other exit.
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
