#!/usr/bin/env Rscript
# Launch shim for FVSOnLocal (fvsOL) behind jupyter-server-proxy.
#
# Invoked by jupyter-server-proxy as `Rscript /opt/fvs/launch.R {port}` (see
# /etc/jupyter/jupyter_server_config.py). fvsOL()'s app code calls shiny
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

port <- as.integer(commandArgs(trailingOnly = TRUE)[1])
if (is.na(port)) {
  stop("launch.R: missing or non-integer port argument")
}

# fvsOL hardcodes launch.browser=TRUE; there is no browser in the container,
# so make the "open a browser" callback a no-op rather than let it error.
options(browser = function(url) invisible(NULL))
options(shiny.port = port, shiny.host = "0.0.0.0")

# Attach fvsOL (and, via its Depends, shiny/Cairo/... which the app calls
# unqualified). Startup messages go to stderr; keep them quiet.
suppressPackageStartupMessages(library(fvsOL))

app <- fvsOL(
  prjDir = Sys.getenv("FVSOL_PRJDIR", "/home/jovyan/project"),
  fvsBin = Sys.getenv("FVSOL_BIN", "/opt/fvs/FVSbin")
)

# Explicit host/port/launch.browser here win over the app object's appOptions.
shiny::runApp(app, host = "0.0.0.0", port = port, launch.browser = FALSE)
