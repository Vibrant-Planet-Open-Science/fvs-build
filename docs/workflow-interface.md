# Workflow interface

`fvs-build` exposes its build machinery as reusable GitHub Actions workflows callable via `workflow_call`. This document describes the public interface — inputs, outputs, and the artifact contract — that callers depend on.

The interface is **source-agnostic**: callers supply a source repo URL plus a commit ref, and the workflows produce the corresponding native artifacts.

## Workflows


| File                                                                                                  | Purpose                                                                                    | Caller surface      | Status    |
| ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------- | --------- |
| `[.github/workflows/build-native-linux.yml](../.github/workflows/build-native-linux.yml)`             | Native Linux x86_64 binaries + provenance + SBOM                                           | `workflow_call`     | available |
| `[.github/workflows/build-container-linux.yml](../.github/workflows/build-container-linux.yml)`       | Linux container image (Ubuntu 24.04 runtime) packaging the native binaries, pushed to GHCR | `workflow_call`     | available |
| `[.github/workflows/dispatch-native-linux.yml](../.github/workflows/dispatch-native-linux.yml)`       | Manual driver around `build-native-linux.yml` for local validation                         | `workflow_dispatch` | available |
| `[.github/workflows/dispatch-native-windows.yml](../.github/workflows/dispatch-native-windows.yml)` | Manual driver around `build-native-windows.yml` for local validation                       | `workflow_dispatch` | available |
| `[.github/workflows/dispatch-native-macos.yml](../.github/workflows/dispatch-native-macos.yml)`     | Manual driver around `build-native-macos.yml` for local validation                         | `workflow_dispatch` | available |
| `[.github/workflows/dispatch-container-linux.yml](../.github/workflows/dispatch-container-linux.yml)` | Manual orchestrator running native + container in sequence                                 | `workflow_dispatch` | available |
| `[.github/workflows/build-native-windows.yml](../.github/workflows/build-native-windows.yml)`       | Native Windows x86_64 (MSYS2 MINGW64) binaries + provenance + SBOM                       | `workflow_call`     | available |
| `[.github/workflows/build-native-macos.yml](../.github/workflows/build-native-macos.yml)`           | Native macOS (Homebrew `gcc@N`) binaries + provenance + SBOM                               | `workflow_call`     | available |
| Upstream-tracking automation                                                                          | Cron-driven detection of new USFS releases plus pruning of evicted images                  | scheduled           | planned   |


## Native bundles (Linux, Windows, macOS)

Three reusable workflows share the same job shape (preflight → per-variant matrix → collect) and the same provenance tool, [`tools/ci/provenance.py`](../tools/ci/provenance.py). Workflows set **`FVS_NATIVE_PLATFORM`** for `write-build-info` and `collect-bundle` so bundle filenames and SBOM paths match the OS:

| OS      | Workflow                 | `FVS_NATIVE_PLATFORM` | Uploaded bundle name              | Executable at bundle root | Shared library at bundle root | SBOM relative path                          |
| ------- | ------------------------ | --------------------- | --------------------------------- | ------------------------- | ----------------------------- | ------------------------------------------- |
| Linux   | `build-native-linux.yml` | `linux`               | `fvs-native-linux-<run_id>`     | `FVS<v>`                  | `libFVS<v>.so`                | `sbom/fvs-native-linux.spdx.json`           |
| Windows | `build-native-windows.yml` | `windows`           | `fvs-native-windows-<run_id>`   | `FVS<v>.exe`              | `libFVS<v>.dll`               | `sbom/fvs-native-windows.spdx.json`         |
| macOS   | `build-native-macos.yml` | `darwin`              | `fvs-native-macos-<run_id>`     | `FVS<v>`                  | `libFVS<v>.dylib`             | `sbom/fvs-native-macos.spdx.json`           |

`provenance/manifest.json` and each `provenance/per-variant/FVS<v>.json` use the **`binary`** and **`shared_library`** basenames from this table (including extensions on Windows). The manifest’s `toolchain.gfortran_package` and `toolchain.gpp_package` fields are **human-readable labels** (apt names on Linux, MSYS2 pacman package names on Windows, `gcc@N` on macOS), not a portable schema across OSes.

