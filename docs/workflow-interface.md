# GitHub Workflow Interface

`fvs-build` exposes its build machinery as reusable GitHub Actions workflows callable via `workflow_call`. This document is the public interface: inputs, outputs, and the artifact contract that callers can rely on.

The workflows are **source-agnostic**: callers supply a source repository and ref, and the workflows build it as long as it is laid out like `USDAForestService/ForestVegetationSimulator` (a `bin/FVS<v>_sourceList.txt` for each variant to build).

## Workflows

| File | Purpose | Trigger |
| --- | --- | --- |
| `.github/workflows/build-native-linux.yml` | Native Linux binaries (x86_64 or aarch64) + provenance + SBOM | `workflow_call` |
| `.github/workflows/build-native-macos.yml` | Native macOS (Homebrew `gcc@N`) binaries + provenance + SBOM | `workflow_call` |
| `.github/workflows/build-native-windows.yml` | Native Windows x86_64 (MSYS2 UCRT64) binaries + provenance + SBOM | `workflow_call` |
| `.github/workflows/build-container-linux.yml` | Multi-arch Linux runtime image packaging the native binaries | `workflow_call` |
| `.github/workflows/build-container-fvs-gui-linux.yml` | Binder-ready FVSOnLocal (`fvsOL`) GUI image built on the native `FVS<v>.so` set | `workflow_call` |
| `.github/workflows/dispatch-native-{linux,macos,windows}.yml` | Manual drivers for the native workflows | `workflow_dispatch` |
| `.github/workflows/dispatch-container-linux.yml` | Manual driver: native Linux + runtime image | `workflow_dispatch` |
| `.github/workflows/dispatch-container-fvs-gui-linux.yml` | Manual driver: native Linux + GUI image | `workflow_dispatch` |

## Native bundles (Linux, Windows, macOS)

The three native workflows build an executable and a shared library per variant and upload one bundle.

| OS | Workflow | Bundle name | Executable | Shared library | SBOM |
| --- | --- | --- | --- | --- | --- |
| Linux | `build-native-linux.yml` | `fvs-native-linux-<arch>-<run_id>` | `FVS<v>` | `FVS<v>.so` | `sbom/fvs-native-linux.spdx.json` |
| Windows | `build-native-windows.yml` | `fvs-native-windows-<run_id>` | `FVS<v>.exe` | `FVS<v>.dll` | `sbom/fvs-native-windows.spdx.json` |
| macOS | `build-native-macos.yml` | `fvs-native-macos-<run_id>` | `FVS<v>` | `FVS<v>.so` | `sbom/fvs-native-macos.spdx.json` |

On Linux, `<arch>` is `x86_64` (`ubuntu-24.04`) or `aarch64` (`ubuntu-24.04-arm`), and the build runs inside the matching `quay.io/pypa/manylinux_2_28_<arch>` container.

