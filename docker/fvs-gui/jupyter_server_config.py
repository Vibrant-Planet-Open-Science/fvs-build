"""jupyter-server-proxy configuration for the FVSOnLocal (fvsOL) Shiny app.

Registers a named proxy entry "fvs-gui" so the Shiny app is reachable at the
`/fvs-gui/` subpath of the Jupyter server (the URL Binder opens via
`?urlpath=fvs-gui/`). jupyter-server-proxy allocates a free {port}, launches
the command, and reverse-proxies to it.

Baked into the image at /etc/jupyter/jupyter_server_config.py (see
docker/Dockerfile.fvs-gui). Kept in this repo so the proxy contract is
reviewable alongside launch.R.
"""

# `c` is injected by the traitlets config loader at load time (this file is
# executed by Jupyter, not imported), so the reference is intentionally undefined.
c.ServerProxy.servers = {  # noqa: F821
    "fvs-gui": {
        "command": ["Rscript", "/opt/fvs/launch.R", "{port}"],
        # Attaching ~15 heavy R packages (rgl, leaflet, Cairo, ...) on first
        # request takes well over the 5s default; give the app time to bind.
        "timeout": 120,
        # jupyter-server-proxy strips the /fvs-gui prefix before forwarding;
        # Shiny then emits correct relative asset URLs. Do NOT set True.
        "absolute_url": False,
        # Non-empty SHINY_PORT => fvsOL isLocal() is FALSE => "Online" mode,
        # whose SVS tree-diagram PNGs use proxy-relative URLs that render
        # under the subpath.
        "environment": {"SHINY_PORT": "1"},
        "launcher_entry": {"title": "FVS GUI", "enabled": True},
    }
}