During the matrix → collect handoff, each workflow uploads **ephemeral** per-variant artifacts named **`linux-variant-<v>`**, **`macos-variant-<v>`**, or **`windows-variant-<v>`** (not plain `variant-<v>`). That avoids GitHub Actions artifact **name collisions** when a caller runs the Linux, macOS, and Windows reusable workflows in the **same** workflow run — for example `[ci-test-reusable-native.yml](../.github/workflows/ci-test-reusable-native.yml)`. Without the prefix, the last OS to upload `variant-ak` would win and the Linux collect job could unzip macOS outputs (e.g. `libFVSak.dylib` instead of `.so`). The final bundle artifact names (`fvs-native-*-<run_id>`) are unchanged.

The Linux container workflow consumes **only** the Linux bundle; Windows and macOS bundles are for native delivery on those platforms.

### Shared native CI helpers

The three `build-native-*.yml` workflows share the same overall shape; repeated steps are centralized so the YAML stays short and changes stay in one place:

| Location | Role |
| -------- | ---- |
| [`tools/ci/expand_variants_matrix.py`](../tools/ci/expand_variants_matrix.py) | Preflight: expand the `variants` CSV into the JSON matrix for `strategy.matrix`. |
| [`.github/actions/prepare-fvs-native-checkout/action.yml`](../.github/actions/prepare-fvs-native-checkout/action.yml) | Matrix jobs: resolve the overlay repo/ref, check out `fvs-build/` and `fvs-source/`, delete stray `*.mod` under `fvs-source`, emit `source_sha` and `fvs_build_sha` outputs. |
| [`tools/ci/meson_configure_native.sh`](../tools/ci/meson_configure_native.sh) | Matrix jobs: `meson setup` / `--reconfigure` with `profile` and fail-fast validation. |
| [`tools/ci/stage_variant_native.py`](../tools/ci/stage_variant_native.py) | After compile: populate `staging/<variant>/`, tail `meson-log.txt`, invoke `provenance.py` (`extract-fortran-args`, `write-build-info`). |
| [`.github/actions/collect-native-bundle/action.yml`](../.github/actions/collect-native-bundle/action.yml) | Collect job: download OS-prefixed `*-variant-*` artifacts, run `provenance.py collect-bundle`, Syft SBOM, upload the final bundle. |
| [`.github/actions/resolve-fvs-build-ref`](../.github/actions/resolve-fvs-build-ref/action.yml) | Parse `github.workflow_ref` into overlay `owner/name` + ref (used by native matrix/collect steps and by `build-container-linux.yml`). |

## `build-native-linux.yml`

Builds Linux x86_64 native binaries for one or more FVS variants from any source repo + ref using the `fvs-build` [Meson overlay](../meson.build), and uploads a single artifact bundle containing every variant's binary plus aggregated provenance and an SBOM.

Jobs that need the overlay resolve `owner/name` and git ref from `[github.workflow_ref](https://docs.github.com/en/actions/learn-github-actions/contexts#github-context)` (the invoked reusable workflow file) via the shared `[.github/actions/resolve-fvs-build-ref](../.github/actions/resolve-fvs-build-ref/action.yml)` composite action, then check out this repository before cloning FVS source.

### Inputs


