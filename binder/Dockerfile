# Binder launch shim for the FVSOnLocal GUI image.
#
# repo2docker's DockerBuildPack uses this file verbatim when mybinder.org
# builds a Binder for the fvs-build repo. The heavy image it references
# (docker/Dockerfile.fvs-gui, published to GHCR by
# build-container-fvs-gui-linux.yml) carries what Binder requires -- a jovyan
# user at uid 1000, jupyter-server-proxy configured with the "fvs-gui" entry,
# and jupyterhub-singleuser, the binary JupyterHub actually spawns -- so no
# NB_USER / jupyter injection is needed here and the build finishes in seconds.
#
# That last one is easy to overlook: BinderHub does not run `jupyter lab` or
# `jupyter notebook`. If jupyterhub-singleuser is absent the single-user server
# never starts and every /user/<id>/ path 404s, even though the image runs
# perfectly under `docker run`. smoke check 6 guards it.
#
# The referenced image MUST be public on GHCR for mybinder.org to pull it.
# Pin an immutable, already-published tag; bump it when a new GUI image ships.
#
# Note on propagation: mybinder caches builds by *repo ref*, not by the digest
# behind this tag. Re-publishing the same tag does NOT reach an already-built
# Binder -- a new commit on the branch the badge points at is what triggers a
# rebuild. See the "Run the FVS GUI on Binder" section of the README.
FROM ghcr.io/vibrant-planet-open-science/usfs-fvs-gui:FS2026.2
