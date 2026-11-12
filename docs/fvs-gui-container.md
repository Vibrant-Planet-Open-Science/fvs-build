# FVS GUI container

Maintainer notes for `build-container-fvs-gui-linux.yml` and `docker/Dockerfile.fvs-gui`. The workflow's inputs and outputs are in [`workflow-interface.md`](workflow-interface.md#build-container-fvs-gui-linuxyml).

## What the workflow does

1. Check out `fvs-build` at the commit that defines the called workflow (`job.workflow_repository` @ `job.workflow_sha`), for `docker/Dockerfile.fvs-gui` and the files baked into the image.
2. Download the named native bundle into `bundle/` and verify it provides the `FVS<v>.so` set.
3. Check out `interface_repo` at `interface_ref` into `interface/`, then stage the `rFVS` and `fvsOL` package roots into `fvs-gui-context/rFVS` and `fvs-gui-context/fvsOL`. The roots are found by their `DESCRIPTION` files (`Package: rFVS` / `Package: fvsOL`), so the Dockerfile's `COPY` paths do not depend on where the packages live in the Interface repo. The resolved Interface SHA is captured for provenance.
4. Extract FVS source/toolchain/variant provenance from `bundle/provenance/manifest.json` with `tools/ci/provenance.py` (`manifest-to-github-env`), and fail unless the bundle's `arch` matches the leg.
5. `docker buildx build --load --platform linux/<arch> -f docker/Dockerfile.fvs-gui .`, with bundle and Interface provenance as `--build-arg`s (which become OCI labels). The Actions layer cache is scoped per arch (`fvs-gui-<arch>`).
6. Run the [smoke test](#smoke-test) against the loaded image.
7. If `push: true`: log in to GHCR (when `image_name` starts with `ghcr.io/`), push by digest, and upload the digest as `container-fvs-gui-digest-<arch>-<run_id>`.
8. Generate an SPDX SBOM of the image with `syft` and upload it as `container-fvs-gui-sbom-<arch>-<run_id>`.
9. If `push: true`, a `manifest` job joins the per-arch digests into one manifest list carrying every tag.

Steps 1–8 run once per arch: `amd64` on `runner_image`, plus `arm64` on `ubuntu-24.04-arm` when `artifact_name_arm64` is set. `ci-test-fvs-gui-container.yml` builds amd64 only; the arm64 image is exercised by `dispatch-container-fvs-gui-linux.yml` (`arm64` input, default `true`).

## Files baked into the image

| Path | Content |
| --- | --- |
| `/opt/fvs/FVSbin/FVS<v>.so` | per-variant shared library (`rFVS::fvsLoad()` globs these) |
| `/opt/fvs/launch.R` | launch shim (`docker/fvs-gui/launch.R`): neutralizes `launch.browser=TRUE`, pins host/port, and calls `shiny::runApp()` inside a **supervise loop**. `fvsOL` calls `stopApp()` on every session end, which makes `runApp()` return, and jupyter-server-proxy never respawns a cleanly-exited process. A fast-exit guard (3 consecutive exits under 5 s) fails loudly instead of spinning. See smoke check 9 |
| `jupyter-fvsol-proxy` (pip-installed into `/opt/venv`) | registers the `fvs-gui` proxy entry via the `jupyter_serverproxy_servers` entry point (`docker/fvs-gui/jupyter-fvsol-proxy/`): `timeout: 120`, `absolute_url: False`, no `environment` (leaving `SHINY_PORT` unset selects Local mode), plus the launcher icon. See smoke checks 7 and 8 |
| `/opt/fvs/patches/` | `fvsOL` source patches (`docker/fvs-gui/patches/`), applied before the package is built and kept in the image to record what it was patched with. See [Local mode and the `fvsOL` patch](#local-mode-and-the-fvsol-patch) |
| `/usr/share/fvs-build/manifest.json` | the native bundle's provenance manifest |
| `/usr/share/fvs-build/sbom-binaries.spdx.json` | the native bundle's binary SBOM |

The image has no `ENTRYPOINT`. On Binder, JupyterHub spawns `jupyterhub-singleuser` (from the `jupyterhub` pip package, **not** `jupyter lab` or `jupyter notebook`: without that binary the single-user server never starts and every `/user/<id>/` path returns a bare 404, while the image still runs fine under `docker run`). jupyter-server-proxy then launches `Rscript /opt/fvs/launch.R {port}` on the first hit to `/fvs-gui/` and reverse-proxies the Shiny app. The Binder user is `jovyan` (uid 1000) with a writable starter project at `/home/jovyan/project` (`FVSOL_PRJDIR`); the shared libraries live under `/opt/fvs/FVSbin` (`FVSOL_BIN`).

## Publishing for Binder

`binder/Dockerfile` is a single `FROM ghcr.io/vibrant-planet-open-science/usfs-fvs-gui:<tag>`, so mybinder.org builds it in seconds. Two things govern whether the README badge picks up a published image:

- **The GHCR package must be public.** mybinder.org pulls the image anonymously, so publish it (`push: true`) and mark the package public.
- **Re-publishing a tag does not reach an existing Binder.** mybinder caches builds by repo ref, not by the digest behind the tag in `binder/Dockerfile`. A new commit on the branch the badge points at forces a rebuild; overwriting the GHCR tag does not.

The `/fvs-gui/` route is registered by an entry point, not a Jupyter config file: mybinder mounts a Kubernetes ConfigMap over `/etc/jupyter` at runtime, so anything registered there is invisible on Binder even though `docker run` works.

## Local mode and the `fvsOL` patch

`fvsOL` picks its mode from `isLocal()`, which is `Sys.getenv('SHINY_PORT') == ""` (`server.R:113`). The proxy config sets no environment, so the image runs in **Local** mode. Local mode is what makes the Manage Projects tab work: `shinyDirChoose` for "Change Working Directory" is registered only under `if (isLocal())` (`server.R:421`), the "Upload project backup zip file" observer returns immediately otherwise (`server.R:6156`), and "Open selected project" only does the `setwd`/reload in the Local branch (`server.R:8781`). Online mode does **not** hide those three: `FVSOnlineUI` (`ui.R:1`) is a package-level object whose `isLocal()` branches were frozen `TRUE` at install time during `docker build`, while the server re-evaluates them per request, so under Online mode they render and do nothing.

Local mode needs three fixes here. Two are source-level, in `docker/fvs-gui/patches/0001-fvsol-local-mode-behind-proxy.patch`, applied by `Dockerfile.fvs-gui` before `document()`/`install()`:

| Fix | Where | Why |
| --- | --- | --- |
| "View On Maps" popup graph URL | `server.R:5933` | with `Display: graph`, each stand's leaflet popup shows a PNG written to `./www/s<sid>.png` and served via `addResourcePath("www", …)`. The Local branch addresses it as an origin-absolute `/www/s<sid>.png`, which 404s under the `/fvs-gui/` prefix. The other branch derives the URL from `session$clientData$url_pathname`, correct both behind a proxy and with none, so the patch drops the `isLocal()` special case |
| lock-file name case | `server.R:8783`, `8920` | the lock is written as `projectIsLocked.txt` (`server.R:224`) but removed as `ProjectIsLocked.txt`. On a case-sensitive filesystem the removal silently fails, every project the user leaves keeps a stale lock, and `getProjectList()` drops locked projects, so it vanishes from the picker |
| `fs` not attached | `launch.R` | `getVolumes2()` (`change_project_dir.R`) calls `fs::dir_exists`/`dir_ls` unqualified while `fvsOL` neither `Depends` on nor `Imports` `fs`, so the session dies at construction with `could not find function "dir_exists"`. `fs` is already in the image and only needs attaching. Kept deployment-side so it is not a third source hunk to carry across `interface_ref` bumps |

The patch is applied with `git apply` (no fuzz). The Dockerfile re-greps `fvsOL/R` for both defects, and smoke check 10 greps the sources baked into the built image. `.pre-commit-config.yaml` excludes `docker/fvs-gui/patches/` from the whitespace and end-of-file hooks: the diff's context lines carry upstream's trailing whitespace, and "cleaning" them makes `git apply` reject the patch.

Two Local-mode behaviours are known and not fixed:

- **The directory chooser is rooted at `/`.** `getVolumes2()` returns `c(Computer = "/")` on Linux. In a single-user Binder container that grants nothing the JupyterLab terminal does not, but it needs a decision before any shared or multi-tenant deployment.
- **A working-directory change does not survive a relaunch.** `launch.R`'s supervise loop re-enters `fvsOL(prjDir = FVSOL_PRJDIR, …)`, so a session that ends after a directory switch comes back in the starter project.

**Exit criteria:** when both source fixes merge upstream, delete `docker/fvs-gui/patches/`, the Dockerfile apply and assert steps, and smoke check 10, then bump `interface_ref` to the merged SHA.

## Why `interface_ref` must be FS2026.3 or later

`fvsOL` used to write scratch tables with `dbWriteTable(con, DBI::SQL("temp.X"), …)`. On **RSQLite ≥ 3.53.1** that fails with `Named parameters not used in query: name`, which greys out the app as soon as a stand is selected. Upstream fixed it in [ForestVegetationSimulator-Interface PR #29](https://github.com/USDAForestService/ForestVegetationSimulator-Interface/pull/29) (`92dc046`), first released in `FS2026.3`. `Dockerfile.fvs-gui` asserts the staged sources contain no `DBI::SQL("temp…")` in `fvsOL/R`, so an affected ref fails at build time.

## Smoke test

Unlike the runtime image, the GUI image is smoke-tested before it is pushed: several failure modes (packages not attaching, a copied `.so` not loadable in-image, the RSQLite regression, a broken proxy path) only surface at runtime. `tools/ci/smoke_fvs_gui.sh` runs against an already-built image after `docker buildx build --load` and before the GHCR push, so a failure blocks publication.

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
| 10\. neither patched defect is present in the `fvsOL/R` sources baked into the image | a published image built without the patch |
| 11\. `isLocal()` is `TRUE` and `getVolumes2()()` returns a non-empty volume list | `launch.R` no longer attaching `fs`, which kills every Local-mode session after the page is served |
| 12\. `getProjectList()` returns instead of erroring with the open project locked | the Manage Projects tab greying out on first click |

Run it locally against a `--load`ed image:

```bash
docker buildx build --load -t usfs-fvs-gui:local -f docker/Dockerfile.fvs-gui .
tools/ci/smoke_fvs_gui.sh usfs-fvs-gui:local
```

Override the variant used in check 2 with `SMOKE_VARIANT=<code>`; it otherwise auto-detects one from `/opt/fvs/FVSbin`.

## Local validation

```bash
gh workflow run dispatch-container-fvs-gui-linux.yml \
  -f source_ref=FS2026.3 \
  -f interface_ref=FS2026.3 \
  -f image_tag=FS2026.3 \
  -f push=false
```

`push=false` (the default) builds the image without publishing. With `-f push=true` it publishes to `ghcr.io/<your-account>/usfs-fvs-gui:FS2026.3`; make the GHCR package public before pointing mybinder.org at it.