| Input                | Type   | Required | Default                                                             | Description                                                                                                                                                                                                                               |
| -------------------- | ------ | -------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_repo`        | string | yes      | —                                                                   | Source repo containing FVS code, in `owner/name` form (e.g. `USDAForestService/ForestVegetationSimulator`, `Vibrant-Planet-Open-Science/fvs-engine`).                                                                                     |
| `source_ref`         | string | yes      | —                                                                   | Tag, branch, or SHA in `source_repo` to build from.                                                                                                                                                                                       |
| `variants`           | string | no       | `ak,bm,ca,ci,cr,cs,ec,em,ie,kt,ls,nc,ne,oc,op,pn,sn,so,tt,ut,wc,ws` | Comma-separated FVS variant codes. Default is the 22 cleanly-buildable US variants. The Canadian variants (`bc`, `on`) are excluded by default; their upstream source lists are incomplete (see `[README.md](../README.md)` for details). |
| `runner_image`       | string | no       | `ubuntu-24.04`                                                      | GitHub-hosted runner image label. Pinned to keep the glibc baseline stable and matched to the Ubuntu 24.04 runtime container base.                                                                                                        |
| `gfortran_package`   | string | no       | `gfortran-13`                                                       | apt package providing gfortran. Pinned so Ubuntu point releases cannot shift the default compiler.                                                                                                                                          |
| `gpp_package`        | string | no       | `g++-13`                                                            | apt package providing g++. A handful of variants compile `.cpp` files (`fire/cfim/cfim.cpp`); the C++ compiler is pinned to the same gcc family as gfortran.                                                                                |
| `meson_version`      | string | no       | `1.5.2`                                                             | Exact Meson version installed via pip. Pinned to the version `fvs-build` was developed against.                                                                                                                                           |
| `profile`            | string | no       | `reference`                                                         | Build profile: `reference` (default, goldens-aligned flags matching upstream `bin/makefile`) or `debug` (paranoid runtime checks for regression testing; not goldens-compatible). Both use `--buildtype=plain`.                          |
| `python_version`     | string | no       | `3.12`                                                              | Version string for `actions/setup-python` (matrix Meson / scripts and the collect job's interpreter when setup-python runs).                                                                                                         |


### Outputs


| Output          | Description                                                                                                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `artifact_name` | Name of the bundled artifact uploaded by this workflow. Exactly `fvs-native-linux-<run_id>`. The downstream container workflow consumes this name to fetch and unpack the bundle. |


### Artifact contract

The workflow uploads exactly one artifact with the canonical layout below. This layout is the public contract; downstream consumers (the container workflow, regression test runners, release-attachment scripts, fork CI) depend on these paths. The JSON under `provenance/` is assembled by `[tools/ci/provenance.py](../tools/ci/provenance.py)` (invoked from the workflows).

```
fvs-native-linux-<run_id>/
├── FVSak                 # standalone executable, +x (flat bundle root)
├── FVSbm
├── ...                   # one `FVS<v>` per requested variant
├── libFVSak.so           # shared library; consumed by microfvs, rFVS, fvs2py
├── libFVSbm.so
├── ...                   # one `libFVS<v>.so` per requested variant
├── provenance/
│   ├── manifest.json     # aggregated build provenance (top-level)
│   ├── per-variant/
│   │   ├── FVSak.json    # per-variant build-info (sha256s, timestamps, toolchain)
│   │   ├── FVSbm.json
│   │   └── ...
│   └── meson-logs/
│       ├── FVSak.meson-log.tail.txt   # last 200 KB of meson-log.txt per variant
│       └── ...
└── sbom/
    └── fvs-native-linux.spdx.json     # SPDX 2.x JSON SBOM (syft)
```

#### `provenance/manifest.json` schema

```jsonc
{
  "schema_version": 1,
  "artifact_name": "fvs-native-linux-12345",
  "build": {
    "workflow_run_id": "12345",
    "workflow_run_attempt": "1",
    "workflow_run_url": "https://github.com/<repo>/actions/runs/12345",
    "generated_at_utc": "2026-05-09T23:10:00Z",
    "variants_input": "ak,bm,...",
    "variants_built": ["ak", "bm", "..."],
    "profile": "reference",
    "buildtype": "plain"
  },
  "source":    { "repo": "...", "ref": "...", "sha": "..." },
  "fvs_build": { "repo": "...", "ref": "...", "sha": "..." },
  "toolchain": {
    "runner_image": "ubuntu-24.04",
    "gfortran_package": "gfortran-13",
    "gpp_package": "g++-13",
    "meson_pin": "1.5.2",
    "gfortran_version": "GNU Fortran (Ubuntu ...) 13.x.x",
    "gcc_version": "gcc (Ubuntu ...) 13.x.x",
    "gpp_version": "g++ (Ubuntu ...) 13.x.x",
    "ninja_version": "1.x.x",
    "meson_version": "1.5.2"
  },
  "artifacts": {
    "binaries":         ["FVSak", "FVSbm", "..."],
    "shared_libraries": ["libFVSak.so", "libFVSbm.so", "..."],
    "sbom": "sbom/fvs-native-linux.spdx.json"
  }
}
```

On **Windows**, `artifacts.binaries` use the `.exe` suffix, `artifacts.shared_libraries` use `.dll`, and `artifacts.sbom` is `sbom/fvs-native-windows.spdx.json`. On **macOS**, binaries are extensionless like Linux; `shared_libraries` use `.dylib`; `artifacts.sbom` is `sbom/fvs-native-macos.spdx.json`.

#### `provenance/per-variant/FVS<v>.json` schema

```jsonc
{
  "schema_version": 1,
  "variant": "ak",
  "binary": "FVSak",
  "shared_library": "libFVSak.so",
  "binary_sha256": "...",
  "shared_library_sha256": "...",
  "compiled_at_utc": "2026-05-09T23:00:00Z",
  "source":    { "repo": "...", "ref": "...", "sha": "..." },
  "fvs_build": { "repo": "...", "ref": "...", "sha": "..." },
  "toolchain": { /* same shape as manifest.json toolchain */ },
  "build": {
    "workflow_run_id": "12345",
    "workflow_run_attempt": "1",
    "profile": "reference",
    "buildtype": "plain",
    "fortran_args": ["-cpp", "-DCMPgcc", "..."]
  }
}
```

`build.fortran_args` is the resolved flag list from `compile_commands.json` after compile (what gfortran actually received). `build.profile` is the contract-level identifier.

The `toolchain` block is captured per variant during the matrix leg, so a future contributor extending the workflow can see exactly which compiler version produced each binary even if the matrix legs run on different runner image versions.

### Calling the workflow

A minimal caller from another repository:

```yaml
jobs:
  fvs-binaries:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2025.4c
