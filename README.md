# fvs-build

[![Binder](https://mybinder.org/badge_logo.svg)](https://mybinder.org/v2/gh/Vibrant-Planet-Open-Science/fvs-build/main?urlpath=lab)

Builds and publishes the Forest Vegetation Simulator (FVS) from USDA Forest Service (and other compatible) sources. FVS products available include a free version of the FVS GUI running on the cloud, multi-arch Docker container images available on GHCR, and reusable GitHub workflows that can be called from other repositories to produce Linux, Windows, and macOS binaries of FVS (executables and shared libraries) with provenance and SBOMs.

## Run the FVS GUI on Binder

Click the "Launch Binder" badge above, and you'll be taken to a cloud-hosted instance of JupyterLab running on [mybinder.org](https://mybinder.org). From there you can just click the **FVS GUI** tile from the Launcher page to fire up the FVS GUI, which is running on a virtual machine in the cloud. Be aware that Binder sessions are temporary, so download anything you want to keep before the session ends.

The Docker container image behind the badge is `ghcr.io/vibrant-planet-open-science/usfs-fvs-gui`; see `docs/fvs-gui-container.md` for how it is built and published.

## Run FVS on your machine using Docker

Docker Images are published at `ghcr.io/vibrant-planet-open-science/usfs-fvs` (the FVS executables and shared libraries alone) and `ghcr.io/vibrant-planet-open-science/usfs-fvs-gui` (the FVS graphical interface, plus the same executables and Jupyter R and Python kernels with `rFVS` and `fvs2py`). The images are tagged by FVS release (e.g. `2027.1.0`), but you can also use the `latest` tag to pull whichever version is the most recent. The images are multi-arch (linux/amd64, linux/arm64), so they will run natively on your machine whether you're running Docker from Windows, Linux, or Mac.

### Use the FVS GUI and notebooks on your computer

This runs the same JupyterLab as the Binder button above, on your own computer: the **FVS GUI** tile, plus notebooks that can run FVS from R or Python.

1. Install [Docker Desktop](https://www.docker.com/products/docker-desktop/) (Windows or Mac) or [Docker Engine](https://docs.docker.com/engine/install/) (Linux), and start it.
2. Open a terminal: **PowerShell** on Windows, **Terminal** on Mac or Linux.
3. **Linux only:** run this in the terminal to create the two folders where your work is saved and let FVS write to them. (On Windows and Mac, Docker creates them for you.)

   ```
   mkdir -p fvs-work fvs-projects && chmod 777 fvs-work fvs-projects
   ```

4. Run this in the terminal. The first time, Docker downloads the image (FVS with R, Python and JupyterLab: about 1 GB to download, about 4 GB on disk), which can take several minutes.

   ```
   docker run --rm -p 8888:8888 -v "${PWD}/fvs-work:/home/jovyan/work" -v "${PWD}/fvs-projects:/home/jovyan/project" ghcr.io/vibrant-planet-open-science/usfs-fvs-gui:latest
   ```

5. Open the link it prints that starts with `http://127.0.0.1:8888/lab?token=` in your web browser.
6. Click the **FVS GUI** tile to open the GUI. Your work is kept in two folders inside the folder the terminal started in (your home folder):
   - `fvs-projects`: your FVS GUI projects.
   - `fvs-work`: notebooks and other files you save in the `work` folder in JupyterLab's file list. Anything saved outside `work` is deleted when you stop.
7. To stop, go back to the terminal and press **Ctrl+C**.

### Run FVS from the command line

To run a keyfile in your current working directory with the `usfs-fvs` image, you do a volume mount of your working directory into the Docker container (`-v "$PWD:/data"`) and then call the FVS variant of your choice as a command line tool (`FVSak --keywordfile=mykeyfile.key`):

```bash
docker run --rm \
  -v "$PWD:/data" \
  ghcr.io/vibrant-planet-open-science/usfs-fvs:latest \
  FVSak --keywordfile=mykeyfile.key
```

The `usfs-fvs-gui` image carries the same executables. With it, add `-w /data` (its working directory is the GUI user's home) and `--user "$(id -u):$(id -g)"`, since it otherwise runs as uid 1000, which may not be able to write to your directory.

The `usfs-fvs` image can also be used as a builder stage in your own Dockerfiles to extract any FVS binaries you need for your own containerized project:

```dockerfile
FROM ghcr.io/vibrant-planet-open-science/usfs-fvs:latest AS fvs
FROM ubuntu:24.04
COPY --from=fvs /usr/local/bin/FVSak /usr/local/bin/
COPY --from=fvs /usr/local/lib/FVSak.so /usr/local/lib/
RUN apt-get update && apt-get install -y libgfortran5 && rm -rf /var/lib/apt/lists/*
```

OCI provenance labels (`org.opencontainers.image.*` plus custom `org.vibrantplanet.fvs.*`) record the source repo, ref, SHA, toolchain versions, and variant set baked in. You can inspect these labels with:

```bash
docker inspect ghcr.io/vibrant-planet-open-science/usfs-fvs:2027.1.0 | jq '.[0].Config.Labels'
```

## Variants

All 24 FVS variants are addressable by their two-letter codes. The Docker images and default workflow builds include the 22 US variants only. In the table below, Canadian variants are marked with † because they don't currently build successfully from the official FVS repository (see [Known upstream issues](#known-upstream-issues-in-usdaforestserviceforestvegetationsimulator)).

| Code | Region |
| --- | --- |
| `ak` | Alaska |
| `bc` | British Columbia (Canada) † |
| `bm` | Blue Mountains |
| `ca` | Inland California / Southern Cascades |
| `ci` | Central Idaho |
| `cr` | Central Rockies |
| `cs` | Central States |
| `ec` | East Cascades |
| `em` | Eastern Montana |
| `ie` | Inland Empire |
| `kt` | Klamath / Tetons |
| `ls` | Lake States |
| `nc` | Inland California (North-Central) |
| `ne` | Northeast |
| `oc` | ORGANON Southwest (Oregon) |
| `on` | Ontario (Canada) † |
| `op` | ORGANON Pacific Northwest (coastal) |
| `pn` | Pacific Northwest |
| `sn` | Southern |
| `so` | South-Central Oregon / Northeast California |
| `tt` | Tetons |
| `ut` | Utah |
| `wc` | West Cascades |
| `ws` | West Sierras |

## Build FVS in your repository with reusable GitHub workflows

Five reusable `workflow_call` workflows can be used to build the native binaries (one workflow for each OS including Linux, MacOS, and Windows), the runtime image (binaries only in the container), and the FVS GUI image.

### Supported FVS versions

The workflows build from`USDAForestService/ForestVegetationSimulator` and support release tags from "**FS2026.3" or more recent**. FVS versions prior to FS2026.3 include copies of the`volume/NVEL` submodule that included stale gfortran `.mod` files, which cause errors during the build. Those were fixed in release FS2026.3. Upstream tags use `YYYY.N.P` from `2027.1.0`, which is the default ref and the one CI tests.

### Native binaries only

```yaml
jobs:
  fvs-binaries:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: 2027.1.0
      profile: reference
```

Produces a single bundle of artifacts (including binaries for each FVS variant + provenance manifest + a Software Bill of Materials following the System Package Data Exchange standard, SPDX SBOM). To produce binaries for another operating system, such as Windows, just change the `uses` line to point to that workflow: `Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-windows.yml@main`

### Native binaries + container image

You can integrate these workflows as steps in your own, gathering the binaries from the `build_native` workflow, and using them in your own `container` step, for example.

```yaml
permissions:
  contents: read
  packages: write

jobs:
  native:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: 2027.1.0

  container:
    needs: native
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-container-linux.yml@main
    with:
      artifact_name: ${{ needs.native.outputs.artifact_name }}
      image_name: ghcr.io/your-org/usfs-fvs
      image_tag: 2027.1.0
      image_extra_tags: latest
      push: true
    secrets: inherit
```

In this example, the `build-container` workflow copies the already-validated native binaries into a runtime-only Ubuntu 24.04 Docker image and pushes it the GitHub Container Registry with full OCI provenance labels (only pushing to GHCR when `push: true`).

See `docs/workflow-interface.md` for the full input/output patterns for these and other workflows, more details on the layout of artifacts within the bundle, the OCI labels baked into the image, and additional caller snippets.

### Manual drivers

Five `workflow_dispatch` drivers allow the workflows to be triggered manually. These are primarily used for testing purposes and creating releases of the Docker containers from this repo:

```bash
# Native binaries only
gh workflow run dispatch-native-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=2027.1.0 \
  -f profile=reference

# Full native + container, dry run (no push)
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=2027.1.0 \
  -f image_tag=2027.1.0

# Same, but actually push to ghcr.io/vibrant-planet-open-science/usfs-fvs:2027.1.0
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=2027.1.0 \
  -f image_tag=2027.1.0 \
  -f push=true
```

To build the FVS GUI image (dry run, no push):

```bash
gh workflow run dispatch-container-fvs-gui-linux.yml \
  -f source_ref=2027.1.0 \
  -f interface_ref=20261109 \
  -f image_tag=2027.1.0
```

## Known upstream issues in `USDAForestService/ForestVegetationSimulator`

### `bc` and `on` source lists are incomplete

`bin/FVSbc_sourceList.txt` and `bin/FVSon_sourceList.txt` reference Fortran routines (`dbs_fiavbc_cutlst`, `dbs_fiavbc_atrtls`, `dbs_fiavbc_trls`, `dbsreference`) from `vbase/cuts.f` and `base/fvs.f` but do not include the files that **define** those routines — `dbsqlite/dbs_fiavbc_*.f` and `vdbsqlite/dbsreference.f`, all of which are present in the `pn`/`nc`/etc. source lists. The result is undefined-symbol errors at the final shared-library link step:

```
undefined reference to `dbs_fiavbc_cutlst_'
undefined reference to `dbsreference_'
```

This is a source-list completeness bug in upstream `USDAForestService/ForestVegetationSimulator`. Until a fix lands there, omit `bc` and `on` from the `variants` option.

## Acknowledgment and disclaimer

FVS is developed and maintained by the USDA Forest Service, and this project builds on the source code and documentation the Forest Service publishes. fvs-build is an independent project of Vibrant Planet and is not affiliated with or endorsed by the USDA Forest Service. Any opinions, findings, conclusions, or recommendations expressed here are those of the authors and should not be construed to represent any official USDA or U.S. Government determination or policy. The use of trade or firm names is for reader information and does not imply endorsement by the U.S. Department of Agriculture of any product or service.

## Releases

Releases are cut by [release-please](https://github.com/googleapis/release-please). PRs are squash-merged, so each PR title must be a [Conventional Commit](https://www.conventionalcommits.org/) (`feat:`, `fix:`, `build:`, `docs:`, …; `!` or a `BREAKING CHANGE:` footer for breaking changes). release-please keeps an open release PR that bumps the version, `CHANGELOG.md` and the `@vX.Y.Z` pins in `docs/workflow-interface.md`; merging it tags the release. Before 1.0, a breaking change bumps the minor version and a feature or fix bumps the patch. Dependabot keeps the GitHub Actions current with `build(deps):` PRs, which count toward the next release.

## Repository layout

- `meson.build` — Meson build definition that compiles FVS from a source repository. Reads options, parses the repository's`bin/FVS<variant>_sourceList.txt` manifests at configure time, and emits per-variant build targets.
- `meson_options.txt` — build-time options (`fvs_source_dir`, `variants`, `profile`, `traps`, and local-only `extra_fortran_args`).
- `tools/parse_sourcelist.py` — turns one source list into the categorized file lists Meson consumes to build the binaries, invoked during the Meson build for each variant.
- `.github/workflows/build-native-linux.yml`, `.github/workflows/build-native-windows.yml`, `.github/workflows/build-native-macos.yml` — reusable `workflow_call` workflows that run the Meson build for a single OS. Each produces an artifact bundle (binaries + provenance + SBOM); see `docs/workflow-interface.md`.
- `.github/workflows/build-container-linux.yml` — reusable `workflow_call` workflow that packages the native binaries into a runtime-only Ubuntu 24.04 container image, with option to push the image to GHCR.
- `.github/workflows/build-container-fvs-gui-linux.yml` — reusable `workflow_call` workflow that builds the FVSOnLocal (`fvsOL`) GUI image. It copies the native Linux binaries (`FVS<v>.so`) and builds the `rFVS`/`fvsOL` R layer on a `rocker/r2u:noble`base image with additional configuration settings that allow the image to be hosted via Binder.
- `.github/workflows/dispatch-native-linux.yml`, `.github/workflows/dispatch-native-windows.yml`, `.github/workflows/dispatch-native-macos.yml` — manually-triggered option for each native OS workflow (`workflow_dispatch`).
- `.github/workflows/dispatch-container-linux.yml` — manually-triggered option for the native Linux + container steps in sequence.
- `.github/workflows/dispatch-container-fvs-gui-linux.yml` — manually-triggered option for running native Linux + FVS GUI container steps in sequence.
- `docker/Dockerfile.runtime` — runtime image definition (Ubuntu 24.04 + `libgfortran5` + the variant binaries; supports standard FVS command-line invocation).
- `docker/Dockerfile.fvs-gui` — FVSOnLocal GUI image definition (`rocker/r2u:noble` + Jupyter + `jupyter-server-proxy`; copies the `FVS<v>` executables and `FVS<v>.so` shared libraries, installs `fvs2py` and an R kernel, builds `rFVS`/`fvsOL` from source). Its baked-in launch shim and proxy configuration for running the web browser interface live under `docker/fvs-gui/`.
- `binder/Dockerfile` — thin `FROM ghcr.io/vibrant-planet-open-science/usfs-fvs-gui:<tag>` shim so mybinder.org can launch the GUI image in seconds rather than building from scratch.
- `docs/local-builds.md` — details for running the Meson build by hand, primarily intended for developers who would like to work on the `fvs-build` project or run Meson-based builds themselves.
- `docs/workflow-interface.md` — the reusable workflows' inputs, outputs and artifact contract.
- `release-please-config.json`, `.release-please-manifest.json`, `.github/workflows/release-please.yml` — release automation (see [Releases](#releases)).
- `.github/dependabot.yml` — weekly GitHub Actions updates for the workflows and composite actions.
- `docs/fvs-gui-container.md` — maintainer notes for the FVS GUI image: build steps, the `fvsOL` Local-mode patch, smoke checks and Binder publishing.
- Shared CI helpers used by the three native workflows:
  - `tools/ci/resolve_variants.sh` — normalizes the `variants` input into the list each build job loops over.
  - `.github/actions/prepare-fvs-native-checkout/` — resolves the overlay repo/ref and checks out `fvs-build/` and `fvs-source/`.
  - `tools/ci/meson_configure_native.sh` — `meson setup` with the requested `profile`.
  - `tools/ci/smoke_test_native.sh` — runs each variant executable to `STOP 20` and checks its `--version` build info.
  - `tools/ci/provenance.py` — `bundle` assembles the bundle (binaries, provenance, SBOM) at the end of each build job; `manifest-to-github-env` reads its manifest for the container workflows.
  - `.github/actions/resolve-fvs-build-ref/` — reads the overlay repo, ref and commit from `job.workflow_*` (correct for callers in other repos, where `github.*` is the caller's).
