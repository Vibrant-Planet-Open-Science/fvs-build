# fvs-build

Builds and publishes the Forest Vegetation Simulator (FVS) from USDA Forest Service (and other compatible) sources: multi-arch Docker container images on GHCR, and reusable GitHub workflows that other repositories can call to produce Linux, Windows, and macOS binaries of FVS (executables and shared libraries) with provenance and SBOMs.

## Use the FVS GUI and notebooks

[fvs-workspace](https://github.com/Vibrant-Planet-Open-Science/fvs-workspace) is the place to start if you want to use FVS rather than build it. It runs JupyterLab with the FVS GUI and R and Python notebooks, in the cloud on Binder or on your own computer with Docker. fvs-build builds its image (`ghcr.io/vibrant-planet-open-science/fvs-workspace`); fvs-workspace publishes and versions it.

## Run FVS on your machine using Docker

The `ghcr.io/vibrant-planet-open-science/usfs-fvs` image holds the FVS executables and shared libraries alone (no GUI or `rFVS` or `fvs2py` wrappers included either). It is tagged by FVS release (e.g. `2027.1.0`), and `latest` points at the most recent. It is multi-arch (linux/amd64, linux/arm64), so it runs natively whether you're running Docker on Windows, Linux, or Mac.

### Run FVS from the command line

To run a keyfile in your current working directory with the `usfs-fvs` image, you do a volume mount of your working directory into the Docker container (`-v "$PWD:/data"`) and then call the FVS variant of your choice as a command line tool (`FVSak --keywordfile=mykeyfile.key`):

```bash
docker run --rm \
  -v "$PWD:/data" \
  ghcr.io/vibrant-planet-open-science/usfs-fvs:latest \
  FVSak --keywordfile=mykeyfile.key
```

The `fvs-workspace` image carries the same executables. With it, add `-w /data` (its working directory is the GUI user's home) and `--user "$(id -u):$(id -g)"`, since it otherwise runs as uid 1000, which may not be able to write to your directory.

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

## Build FVS with reusable GitHub workflows

Five reusable `workflow_call` workflows build the native binaries (one each for Linux, macOS and Windows), the runtime image (the binaries alone in a container), and the FVS workspace image (the FVS GUI, the executables, and the `rFVS` and `fvs2py` packages that load FVS through its shared libraries).

### Supported FVS versions

The workflows build from `USDAForestService/ForestVegetationSimulator` and support release tags from **FS2026.3** on. Earlier releases include copies of the `volume/NVEL` submodule with stale gfortran `.mod` files, which break the build. Upstream tags use `YYYY.N.P` from `2027.1.0`, which is the default ref and the one CI tests.

### Calling the workflows

Call a workflow from a job with `uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/<file>@<tag>`, pinned to a release tag. Each native workflow uploads one bundle per platform: the executable and shared library for each variant, provenance, and an SPDX SBOM. [`docs/workflow-interface.md`](docs/workflow-interface.md) has every input, output and bundle layout, an example of [one native build](docs/workflow-interface.md#calling-the-workflow), and one of [a native build feeding a container image](docs/workflow-interface.md#composing-native--container).

Each workflow also has a manual `dispatch-*.yml` driver, used for testing; the command to run each one is in its section of `workflow-interface.md`.

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

- `meson.build`, `meson_options.txt` and `tools/parse_sourcelist.py`: the Meson build, which reads each variant's `bin/FVS<v>_sourceList.txt` from the FVS source tree and defines its executable and shared library.
- `.github/workflows/`: the reusable `build-*.yml` workflows, their `dispatch-*.yml` drivers, PR CI and release-please.
- `tools/ci/`: the scripts those workflows run, from resolving the variant list through configure, smoke tests and artifact checks to assembling the bundle and its provenance.
- `docker/`: `Dockerfile.runtime` (`usfs-fvs`) and `Dockerfile.fvs-workspace`, with the workspace image's launch shim and proxy package under `docker/fvs-workspace/`.
- `docs/`: [`workflow-interface.md`](docs/workflow-interface.md) (the contract for callers), [`local-builds.md`](docs/local-builds.md) (running Meson by hand) and [`fvs-workspace-container.md`](docs/fvs-workspace-container.md) (maintainer notes for the workspace image).
- `release-please-config.json`, `.release-please-manifest.json` and `.github/dependabot.yml`: releases (see [Releases](#releases)) and dependency updates.