```

Pin to a specific `fvs-build` ref (tag or SHA) for reproducible release pipelines:

```yaml
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@v0.1.0
```

Consume the produced artifact in a downstream job in the same workflow:

```yaml
jobs:
  fvs-binaries:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2025.4c

  use-binaries:
    needs: fvs-binaries
    runs-on: ubuntu-24.04
    steps:
      - uses: actions/download-artifact@v7
        with:
          name: ${{ needs.fvs-binaries.outputs.artifact_name }}
          path: fvs-bundle
      - run: |
          ls -1 fvs-bundle/FVS* fvs-bundle/libFVS*.so
          jq . fvs-bundle/provenance/manifest.json
```

Build a custom subset of variants:

```yaml
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2025.4c
      variants: pn,wc,nc
```

### Authentication

The default behavior assumes `source_repo` is public; `actions/checkout@v5` works without explicit credentials. If the source repo is private, add `secrets: inherit` to the caller's `uses:` block — see the commented hint in `[dispatch-native-linux.yml](../.github/workflows/dispatch-native-linux.yml)`.

The workflow itself only requests `contents: read`. SBOM generation requires no extra permissions; SLSA build attestation (`id-token: write`) is deferred — the in-bundle `provenance/manifest.json` plus the SPDX SBOM provide build metadata without the operational complexity of attestation right now.

### Wall-clock and concurrency

The matrix expands to 22 variants by default; on GitHub-hosted runners with default concurrency limits a full release build typically completes in less than ten minutes.

Per-variant Fortran compile time dominates. Caching the Meson build directory (`actions/cache@v5` keyed on variant + source ref + Meson scaffold hash) is enabled but mostly benefits branch/PR runs; tag-driven release builds change `source_ref` every run and miss intentionally.

### Local validation before any external caller exists

Until `fvs-engine`'s release pipeline or the upstream tracker is wired up, validate end-to-end via `[dispatch-native-linux.yml](../.github/workflows/dispatch-native-linux.yml)`:

```bash
gh workflow run dispatch-native-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c
```

The same pattern applies on **Windows** and **macOS** via [`dispatch-native-windows.yml`](../.github/workflows/dispatch-native-windows.yml) and [`dispatch-native-macos.yml`](../.github/workflows/dispatch-native-macos.yml) (substitute the workflow file name in `gh workflow run`).

This invokes the reusable workflow with the same inputs an external caller would supply.

## `build-native-windows.yml`

Reusable workflow: **Windows x86_64**, **MSYS2 `MINGW64`**, gfortran/gcc from `pacman`, Meson from **pip** (MINGW64 Python). Outputs **`fvs-native-windows-<run_id>`** with `FVS<v>.exe` and `libFVS<v>.dll`. See the workflow file for the full input list; notable inputs include `runner_image` (default `windows-latest`), `gfortran_package` / `gpp_package` (provenance labels for MSYS2 packages), `meson_version`, `python_version` (default `3.12` for `actions/setup-python`), and `variants` (same CSV default as Linux).

**Calling pattern** is the same as Linux: `uses: <owner>/fvs-build/.github/workflows/build-native-windows.yml@<ref>` with `with: source_repo`, `source_ref`, and optional `variants`.

## `build-native-macos.yml`

Reusable workflow: **macOS**, **Homebrew** `gcc@N` (default `N=14`) for `gfortran-N` / `gcc-N` / `g++-N`, **Ninja** from Homebrew, Meson from **pip**. Outputs **`fvs-native-macos-<run_id>`** with extensionless `FVS<v>` and `libFVS<v>.dylib`. Inputs include `runner_image` (default `macos-latest`), `brew_gcc_major` (must match the installed `gcc@N` formula), `meson_version`, `python_version` (default `3.12`), and `variants`.

**Calling pattern** matches Linux/Windows; consume `outputs.artifact_name` the same way.

## `build-container-linux.yml`

Packages a `build-native-linux.yml` artifact bundle into a runtime-only Ubuntu 24.04 container image and (optionally) pushes it to GHCR. The container does **not** recompile FVS — it copies the already-validated native binaries into a slim runtime image with the matching `libgfortran5` / `libquadmath0` runtime libraries. **Per-variant `STOP 20` smoke runs on the native Linux build runner** before bundling; this workflow does not re-run those binaries inside the image (see the **Validation / smoke testing** subsection later in this document).

### Inputs


| Input              | Type    | Required | Default        | Description                                                                                                                                                                      |
| ------------------ | ------- | -------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `artifact_name`    | string  | yes      | —              | Name of the bundle artifact produced by a prior `build-native-linux.yml` job in the same workflow run. Pass through the upstream job's `artifact_name` output.                   |
| `image_name`       | string  | yes      | —              | Fully-qualified image name without the tag suffix (e.g. `ghcr.io/vibrant-planet-open-science/usfs-fvs`). Caller picks the namespace.                                             |
| `image_tag`        | string  | yes      | —              | Primary tag, typically the FVS source ref (e.g. `FS2025.4c`).                                                                                                                    |
| `image_extra_tags` | string  | no       | `""`           | Comma-separated extra tags applied at push time (e.g. `latest`, `<short-sha>`). Each is `docker tag`ged from the primary and pushed alongside it.                                |
| `runtime_base`     | string  | no       | `ubuntu:24.04` | Base image for the runtime container. Pinned to `ubuntu:24.04` (same version as the Linux native build runner so glibc baselines match). |
| `runner_image`     | string  | no       | `ubuntu-24.04` | GitHub-hosted runner image label this workflow runs on.                                                                                                                          |
| `push`             | boolean | no       | `false`        | Push to the registry after the image build succeeds. Defaults to `false`; production callers explicitly opt in.                                                                  |


### Outputs


| Output         | Description                                                                                            |
| -------------- | ------------------------------------------------------------------------------------------------------ |
| `image_ref`    | Primary image reference: `<image_name>:<image_tag>`.                                                   |
| `image_digest` | Image digest (`sha256:...`). Empty when `push: false` since digests are only stable for pushed images. |


### What the workflow does

1. Self-checkout `fvs-build` at the ref implied by `github.workflow_ref` using `[.github/actions/resolve-fvs-build-ref](../.github/actions/resolve-fvs-build-ref/action.yml)` (for `[docker/Dockerfile.runtime](../docker/Dockerfile.runtime)`).
2. Download the named artifact bundle into `bundle/` and verify the layout.
3. Extract source repo/ref/sha and toolchain versions from `bundle/provenance/manifest.json` via `[tools/ci/provenance.py](../tools/ci/provenance.py)` (`manifest-to-github-env`); pass them into `docker buildx build` as `--build-arg` values which become OCI image labels.
4. `docker buildx build --load --platform linux/amd64` produces the image into the local Docker daemon (no push yet).
5. If `push: true` and `image_name` starts with `ghcr.io/`: log in to GHCR with `${{ secrets.GITHUB_TOKEN }}`, push the primary tag, then tag-and-push each `image_extra_tags` entry.
6. Generate an SPDX SBOM of the *built image* via `syft` (separate from the binary-only SBOM in the bundle — the image SBOM also captures the Ubuntu base layers and `libgfortran5`). Upload as a sibling `container-sbom-<run_id>` artifact.

### OCI labels applied to the image

Standard [OpenContainers annotations](https://github.com/opencontainers/image-spec/blob/main/annotations.md):


| Label                                    | Source                                                                           |
| ---------------------------------------- | -------------------------------------------------------------------------------- |
| `org.opencontainers.image.source`        | `https://github.com/<fvs_build_repo>` (the repo whose workflow built this image) |
| `org.opencontainers.image.revision`      | `fvs_build` SHA from manifest                                                    |
| `org.opencontainers.image.version`       | `source_ref` from manifest (the FVS version)                                     |
| `org.opencontainers.image.created`       | Build timestamp (ISO 8601 UTC)                                                   |
| `org.opencontainers.image.title`         | `usfs-fvs`                                                                       |
| `org.opencontainers.image.description`   | Project description                                                              |
| `org.opencontainers.image.documentation` | URL to this document at the build's `fvs-build` ref                              |


