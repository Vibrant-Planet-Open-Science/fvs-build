"""jupyter-server-proxy registration for the FVSOnLocal (fvsOL) Shiny app.

Registers a named proxy entry "fvs-gui" so the Shiny app is reachable at the
`/fvs-gui/` subpath of the Jupyter server (the URL Binder opens via
`?urlpath=fvs-gui/`). jupyter-server-proxy allocates a free {port}, launches the
command, and reverse-proxies to it.

Registration happens through the `jupyter_serverproxy_servers` entry point
declared in pyproject.toml -- NOT through a `jupyter_server_config.py`. That is
deliberate: mybinder.org mounts a Kubernetes ConfigMap over /etc/jupyter, and a
directory mount replaces the whole directory from the image, so any config file
placed there is invisible on Binder while `docker run` still works perfectly.
Because the mount happens at runtime in Kubernetes, no image layer can win that
race. Entry points live in package metadata, which no mount can mask, and it is
how other teams adopt proxies (jupyter-rsession-proxy, jupyter-shiny-proxy) and
rocker-org/binder do for exactly this reason.

Note that jupyter-server-proxy swallows failures here -- a raising entry point is
reported with warn() and skipped, leaving a silent 404 rather than a startup
error. Dockerfile.fvs-gui asserts this module loads at build time so a mistake
breaks the build instead of the Binder launch.
"""

import os
from importlib.resources import files

# The R launch shim, baked in at a fixed path by Dockerfile.fvs-gui. Overridable
# so the app can be exercised from a checkout without rebuilding the image.
LAUNCHER = os.environ.get("FVSOL_LAUNCHER", "/opt/fvs/launch.R")


def setup_fvs_gui() -> dict[str, object]:
    """Build the jupyter-server-proxy server definition for fvsOL.

    Returns:
        Keyword arguments for ``jupyter_server_proxy.config.ServerProcess``.
        The server's name (and so its URL segment) comes from the entry point
        name, not from this dict.
    """
    launcher_entry: dict[str, object] = {"title": "FVS GUI", "enabled": True}

    # Rendered by the JupyterLab launcher as a plain <img>. Guarded by a
    # conditional so that app is not missing on startup page even if icon
    # isn't found at build time.
    icon = files("jupyter_fvsol_proxy") / "icons" / "fvs.png"
    if icon.is_file():
        launcher_entry["icon_path"] = str(icon)

    return {
        "command": ["Rscript", LAUNCHER, "{port}"],
        # Attaching ~15 heavy R packages (rgl, leaflet, Cairo, ...) on first
        # request takes well over the 5s default; give the app time to bind.
        "timeout": 120,
        # jupyter-server-proxy strips the /fvs-gui prefix before forwarding;
        # Shiny then emits correct relative asset URLs. Do NOT set True.
        "absolute_url": False,
        "launcher_entry": launcher_entry,
    }
