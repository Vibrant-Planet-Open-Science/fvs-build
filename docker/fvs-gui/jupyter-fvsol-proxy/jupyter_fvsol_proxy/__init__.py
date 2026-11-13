"""jupyter-server-proxy registration for the fvsOL Shiny app at `/fvs-gui/`.

Registered through the `jupyter_serverproxy_servers` entry point, not a config
file: mybinder mounts a Kubernetes ConfigMap over /etc/jupyter at runtime, which
hides any config placed there. jupyter-server-proxy skips a raising entry point
with only a warning (a silent 404), so Dockerfile.fvs-gui asserts this module
loads at build time.
"""

import os
from importlib.resources import files

# Overridable to run the shim from a checkout without rebuilding the image.
LAUNCHER = os.environ.get("FVSOL_LAUNCHER", "/opt/fvs/launch.R")


def setup_fvs_gui() -> dict[str, object]:
    """Build the jupyter-server-proxy server definition for fvsOL.

    Returns:
        Keyword arguments for ``jupyter_server_proxy.config.ServerProcess``.
        The server's name (and so its URL segment) comes from the entry point
        name, not from this dict.
    """
    launcher_entry: dict[str, object] = {"title": "FVS GUI", "enabled": True}

    # A missing icon must not drop the launcher entry.
    icon = files("jupyter_fvsol_proxy") / "icons" / "fvs.png"
    if icon.is_file():
        launcher_entry["icon_path"] = str(icon)

    return {
        "command": ["Rscript", LAUNCHER, "{port}"],
        # Attaching ~15 heavy R packages (rgl, leaflet, Cairo, ...) on first
        # request takes well over the 5s default; give the app time to bind.
        "timeout": 120,
        # The proxy strips the /fvs-gui prefix so Shiny's relative asset URLs
        # resolve. Do NOT set True.
        "absolute_url": False,
        "launcher_entry": launcher_entry,
    }
