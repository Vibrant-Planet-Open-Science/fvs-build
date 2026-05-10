# Workflow interface

`fvs-build` exposes its build machinery as reusable GitHub Actions workflows callable via `workflow_call`. This document describes the public interface — inputs, outputs, and the artifact contract — that callers depend on.

The interface is **source-agnostic**: callers supply a source repo URL plus a commit ref, and the workflows produce the corresponding native artifacts.

## Workflows


| File                                                                                                  | Purpose                                                                                    | Caller surface      | Status    |
| ----------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------ | ------------------- | --------- |
| `[.github/workflows/build-native-linux.yml](../.github/workflows/build-native-linux.yml)`             | Native Linux x86_64 binaries + provenance + SBOM                                           | `workflow_call`     | available |
| `[.github/workflows/build-container-linux.yml](../.github/workflows/build-container-linux.yml)`       | Linux container image (Ubuntu 24.04 runtime) packaging the native binaries, pushed to GHCR | `workflow_call`     | available |
| `[.github/workflows/dispatch-native-linux.yml](../.github/workflows/dispatch-native-linux.yml)`       | Manual driver around `build-native-linux.yml` for local validation                         | `workflow_dispatch` | available |
| `[.github/workflows/dispatch-container-linux.yml](../.github/workflows/dispatch-container-linux.yml)` | Manual orchestrator running native + container in sequence                                 | `workflow_dispatch` | available |
| Windows / macOS native workflows                                                                      | Native binary builds for Windows and macOS                                                 | `workflow_call`     | planned   |
| Upstream-tracking automation                                                                          | Cron-driven detection of new USFS releases plus pruning of evicted images                  | scheduled           | planned   |


## `build-native-linux.yml`

Builds Linux x86_64 native binaries for one or more FVS variants from any source repo + ref using the `fvs-build` [Meson overlay](../meson.build), and uploads a single artifact bundle containing every variant's binary plus aggregated provenance and an SBOM.

Jobs that need the overlay resolve `owner/name` and git ref from `[github.workflow_ref](https://docs.github.com/en/actions/learn-github-actions/contexts#github-context)` (the invoked reusable workflow file) via the shared `[.github/actions/resolve-fvs-build-ref](../.github/actions/resolve-fvs-build-ref/action.yml)` composite action, then check out this repository before cloning FVS source.

### Inputs