Plus `fvs-build`-specific labels for full source / toolchain provenance:


| Label                                    | Source                                                           |
| ---------------------------------------- | ---------------------------------------------------------------- |
| `org.vibrantplanet.fvs.source-repo`      | source repo (e.g. `USDAForestService/ForestVegetationSimulator`) |
| `org.vibrantplanet.fvs.source-ref`       | source ref (FVS tag/branch)                                      |
| `org.vibrantplanet.fvs.source-sha`       | source commit SHA                                                |
| `org.vibrantplanet.fvs.fvs-build-repo`   | this repo (e.g. `Vibrant-Planet-Open-Science/fvs-build`)         |
| `org.vibrantplanet.fvs.fvs-build-ref`    | `fvs-build` ref the workflow ran from                            |
| `org.vibrantplanet.fvs.fvs-build-sha`    | `fvs-build` commit SHA                                           |
| `org.vibrantplanet.fvs.variants`         | comma-separated 2-letter variant codes baked in                  |
| `org.vibrantplanet.fvs.gfortran-version` | exact gfortran version (first line of `gfortran --version`)      |
| `org.vibrantplanet.fvs.meson-version`    | exact Meson version                                              |


Inspect on a built image with `docker inspect <image_ref> | jq '.[0].Config.Labels'`.