The executable and shared library are independent link products (upstream `bin/makefile` `%.prg` rules): the executable does not need the library beside it. Shared libraries keep the `FVS<v>` basename with no `lib` prefix, and use `.so` on macOS as well as Linux (matching upstream and R's `.Platform$dynlib.ext`). On Windows both are statically linked and import only the Universal C Runtime (Windows 10+). macOS binaries target macOS 15.0 (`MACOSX_DEPLOYMENT_TARGET`), built on the `macos-15` runner, whose Homebrew GCC targets the same release.

### GCC toolchain selection

All three native workflows take a `gcc_major` input. A major the platform cannot provide fails before compiling, and every artifact is checked to come from exactly one GCC of that major (`tools/ci/check_gcc_major.sh`).

| OS | Default | Source |
| --- | --- | --- |
| Linux | `14` | `gcc-toolset-14` in the manylinux_2_28 image; no other major. |
| macOS | `15` | Homebrew `gcc@N`, or the unversioned `gcc` formula when N is its current major. |
| Windows | `15` | The exact MSYS2 package set for N in `tools/ci/msys2-toolchains.json`. |

### Linux runtime compatibility

Linux binaries need at most glibc 2.28, on both arches: RHEL/AlmaLinux/Rocky 8+, Debian 10+, Ubuntu 18.10+, and any distribution with glibc ≥ 2.28. The build fails if an artifact needs a newer `GLIBC_` symbol version or any library outside these:

| Artifact | Needs |
| --- | --- |
| Executable `FVS<v>` | `libc.so.6`, `libm.so.6` (the GCC runtime is linked statically) |
| Shared library `FVS<v>.so` | `libc.so.6`, `libm.so.6`, `libgfortran.so.5` (from GCC 8 or newer), `libgcc_s.so.1` |

On aarch64 both also list the glibc loader `ld-linux-aarch64.so.1`.

## `build-native-linux.yml`

Builds the requested variants and uploads one bundle. `runner_image` picks the arch; there is no cross-compilation, so a caller wanting both arches calls the workflow twice. `build-native-macos.yml` and `build-native-windows.yml` take the same inputs (with `gcc_major` default `15`, and `runner_image` defaulting to `macos-15` and `windows-latest`) and produce the same bundle layout with their platform's file names.

### Inputs

| Input | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `source_repo` | string | yes | — | FVS source repo, `owner/name`. |
| `source_ref` | string | yes | — | Tag, branch, or SHA in `source_repo`. |
| `variants` | string | no | the 22 US variants | Comma-separated variant codes. `bc` and `on` are excluded: their upstream source lists are incomplete (see `README.md`). |
| `runner_image` | string | no | `ubuntu-24.04` | `ubuntu-24.04` builds x86_64; `ubuntu-24.04-arm` builds aarch64. A label containing `arm` selects the aarch64 manylinux image. |
| `gcc_major` | string | no | `14` | GCC major version (see [GCC toolchain selection](#gcc-toolchain-selection)). |
| `meson_version` | string | no | `1.12.0` | Exact Meson version installed via pip. |
| `profile` | string | no | `reference` | `reference` (goldens-aligned, matches upstream `bin/makefile`) or `debug` (runtime checks; not goldens-compatible). |
| `python_version` | string | no | `3.12` | Python for Meson and the build scripts. |

### Outputs

| Output | Description |
| --- | --- |
| `artifact_name` | `fvs-native-linux-<arch>-<run_id>`; the container workflows take it as input. |

### Bundle layout

```
fvs-native-linux-<arch>-<run_id>/
├── FVS<v>                    # standalone executable, one per variant
├── FVS<v>.so                 # shared library, one per variant, debug info stripped
├── provenance/
│   ├── manifest.json         # aggregated build provenance
│   ├── per-variant/FVS<v>.json
│   └── meson-logs/FVS<v>.meson-log.tail.txt
└── sbom/fvs-native-linux.spdx.json
```

Provenance JSON (`schema_version: 1`), written by `tools/ci/provenance.py`:

- `manifest.json`: `artifact_name`; `arch` (Python's `platform.machine()`: `x86_64`/`aarch64`, `arm64` on macOS, `AMD64` on Windows); `build` (run id/attempt/URL, timestamp, variants requested and built, `profile`, `buildtype`); `source` and `fvs_build` (`repo`, `ref`, `sha`); `toolchain` (runner image, GCC major and package names, compiler/Meson/Ninja versions); `artifacts` (`binaries`, `shared_libraries`, `sbom`).
- `per-variant/FVS<v>.json`: `variant`, `arch`, `binary` and `shared_library` with their `*_sha256` (the library's of the stripped file), `compiled_at_utc`, `source`, `fvs_build`, `toolchain`, and `build.fortran_args` (the flags gfortran received, from `compile_commands.json`).

### Calling the workflow

<!-- x-release-please-start-version -->
```yaml
jobs:
  fvs-x86_64:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@v0.7.0
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2026.3
      # variants: pn,wc,nc   # optional subset

  fvs-aarch64:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@v0.7.0
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2026.3
      runner_image: ubuntu-24.04-arm

  use-binaries:
    needs: fvs-x86_64
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@v8
        with:
          name: ${{ needs.fvs-x86_64.outputs.artifact_name }}
          path: fvs-bundle
```
<!-- x-release-please-end -->

Pin `fvs-build` to a tag or SHA for reproducible pipelines. The workflow requests only `contents: read`; for a private `source_repo`, add `secrets: inherit` to the caller's `uses:` block.

To run it by hand: `gh workflow run dispatch-native-linux.yml -f source_repo=USDAForestService/ForestVegetationSimulator -f source_ref=FS2026.3` (likewise `dispatch-native-macos.yml` and `dispatch-native-windows.yml`).

## `build-container-linux.yml`

Packages `build-native-linux.yml` bundles into a runtime-only Ubuntu 24.04 image with `libgfortran5` (plus `libquadmath0` on amd64), and optionally pushes it. It does not recompile FVS; binaries are smoke-tested on the native runner, not in the image.

### Inputs

| Input | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `artifact_name` | string | yes | — | x86_64 bundle from a `build-native-linux.yml` job in the same run. |
| `artifact_name_arm64` | string | no | `""` | aarch64 bundle; when set, the image is also built for linux/arm64. |
| `image_name` | string | yes | — | Image name without tag (e.g. `ghcr.io/vibrant-planet-open-science/usfs-fvs`). |
| `image_tag` | string | yes | — | Primary tag, typically the FVS source ref (e.g. `FS2026.3`). |
| `image_extra_tags` | string | no | `""` | Comma-separated extra tags (e.g. `latest`). |
| `runtime_base` | string | no | `ubuntu:24.04` | Runtime base image. |
| `runner_image` | string | no | `ubuntu-24.04` | Runner for the amd64 leg and the manifest job; the arm64 leg runs on `ubuntu-24.04-arm`. |
| `push` | boolean | no | `false` | Push after the build succeeds. |

### Outputs

| Output | Description |
| --- | --- |
| `image_ref` | `<image_name>:<image_tag>`. |
| `image_digest` | Digest of the multi-arch manifest list; empty when `push: false`. |

The workflow fails if a bundle's `arch` does not match its leg (`x86_64` ↔ `amd64`, `aarch64` ↔ `arm64`). It also uploads an SPDX SBOM of each built image as `container-sbom-<arch>-<run_id>`.

### Multi-arch images

Each tag points at a manifest list, so `docker pull <image_name>:<tag>` picks the host's arch (`--platform linux/arm64` to choose). There are no per-arch tags. The per-arch images appear in GHCR as **untagged** versions: **do not delete them**, by hand or by a retention policy that prunes untagged versions, or every tag breaks.

### Image contents and usage

| Path | Content |
| --- | --- |
| `/usr/local/bin/FVS<v>` | executable, on `PATH` |
| `/usr/local/lib/FVS<v>.so` | shared library |
| `/usr/share/fvs-build/manifest.json` | the bundle's provenance manifest |
| `/usr/share/fvs-build/sbom-binaries.spdx.json` | the bundle's binary SBOM |

No `ENTRYPOINT`; `WORKDIR` is `/data`:

```bash
docker run --rm -v "$PWD:/data" <image_ref> FVSak --keywordfile=mykey.key
```

### OCI labels

Standard labels: `source` (fvs-build repo URL), `revision` (fvs-build SHA), `version` (FVS source ref), `created`, `title` (`usfs-fvs`), `description`, `licenses` (`MIT AND CC0-1.0`: CC0 for the public-domain FVS sources, MIT for fvs-build), `documentation` (this file at the build's ref).

`org.vibrantplanet.fvs.*` labels: `source-repo`, `source-ref`, `source-sha`, `fvs-build-repo`, `fvs-build-ref`, `fvs-build-sha`, `variants`, `gfortran-version`, `meson-version`. Inspect with `docker inspect <image_ref> | jq '.[0].Config.Labels'`.

### Composing native + container

<!-- x-release-please-start-version -->
```yaml
permissions:
  contents: read
  packages: write

jobs:
  native:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@v0.7.0
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2026.3

  native-arm64:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@v0.7.0
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2026.3
      runner_image: ubuntu-24.04-arm

  container:
    needs: [native, native-arm64]
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-container-linux.yml@v0.7.0
    with:
      artifact_name: ${{ needs.native.outputs.artifact_name }}
      artifact_name_arm64: ${{ needs.native-arm64.outputs.artifact_name }}
      image_name: ghcr.io/your-org/usfs-fvs
      image_tag: FS2026.3
      image_extra_tags: latest
      push: true
    secrets: inherit
```
<!-- x-release-please-end -->

Pushing to GHCR uses `GITHUB_TOKEN`; the caller must grant `packages: write`. For other registries the caller handles login. Drop `native-arm64` and `artifact_name_arm64` for an amd64-only image.

To run it by hand: `gh workflow run dispatch-container-linux.yml -f source_repo=USDAForestService/ForestVegetationSimulator -f source_ref=FS2026.3 -f image_tag=FS2026.3 -f push=false` (`-f arm64=false` for amd64 only).

## `build-container-fvs-gui-linux.yml`

Builds a Binder-ready FVSOnLocal (`fvsOL`) GUI image and optionally pushes it. It reuses the `FVS<v>.so` set from `build-native-linux.yml` bundles and builds the pure-R `rFVS`/`fvsOL` layer from `ForestVegetationSimulator-Interface` on `rocker/r2u:noble`, with Jupyter and `jupyter-server-proxy` serving the app at `/fvs-gui/`. The image is smoke-tested before it is pushed. Build steps, the Local-mode patch, the smoke checks and Binder publishing are in [`fvs-gui-container.md`](fvs-gui-container.md).

### Inputs

| Input | Type | Required | Default | Description |
| --- | --- | --- | --- | --- |
| `artifact_name` | string | yes | — | x86_64 `build-native-linux.yml` bundle; only its `FVS<v>.so` set is used. |
| `artifact_name_arm64` | string | no | `""` | aarch64 bundle; when set, the image is also built for linux/arm64. |
| `interface_repo` | string | no | `USDAForestService/ForestVegetationSimulator-Interface` | Repo providing `rFVS` and `fvsOL`. |
| `interface_ref` | string | no | `FS2026.3` | Ref in `interface_repo`; must be `FS2026.3` or later. |
| `image_name` | string | yes | — | Image name without tag (e.g. `ghcr.io/vibrant-planet-open-science/usfs-fvs-gui`). |
| `image_tag` | string | yes | — | Primary tag, typically matching `interface_ref`. |
| `image_extra_tags` | string | no | `""` | Comma-separated extra tags. |
| `runner_image` | string | no | `ubuntu-24.04` | Runner for the amd64 leg and the manifest job. |
| `push` | boolean | no | `false` | Push after the build and smoke test succeed. For Binder, the GHCR package must also be public. |

### Outputs

Same as `build-container-linux.yml`: `image_ref` and `image_digest`. Multi-arch tagging works the same way, including the warning about untagged per-arch versions.

### OCI labels

The runtime image's labels (with `title` `usfs-fvs-gui`), plus `org.vibrantplanet.fvs.interface-repo`, `interface-ref` and `interface-sha` for the R layer.

To run it by hand: `gh workflow run dispatch-container-fvs-gui-linux.yml -f source_ref=FS2026.3 -f interface_ref=FS2026.3 -f image_tag=FS2026.3 -f push=false`.