| Input                | Type   | Required | Default                                                             | Description                                                                                                                                                                                                                               |
| -------------------- | ------ | -------- | ------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `source_repo`        | string | yes      | —                                                                   | Source repo containing FVS code, in `owner/name` form (e.g. `USDAForestService/ForestVegetationSimulator`, `Vibrant-Planet-Open-Science/fvs-engine`).                                                                                     |
| `source_ref`         | string | yes      | —                                                                   | Tag, branch, or SHA in `source_repo` to build from.                                                                                                                                                                                       |
| `variants`           | string | no       | `ak,bm,ca,ci,cr,cs,ec,em,ie,kt,ls,nc,ne,oc,op,pn,sn,so,tt,ut,wc,ws` | Comma-separated FVS variant codes. Default is the 22 cleanly-buildable US variants. The Canadian variants (`bc`, `on`) are excluded by default; their upstream source lists are incomplete (see `[README.md](../README.md)` for details). |
| `runner_image`       | string | no       | `ubuntu-24.04`                                                      | GitHub-hosted runner image label. Pinned per ADR-001 to keep the glibc baseline stable and matched to the Ubuntu 24.04 runtime container base.                                                                                            |
| `gfortran_package`   | string | no       | `gfortran-13`                                                       | apt package providing gfortran. Pinned per ADR-001 so Ubuntu point releases cannot shift the default compiler.                                                                                                                            |
| `gpp_package`        | string | no       | `g++-13`                                                            | apt package providing g. ++A handful of variants compile++ `.cpp` ++files (`fire/cfim/cfim.cpp`); the C++ compiler is pinned to the same gcc family as gfortran.                                                                          |
| `meson_version`      | string | no       | `1.5.2`                                                             | Exact Meson version installed via pip. Pinned to the version `fvs-build` was developed against.                                                                                                                                           |
| `extra_fortran_args` | string | no       | `""`                                                                | Comma-separated extra flags appended to common Fortran compile args (passed verbatim through Meson's `-Dextra_fortran_args=`). Escape hatch for ad-hoc build investigation; production builds should leave this empty.                    |


### Outputs


| Output          | Description                                                                                                                                                                       |
| --------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `artifact_name` | Name of the bundled artifact uploaded by this workflow. Exactly `fvs-native-linux-<run_id>`. The downstream container workflow consumes this name to fetch and unpack the bundle. |


### Artifact contract

The workflow uploads exactly one artifact with the canonical layout below. This layout is the public contract; downstream consumers (the container workflow, regression test runners, release-attachment scripts, fork CI) depend on these paths. The JSON under `provenance/` is assembled by `[tools/ci/provenance.py](../tools/ci/provenance.py)` (invoked from the workflows).

```
fvs-native-linux-<run_id>/
├── bin/
│   ├── FVSak             # standalone executable, +x
│   ├── FVSbm
│   └── ...               # one per requested variant
├── lib/
│   ├── libFVSak.so       # shared library; consumed by microfvs, rFVS, fvs2py
│   ├── libFVSbm.so
│   └── ...               # one per requested variant
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
    "variants_built": ["ak", "bm", "..."]
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
    "workflow_run_attempt": "1"
  }
}
```

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
          ls fvs-bundle/bin/
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

The workflow itself only requests `contents: read`. SBOM generation requires no extra permissions; SLSA build attestation (`id-token: write`) is deferred — the in-bundle `provenance/manifest.json` plus the SPDX SBOM satisfy PRD section 2's "build metadata" requirement for Phase 1 without taking on the operational complexity of attestation right now.

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

This invokes the reusable workflow with the same inputs an external caller would supply.

## `build-container-linux.yml`

Packages a `build-native-linux.yml` artifact bundle into a runtime-only Ubuntu 24.04 container image and (optionally) pushes it to GHCR. Per [ADR-001's "container build approach"](adr-001-build-system-build-environment-and-artifact-formats.md), the container does **not** recompile FVS — it copies the already-validated native binaries into a slim runtime image with the matching `libgfortran5` / `libquadmath0` runtime libraries.

### Inputs


| Input              | Type    | Required | Default        | Description                                                                                                                                                                      |
| ------------------ | ------- | -------- | -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `artifact_name`    | string  | yes      | —              | Name of the bundle artifact produced by a prior `build-native-linux.yml` job in the same workflow run. Pass through the upstream job's `artifact_name` output.                   |
| `image_name`       | string  | yes      | —              | Fully-qualified image name without the tag suffix (e.g. `ghcr.io/vibrant-planet-open-science/usfs-fvs`). Caller picks the namespace.                                             |
| `image_tag`        | string  | yes      | —              | Primary tag, typically the FVS source ref (e.g. `FS2025.4c`).                                                                                                                    |
| `image_extra_tags` | string  | no       | `""`           | Comma-separated extra tags applied at push time (e.g. `latest`, `<short-sha>`). Each is `docker tag`ged from the primary and pushed alongside it.                                |
| `runtime_base`     | string  | no       | `ubuntu:24.04` | Base image for the runtime container. Pinned per ADR-001's matched-base decision (same Ubuntu version as `runner_image`'s `ubuntu-24.04` build runner so glibc baselines match). |
| `runner_image`     | string  | no       | `ubuntu-24.04` | GitHub-hosted runner image label this workflow runs on.                                                                                                                          |
| `push`             | boolean | no       | `false`        | Push to the registry after smoke tests pass. Defaults to `false`; production callers explicitly opt in.                                                                          |


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
5. Per-variant in-image smoke test: for each `FVS<v>` listed in `manifest.json`'s `artifacts.binaries`, run the variant binary as the image's default command (the image has no `ENTRYPOINT` shim) with `</dev/null` and assert the output reaches gfortran's `STOP 20`. This validates that the binary loads inside the runtime image and `libgfortran5` is correctly installed; it mirrors the per-variant smoke from `build-native-linux.yml`'s build runner.
6. If `push: true` and `image_name` starts with `ghcr.io/`: log in to GHCR with `${{ secrets.GITHUB_TOKEN }}`, push the primary tag, then tag-and-push each `image_extra_tags` entry.
7. Generate an SPDX SBOM of the *built image* via `syft` (separate from the binary-only SBOM in the bundle — the image SBOM also captures the Ubuntu base layers and `libgfortran5`). Upload as a sibling `container-sbom-<run_id>` artifact.

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

`needs: native` enforces ADR-001's "container build depends on native build success" rule via GitHub's job-dependency machinery — a failed native build short-circuits the container build before any image work runs.

### Authentication

When `push: true`, `${{ secrets.GITHUB_TOKEN }}` (auto-available in reusable workflows scoped to the workflow's permissions block) authenticates GHCR. The workflow declares `permissions: packages: write`; the caller must grant at least that. See the example above.

For non-GHCR registries the workflow's GHCR-only `docker/login-action` step is skipped (guarded by `startsWith(image_name, 'ghcr.io/')`); a fork or downstream caller would need to handle login themselves.

### Smoke-test scope

Phase 1 smoke is intentionally minimal: per-variant binary-load + `STOP 20` reach. Future enhancements (porting `docker_fvs/tests/test_fvs_build.py`'s pytest harness with per-variant keyfiles, asserting no `WARNING:`/`ERROR:` in output, etc.) are tracked as follow-ups; the current scope catches missing-runtime-library and broken-image regressions cheaply, in seconds per variant.

### Local validation before any external caller exists

Use the orchestrator dispatch driver:

```bash
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c \
  -f image_tag=FS2025.4c \
  -f push=false
```

`push=false` (the default) builds and smoke-tests without publishing. Set `-f push=true` to also push to `ghcr.io/<your-account>/fvs-upstream:FS2025.4c` once you're confident the image is ready for the registry.