### Files baked into the image


| Path                                           | Content                                                                                         |
| ---------------------------------------------- | ----------------------------------------------------------------------------------------------- |
| `/usr/local/bin/FVS<v>`                        | per-variant standalone executable, +x, on `PATH`                                                |
| `/usr/local/lib/libFVS<v>.so`                  | per-variant shared library                                                                      |
| `/usr/share/fvs-build/manifest.json`           | the bundle's top-level provenance manifest                                                      |
| `/usr/share/fvs-build/sbom-binaries.spdx.json` | the bundle's binary-only SBOM (the image-level SBOM is uploaded as a sibling workflow artifact) |


The image has no `ENTRYPOINT`. With `WORKDIR=/data` and the variant binaries on `PATH`, callers invoke FVS with its native command line:

```bash
docker run --rm -v "$PWD:/data" <image_ref> FVSak --keywordfile=mykey.key
```

Pass-through FVS options (`--stoppoint=...`, `--restart=...`, etc.) work without any wrapper interpretation; the `WORKDIR=/data` ensures relative paths in the keyfile resolve against the caller-mounted directory.

### Composing native + container (orchestrator pattern)

The two workflows hand off via a same-run artifact. A caller composes them:

```yaml
permissions:
  contents: read
  packages: write

jobs:
  native:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2025.4c

  container:
    needs: native
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-container-linux.yml@main
    with:
      artifact_name: ${{ needs.native.outputs.artifact_name }}
      image_name: ghcr.io/your-org/usfs-fvs
      image_tag: FS2025.4c
      image_extra_tags: latest
      push: true
    secrets: inherit
```

`needs: native` ensures the container build runs only after a successful native build — a failed native job short-circuits the container build before any image work runs.

### Authentication

When `push: true`, `${{ secrets.GITHUB_TOKEN }}` (auto-available in reusable workflows scoped to the workflow's permissions block) authenticates GHCR. The workflow declares `permissions: packages: write`; the caller must grant at least that. See the example above.

For non-GHCR registries the workflow's GHCR-only `docker/login-action` step is skipped (guarded by `startsWith(image_name, 'ghcr.io/')`); a fork or downstream caller would need to handle login themselves.

### Validation / smoke testing

**Native Linux matrix:** each variant binary is smoke-tested on the build runner (`</dev/null`, expect gfortran `STOP 20`) before staging and bundle collection — the same minimal pattern as local development (see `README.md`).

**Container workflow:** the image is **not** smoke-tested after `docker build`. That keeps CI fast and avoids duplicating the native gate. The tradeoff is weaker coverage for mistakes that only show up inside the runtime image (for example wrong `apt` packages in `Dockerfile.runtime` or a broken `COPY` layout). Teams that need in-image confirmation can add a separate integration job, reintroduce a targeted `docker run` check, or rely on downstream tests.

Future enhancements (porting `docker_fvs/tests/test_fvs_build.py`-style checks, keyfiles, log assertions, etc.) remain possible without changing the native contract.

### Local validation before any external caller exists

Use the orchestrator dispatch driver:

```bash
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c \
  -f image_tag=FS2025.4c \
  -f push=false
```

`push=false` (the default) builds the image without publishing. Set `-f push=true` to also push to `ghcr.io/<your-account>/fvs-upstream:FS2025.4c` once you're confident the image is ready for the registry.
