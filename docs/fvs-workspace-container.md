# FVS workspace container

Maintainer notes for `build-container-fvs-workspace.yml` and `docker/Dockerfile.fvs-workspace`. The workflow's inputs and outputs are in [`workflow-interface.md`](workflow-interface.md#build-container-fvs-workspaceyml).

## What the workflow does

1. Check out `fvs-build` at the commit that defines the called workflow (`job.workflow_repository` @ `job.workflow_sha`), for `docker/Dockerfile.fvs-workspace` and the files baked into the image.
2. Download the named native bundle into `bundle/` and verify it provides the `FVS<v>.so` set.
3. Check out `interface_repo` at `interface_ref` into `interface/`, then stage the `rFVS` and `fvsOL` package roots into `fvs-workspace-context/rFVS` and `fvs-workspace-context/fvsOL`. The roots are found by their `DESCRIPTION` files (`Package: rFVS` / `Package: fvsOL`), so the Dockerfile's `COPY` paths do not depend on where the packages live in the Interface repo. The resolved Interface SHA is captured for provenance.
4. Extract FVS source/toolchain/variant provenance from `bundle/provenance/manifest.json` with `tools/ci/provenance.py` (`manifest-to-github-env`), and fail unless the bundle's `arch` matches the leg.
5. `docker buildx build --load --platform linux/<arch> -f docker/Dockerfile.fvs-workspace .`, with bundle and Interface provenance as `--build-arg`s (which become OCI labels). The Actions layer cache is scoped per arch (`fvs-workspace-<arch>`).
6. Run the [smoke test](#smoke-test) against the loaded image.
7. If `push: true`: log in to GHCR (when `image_name` starts with `ghcr.io/`), push by digest, and upload the digest as `container-fvs-workspace-digest-<arch>-<run_id>`.
8. Generate an SPDX SBOM of the image with `syft` and upload it as `container-fvs-workspace-sbom-<arch>-<run_id>`.
9. If `push: true`, a `manifest` job joins the per-arch digests into one manifest list carrying every tag.

Steps 1–8 run once per arch: `amd64` on `ubuntu-24.04`, plus `arm64` on `ubuntu-24.04-arm` unless `arm64: false`. On pull requests, `ci-test-reusable-native.yml` builds and smoke-tests both arches, without pushing, whenever the workspace image's files or anything behind the native bundles change. It reuses the Linux bundles that run builds anyway.

## Files baked into the image

| Path | Content |
| --- | --- |
| `/usr/local/lib/FVS<v>.so` | per-variant shared library (`FVS_BIN`; `fvsOL` lists the `FVS*.so` files there) |
| `/usr/local/bin/FVS<v>` | per-variant executable, for running FVS from the command line (see README) |
| `fvs2py` (in `/opt/venv`) and `IRkernel` | Python and R access to the `.so` set from Jupyter notebooks. `FVS_BIN=/usr/local/lib` points both at it: `rFVS::fvsLoad("FVSpn", bin = Sys.getenv("FVS_BIN"))`, `fvs2py.FVS(os.path.join(os.environ["FVS_BIN"], "FVSpn.so"))` |
| `/opt/fvs/launch.R` | launch shim (`docker/fvs-workspace/launch.R`): neutralizes `launch.browser=TRUE`, pins host/port, and calls `shiny::runApp()` inside a **supervise loop**. `fvsOL` calls `stopApp()` on every session end, which makes `runApp()` return, and jupyter-server-proxy never respawns a cleanly-exited process. A fast-exit guard (3 consecutive exits under 5 s) fails loudly instead of spinning. See smoke check 9 |
| `jupyter-fvsol-proxy` (pip-installed into `/opt/venv`) | registers the `fvs-gui` proxy entry via the `jupyter_serverproxy_servers` entry point (`docker/fvs-workspace/jupyter-fvsol-proxy/`): `timeout: 120`, `absolute_url: False`, no `environment` (leaving `SHINY_PORT` unset selects Local mode), plus the launcher icon. See smoke checks 7 and 8 |
| `/usr/share/fvs-build/manifest.json` | the native bundle's provenance manifest |
| `/usr/share/fvs-build/sbom-binaries.spdx.json` | the native bundle's binary SBOM |

The image's default command starts JupyterLab on port 8888 (`EXPOSE 8888`), for running it locally (see the [fvs-workspace README](https://github.com/Vibrant-Planet-Open-Science/fvs-workspace#run-it-on-your-computer-with-docker)). It has no `ENTRYPOINT`, so any other command replaces the default. On Binder, JupyterHub spawns `jupyterhub-singleuser` (from the `jupyterhub` pip package, **not** `jupyter lab` or `jupyter notebook`: without that binary the single-user server never starts and every `/user/<id>/` path returns a bare 404, while the image still runs fine under `docker run`). jupyter-server-proxy then launches `Rscript /opt/fvs/launch.R {port}` on the first hit to `/fvs-gui/` and reverse-proxies the Shiny app. The Binder user is `jovyan` (uid 1000) with a writable starter project at `/home/jovyan/project` (`FVSOL_PRJDIR`); the shared libraries live in `/usr/local/lib` (`FVS_BIN`).

## Publishing

The published image comes from [fvs-workspace](https://github.com/Vibrant-Planet-Open-Science/fvs-workspace): each of its releases calls this workflow with `push: true`, its own version as `image_tag`, and pinned FVS, Interface and fvs-build refs. The package is linked to that repository (`org.opencontainers.image.source` is the caller), which also holds the Binder badge and `binder/Dockerfile`.

## Binder constraints

The `/fvs-gui/` route is registered by an entry point, not a Jupyter config file: mybinder mounts a Kubernetes ConfigMap over `/etc/jupyter` at runtime, so anything registered there is invisible on Binder even though `docker run` works.

## Local mode

`fvsOL` picks its mode from `isLocal()`, which is `Sys.getenv('SHINY_PORT') == ""` (`server.R:113`). The proxy config sets no environment, so the image runs in **Local** mode. Local mode is what makes the Manage Projects tab work: `shinyDirChoose` for "Change Working Directory" is registered only under `if (isLocal())` (`server.R:449`), the "Upload project backup zip file" observer returns immediately otherwise (`server.R:6009`), and "Open selected project" only does the `setwd`/reload in the Local branch (`server.R:8661`). Online mode does **not** hide those three: `FVSOnlineUI` (`ui.R:1`) is a package-level object whose `isLocal()` branches were frozen `TRUE` at install time during `docker build`, while the server re-evaluates them per request, so under Online mode they render and do nothing.

Two Local-mode behaviours are known and not fixed:

- **The directory chooser is rooted at `/`.** `shinyFiles::getVolumes()()` returns `c(Computer = "/")` in the image. In a single-user Binder container that grants nothing the JupyterLab terminal does not, but it needs a decision before any shared or multi-tenant deployment.
- **A working-directory change does not survive a relaunch.** `launch.R`'s supervise loop re-enters `fvsOL(prjDir = FVSOL_PRJDIR, …)`, so a session that ends after a directory switch comes back in the starter project.

## Minimum `interface_ref`

`interface_ref` must be Interface release `20261121` or later. Earlier releases lack three `fvsOL` fixes Local mode needs on Linux behind the `/fvs-gui/` proxy: "Change Working Directory" ([#43](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/issues/43)), the project lock on a project switch ([#45](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/issues/45)) and View On Maps popup images ([#47](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/issues/47)). Smoke check 10 fails an image built from an older ref. Releases before `20261019` also ship `rFVS` and `fvsOL` without the `NAMESPACE` that `R CMD INSTALL` needs, which `Dockerfile.fvs-workspace` checks.

## Smoke test

Unlike the runtime image, the workspace image is smoke-tested before it is pushed: several failure modes (packages not attaching, a copied `.so` not loadable in-image, an RSQLite incompatibility, a broken proxy path) only surface at runtime. `tools/ci/smoke_fvs_workspace.sh` runs against an already-built image after `docker buildx build --load` and before the GHCR push, so a failure blocks publication.

| Check | Catches |
| --- | --- |
| 1\. `fvsOL` + `rFVS` attach (`library()`) | `Depends` not attaching (e.g. unqualified `addResourcePath`) |
| 2\. an `FVS<v>.so` loads via `rFVS::fvsLoad` with its expected C API symbols | a copied `.so` not runnable in-image (glibc/libgfortran mismatch) |
| 3\. the `temporary = TRUE` write pattern works and the default `FVS_Data.db` opens | a future RSQLite breaking the call style `fvsOL` relies on (r2u installs it unpinned) |
| 4\. the app boots headless via `launch.R` → HTTP 200 Shiny page | `fvsOL()` startup errors, hardcoded `launch.browser`, missing assets |
| 5\. jupyter-server-proxy serves the app at `<base_url>/fvs-gui/` under a JupyterHub-style prefix | proxy config and `absolute_url: False` prefix handling |
| 6\. `jupyterhub-singleuser` is on `PATH` | the binary BinderHub spawns being absent; checks 4 and 5 start the server themselves, so nothing else notices |
| 7\. `<base_url>/fvs-gui/` still serves with an empty dir mounted over `/etc/jupyter`, and `server-proxy/icon/fvs-gui` returns `image/png` | the proxy registration living only where mybinder's ConfigMap mount shadows it |
| 8\. the `jupyter_serverproxy_servers` entry point is registered, validates as a `ServerProcess`, and sets no `SHINY_PORT` | a broken entry point (skipped with only a warning, so the symptom is a silent 404), or a reintroduced Online mode |
| 9\. `launch.R` relaunches `fvsOL` after `stopApp()` | the supervise loop regressing, which bricks the Binder session when the tab closes |
| 10\. the `fvsOL/R` sources baked into the image include the Local-mode fixes from Interface `20261121` | an image built from an older `interface_ref` |
| 11\. `getProjectList()` returns instead of erroring with the open project locked | the Manage Projects tab greying out on first click |
| 12\. an `FVS<v>` executable on `PATH` runs `--version` and reaches `STOP 20` on empty input | the executables missing from the image, or not runnable in it |
| 13\. `fvs2py` loads an `FVS<v>.so` from `$FVS_BIN` | an `fvs2py` release whose required API routines the `.so` lacks, or `FVS_BIN` pointing elsewhere |
| 14\. `jupyter kernelspec list` shows `ir` and `python3` | a notebook kernel missing on Binder |
| 15\. `docker run` with no command serves JupyterLab on 8888 and prints the `http://127.0.0.1:8888/lab?token=` link | the README's local instructions breaking |

Run it locally against a `--load`ed image:

```bash
docker buildx build --load -t fvs-workspace:local -f docker/Dockerfile.fvs-workspace .
tools/ci/smoke_fvs_workspace.sh fvs-workspace:local
```

Override the variant used in checks 2, 12 and 13 with `SMOKE_VARIANT=<code>`; it otherwise auto-detects one from `/usr/local/lib`.

## Local validation

```bash
gh workflow run dispatch-container-fvs-workspace.yml \
  -f source_ref=2027.1.1 \
  -f interface_ref=20261121 \
  -f image_tag=2027.1.1 \
  -f push=false
```

`push=false` (the default) builds the image without publishing. With `-f push=true` it publishes to `ghcr.io/<your-account>/fvs-workspace:2027.1.1`, which is for forks: in this organization the package belongs to fvs-workspace, and fvs-build's token cannot push to it.
