# Binder launch shim for the FVSOnLocal GUI image.
#
# repo2docker's DockerBuildPack uses this file verbatim when mybinder.org
# builds a Binder for the fvs-build repo. The heavy image it references
# (docker/Dockerfile.fvs-gui, published to GHCR by
# build-container-fvs-gui-linux.yml) already satisfies every Binder
# requirement -- a jovyan user at uid 1000, a Jupyter server on PATH, and
# jupyter-server-proxy configured with the "fvs-gui" entry -- so no NB_USER
# / jupyter injection is needed here and the Binder build finishes in seconds.
#
# The referenced image MUST be public on GHCR for mybinder.org to pull it.
# Pin an immutable, already-published tag; bump it when a new GUI image ships.
# See the "Run the FVS GUI on Binder" section of the README.
FROM ghcr.io/vibrant-planet-open-science/usfs-fvs-gui:FS2026.2
