# fvs-build

Reusable build machinery for the Forest Vegetation Simulator (FVS).

`fvs-build` provides a thin Meson overlay that compiles FVS native binaries (executables and shared libraries) from any source repository following the upstream USDA Forest Service layout. It is **source-agnostic**: callers point `fvs-build` at a checked-out source tree (e.g., a tag of `USDAForestService/ForestVegetationSimulator`) and a set of variant codes, and Meson produces the corresponding native artifacts.

This repo covers **Linux** (`ubuntu-24.04`), **Windows** (MSYS2 MINGW64), and **macOS** (Homebrew `gcc@N`) native bundles via reusable workflows; see [`docs/workflow-interface.md`](docs/workflow-interface.md). The Meson overlay configures on all three hosts locally as well.

## What's in here

- `[meson.build](meson.build)` — the overlay project. Reads options, parses the upstream `bin/FVS<variant>_sourceList.txt` manifests at configure time, and emits per-variant build targets.
- `[meson_options.txt](meson_options.txt)` — build-time options (`fvs_source_dir`, `variants`, `extra_fortran_args`).
- `[tools/parse_sourcelist.py](tools/parse_sourcelist.py)` — stdlib-only Python helper that turns one source list into the categorized file lists Meson consumes. Invoked once per variant via `run_command()`.
- `[.github/workflows/build-native-linux.yml](.github/workflows/build-native-linux.yml)`, `[.github/workflows/build-native-windows.yml](.github/workflows/build-native-windows.yml)`, `[.github/workflows/build-native-macos.yml](.github/workflows/build-native-macos.yml)` — reusable `workflow_call` workflows that wrap the Meson overlay per OS. Each produces a per-run artifact bundle (binaries + provenance + SBOM); see `[docs/workflow-interface.md](docs/workflow-interface.md)`.
- `[.github/workflows/build-container-linux.yml](.github/workflows/build-container-linux.yml)` — reusable `workflow_call` workflow that packages the native binaries into a runtime-only Ubuntu 24.04 container image (no recompile inside Docker per ADR-001), with optional GHCR push.
- `[.github/workflows/dispatch-native-linux.yml](.github/workflows/dispatch-native-linux.yml)`, `[.github/workflows/dispatch-native-windows.yml](.github/workflows/dispatch-native-windows.yml)`, `[.github/workflows/dispatch-native-macos.yml](.github/workflows/dispatch-native-macos.yml)` — manual drivers for each native OS workflow (`workflow_dispatch`).
- `[.github/workflows/dispatch-container-linux.yml](.github/workflows/dispatch-container-linux.yml)` — manual orchestrator running native + container in sequence.
- `[docker/Dockerfile.runtime](docker/Dockerfile.runtime)` — runtime image definition (Ubuntu 24.04 + `libgfortran5` + the variant binaries; no entrypoint shim, native FVS CLI invocation).
- `[.pre-commit-config.yaml](.pre-commit-config.yaml)`, `[ruff.toml](ruff.toml)`, `[.yamllint](.yamllint)`, `[.hadolint.yaml](.hadolint.yaml)`, `[.github/workflows/lint.yml](.github/workflows/lint.yml)` — repo-wide lint configuration enforced both locally (via `pre-commit`) and in CI.

## Local-dev quickstart

### Prerequisites

- Linux x86_64
- `gfortran` and `gcc` (Phase 1 pins to `gfortran-13` at the workflow level;
any reasonably recent gfortran works for local-dev experimentation)
- `meson >= 1.1`, `ninja`
- `python3` (stdlib only — no third-party packages)

### Configure and build a single variant

```bash
# Get a source tree to build against. Any tag works.
git clone https://github.com/USDAForestService/ForestVegetationSimulator /tmp/fvs-source

# Configure the build. fvs_source_dir is required; variants defaults to ['pn'].
cd /path/to/fvs-build
meson setup builddir -Dfvs_source_dir=/tmp/fvs-source -Dvariants=pn

# Compile. The first build is ~10 minutes for one variant on a workstation;
# subsequent incremental rebuilds are seconds.
meson compile -C builddir

# Verify outputs.
test -x builddir/FVSpn          # executable
test -f builddir/libFVSpn.so    # shared library

# Smoke run — prints the variant banner, prompts for keyword file,
# stops with exit 20 when stdin is empty (this is upstream behavior).
# Run from a scratch directory; see "fort.<N> artifacts" below for why.
mkdir -p /tmp/fvs-smoke && cd /tmp/fvs-smoke
/path/to/fvs-build/builddir/FVSpn < /dev/null
```

### `fort.<N>` artifacts after a run

When a Fortran program does I/O on a unit number that hasn't been explicitly `OPEN`ed, gfortran creates a file named `fort.<unit>` in the current working directory. FVS reads keyword input from unit 15 and writes a run summary to unit 16, so a smoke run via `./builddir/FVSpn </dev/null` from the repo root leaves `fort.15` and `fort.16` next to `meson.build`. They are harmless, empty-or-near-empty, and matched by the `fort.*` line in `.gitignore`, but the cleanest pattern is to run FVS from a throwaway directory (as in the quickstart above) so the build tree stays tidy.

### Cleaning up

```bash
# Drop built objects and binaries; keep the configure state (options,
# detected toolchain) so the next `meson compile` skips setup.
meson compile --clean -C builddir

# Or nuke everything and re-run `meson setup` from scratch. Use this when
# you want to change build options materially or clear the configure cache.
rm -rf builddir
```

### Building multiple variants

A few representative variants:

```bash
meson setup builddir \
  -Dfvs_source_dir=/tmp/fvs-source \
  -Dvariants=pn,nc,wc
meson compile -C builddir
```

The full set of US variants that build cleanly today (22 of them):

```bash
meson setup builddir \
  -Dfvs_source_dir=/tmp/fvs-source \
  -Dvariants=ak,bm,ca,ci,cr,cs,ec,em,ie,kt,ls,nc,ne,oc,op,pn,sn,so,tt,ut,wc,ws
meson compile -C builddir
```

Wall-clock for the full 22-variant build is ~5–10 min on a modern workstation
(15k+ compile units across the matrix; Ninja parallelizes them aggressively).

### Reconfiguring options

```bash
meson configure builddir -Dvariants=pn,nc
meson compile -C builddir
```

## Variant matrix

All 24 upstream variants are addressable by their two-letter codes. Source
lists for every variant — including the Canadian ones — live in `bin/` in
the upstream tree.


| Code | Region                                      | Status                                         |
| ---- | ------------------------------------------- | ---------------------------------------------- |
| `ak` | Alaska                                      | builds + smoke-tests cleanly                   |
| `bc` | British Columbia (Canada)                   | upstream source list incomplete (see below)    |
| `bm` | Blue Mountains                              | builds + smoke-tests cleanly                   |
| `ca` | Inland California / Southern Cascades       | builds + smoke-tests cleanly                   |
| `ci` | Central Idaho                               | builds + smoke-tests cleanly                   |
| `cr` | Central Rockies                             | builds + smoke-tests cleanly                   |
| `cs` | Central States                              | builds + smoke-tests cleanly                   |
| `ec` | East Cascades                               | builds + smoke-tests cleanly                   |
| `em` | Eastern Montana                             | builds + smoke-tests cleanly                   |
| `ie` | Inland Empire                               | builds + smoke-tests cleanly                   |
| `kt` | Klamath / Tetons                            | builds + smoke-tests cleanly                   |
| `ls` | Lake States                                 | builds + smoke-tests cleanly                   |
| `nc` | Inland California (North-Central)           | builds + smoke-tests cleanly                   |
| `ne` | Northeast                                   | builds + smoke-tests cleanly                   |
| `oc` | Oregon Coast                                | builds + smoke-tests cleanly                   |
| `on` | Ontario (Canada)                            | upstream source list incomplete (see below)    |
| `op` | Olympic Peninsula                           | builds + smoke-tests cleanly                   |
| `pn` | Pacific Northwest                           | builds + smoke-tests cleanly (default variant) |
| `sn` | Southern                                    | builds + smoke-tests cleanly                   |
| `so` | South-Central Oregon / Northeast California | builds + smoke-tests cleanly                   |
| `tt` | Tetons                                      | builds + smoke-tests cleanly                   |
| `ut` | Utah                                        | builds + smoke-tests cleanly                   |
| `wc` | West Cascades                               | builds + smoke-tests cleanly                   |
| `ws` | West Sierras                                | builds + smoke-tests cleanly                   |


### Known upstream issue: `bc` and `on` source lists are incomplete

`bin/FVSbc_sourceList.txt` and `bin/FVSon_sourceList.txt` reference Fortran routines (`dbs_fiavbc_cutlst`, `dbs_fiavbc_atrtls`, `dbs_fiavbc_trls`, `dbsreference`) from `vbase/cuts.f` and `base/fvs.f` but do not include the files that **define** those routines — `dbsqlite/dbs_fiavbc_*.f` and `vdbsqlite/dbsreference.f`, all of which are present in the `pn`/`nc`/etc. source lists. The result is undefined-symbol errors at the final shared-library link step:

```
undefined reference to `dbs_fiavbc_cutlst_'
undefined reference to `dbsreference_'
```

This is a source-list completeness bug in upstream `USDAForestService/ForestVegetationSimulator`, not an issue in this overlay. This repo deliberately does **not** carry source patches; the fix belongs in upstream. Until it lands, omit `bc` and `on` from the `variants` option.

There is also a separate `canada/bin/FVSon_sourceList.txt` in the upstream tree (a shorter list, ~520 lines vs. the canonical ~700-line `bin/FVSon`), used by an internal Canada-specific build flow. The overlay does not consume it — see `tools/parse_sourcelist.py` for the canonical-source-list rationale.

## Important: source tree must be free of stale build artifacts

The overlay adds parent directories of `.F77`, `.inc`, and `.h` entries from the source list to gfortran's `-I` path so Fortran `INCLUDE` statements and C `#include` directives resolve. **gfortran's `-I` flag also searches for `.mod` files**, so any stale `.mod` files left in those directories from a prior in-place build will be picked up before the freshly-built ones — and since they may be from a different gfortran version or partial build, you get cryptic errors like:

```
f951: Fatal Error: Reading module 'charmod.mod' at line 1 column 2: Unexpected EOF
```

If your source tree was previously built in-place (the upstream `bin/makefile` does this in `bin/FVS<variant>_buildDir/`, but stray runs of `gfortran` at the source root can leave `.mod` files in subdirectories like `volume/NVEL/`), clean it before building with this overlay:

```bash
cd /path/to/fvs-source
git clean -fdx           # removes all untracked files including .mod / .o
# or, more conservatively:
find . -name '*.mod' -not -path './bin/FVS*_buildDir/*' -delete
```

A fresh `git clone` should not have this problem. The native Linux GitHub Actions workflow also deletes `*.mod` under the checked-out source tree before running Meson, since upstream can ship empty or stale module files under paths such as `volume/NVEL/`.

## How the parser categorizes source-list entries

`tools/parse_sourcelist.py` reads the upstream manifest format (newline-delimited paths relative to `bin/`, typically prefixed with `../`) and emits six sections that `meson.build` consumes:


| Section           | Contents                                                                                       |
| ----------------- | ---------------------------------------------------------------------------------------------- |
| `fortran_sources` | `.f`, `.for`, `.F` files **excluding** `main.f`                                                |
| `main_source`     | the single `main.f` for this variant (matched by basename)                                     |
| `c_sources_sql`   | `sqlite3.c`, `fvsqlite3.c`, `apisubsc.c` (categorized following upstream `bin/CMakeLists.txt`) |
| `c_sources_fofem` | other C / C++ sources (FOFEM fire-effects code)                                                |
| `include_dirs`    | deduplicated parent directories of `.F77`, `.inc`, `.h` entries                                |
| `mod_sources`     | subset of `fortran_sources` matching `*_mod.f` (informational)                                 |


Run the helper directly to inspect a variant's parsed schema:

```bash
python3 tools/parse_sourcelist.py \
  --source-dir /tmp/fvs-source \
  --variant pn
```

### Invariants worth knowing if you touch this code

- `**.F77` files are never compiled.** They are Fortran fixed-form **include** files (common blocks). Meson's default Fortran extension set does not cover `.F77`, which is exactly what we want: only their parent directories go on the include path.
- `**main.f` is identified by basename, not by source-list position.** The upstream source list places `../base/main.f` near the middle of the file, not at a fixed line. The parser walks the entire list and pulls out the single `main.f` entry by basename.
- **All paths in the parser output are absolute**, resolved against the `--source-dir` argument. Meson supports absolute paths in `static_library` source lists; we use that to avoid mutating the upstream tree.
- `**apisubsc.c` references Fortran-defined symbols.** Upstream's `bin/CMakeLists.txt` puts it in the `FVSsql` library group, but in a build that uses `-Wl,--no-undefined` (Meson's default for shared libraries) that creates a circular dependency between `libFVSsql` and `libFVS<v>`. To avoid the cycle, this overlay collapses all C and Fortran objects (other than `main.f`) into a single `libFVS<v>.so` per variant — matching the topology of upstream's `bin/makefile` and the goal of creating a single shared library per variant.

## Outputs

For variant `<v>`, `meson compile` produces in `builddir/`:

- `FVS<v>` — standalone executable (consumes `main.f` linked against the shared library; the binary callers like FVSOnLocal users run directly)
- `libFVS<v>.so` — shared library (consumed by `microfvs`, `rFVS`, `fvs2py`, and other library-mode callers)
- `libfvs_<v>_objs.a` — internal PIC static library used as the carrier between the compile pass and the two link products; not a deliverable

Build provenance metadata captured by Meson at configure time (compiler versions, linker, host machine) is in `builddir/meson-logs/`.

## Calling the workflows from CI

For CI use cases, two reusable `workflow_call` workflows wrap the Meson overlay and runtime image build with pinned `ubuntu-24.04` runner, `gfortran-13` toolchain, and `ubuntu:24.04` runtime base.

### Native binaries only

```yaml
jobs:
  fvs-binaries:
    uses: Vibrant-Planet-Open-Science/fvs-build/.github/workflows/build-native-linux.yml@main
    with:
      source_repo: USDAForestService/ForestVegetationSimulator
      source_ref: FS2025.4c
```

Produces a single artifact bundle (per-variant binaries + provenance manifest + SPDX SBOM).

### Native binaries + container image

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

The container does **not** recompile FVS — it copies the already-validated native binaries into a runtime-only Ubuntu 24.04 image with the matching `libgfortran5` runtime, smoke-tests every variant inside the image, and pushes to GHCR with full OCI provenance labels.

See `**[docs/workflow-interface.md](docs/workflow-interface.md)`** for the full input/output surface of both workflows, the artifact-bundle layout, the OCI label set baked into the image, and additional caller snippets.

### Manual / local-dev drivers

Two `workflow_dispatch` drivers exercise the reusable workflows without a real caller:

```bash
# Native binaries only
gh workflow run dispatch-native-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c

# Full native + container, dry run (no push)
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c \
  -f image_tag=FS2025.4c

# Same, but actually push to ghcr.io/<owner>/fvs-upstream:FS2025.4c
gh workflow run dispatch-container-linux.yml \
  -f source_repo=USDAForestService/ForestVegetationSimulator \
  -f source_ref=FS2025.4c \
  -f image_tag=FS2025.4c \
  -f push=true
```

## Using the container image

The image has no entrypoint shim — invoke FVS with its native command line. Each variant binary is on `PATH` and the image's `WORKDIR` is `/data`, so mounting the directory containing your keyfile makes relative paths resolve and FVS output land back in your working directory:

```bash
docker run --rm \
  -v "$PWD:/data" \
  ghcr.io/<owner>/usfs-fvs:FS2025.4c \
  FVSak --keywordfile=mykeyfile.key
```

Pass-through FVS options work without any wrapper:

```bash
docker run --rm -v "$PWD:/data" ghcr.io/<owner>/usfs-fvs:FS2025.4c \
  FVSak --keywordfile=mykey.key --stoppoint=1,2040,mykey.stop

docker run --rm -v "$PWD:/data" ghcr.io/<owner>/usfs-fvs:FS2025.4c \
  FVSak --restart=mykey.stop
```

The image can also be used as a build stage in downstream Dockerfiles to extract just the binaries you need:

```dockerfile
FROM ghcr.io/<owner>/usfs-fvs:FS2025.4c AS fvs
FROM ubuntu:24.04
COPY --from=fvs /usr/local/bin/FVSak /usr/local/bin/
COPY --from=fvs /usr/local/lib/libFVSak.so /usr/local/lib/
RUN apt-get update && apt-get install -y libgfortran5 libquadmath0 && rm -rf /var/lib/apt/lists/*
```

OCI provenance labels (`org.opencontainers.image.*` plus custom `org.vibrantplanet.fvs.*`) record the source repo, ref, SHA, toolchain versions, and variant set baked in. Inspect with:

```bash
docker inspect ghcr.io/<owner>/usfs-fvs:FS2025.4c | jq '.[0].Config.Labels'
```

## Linting

Repo-wide hygiene is enforced via `[pre-commit](https://pre-commit.com/)`. The same hooks that run in CI (`[.github/workflows/lint.yml](.github/workflows/lint.yml)`) are wired up for local commits via `[.pre-commit-config.yaml](.pre-commit-config.yaml)`:

- `[actionlint](https://github.com/rhysd/actionlint)` — workflow-aware static analysis for `.github/workflows/`, including `${{ ... }}` expression type-checking and `shellcheck` over `run:` blocks.
- `[yamllint](https://github.com/adrienverge/yamllint)` — YAML hygiene with the relaxed profile in `[.yamllint](.yamllint)`.
- `[Ruff](https://docs.astral.sh/ruff/)` (`ruff check` + `ruff format`) — Python lint and formatting per `[ruff.toml](ruff.toml)`: **88** columns everywhere (code, docstrings, comments; Black-style default), Google-style docstrings on `[tools/parse_sourcelist.py](tools/parse_sourcelist.py)`.
- `[hadolint](https://github.com/hadolint/hadolint)` (via Docker) — Dockerfile lint for `[docker/Dockerfile.runtime](docker/Dockerfile.runtime)`; ignores in `[.hadolint.yaml](.hadolint.yaml)`.
- Generic hygiene from `pre-commit-hooks`: trailing whitespace, missing trailing newlines, accidentally committed merge markers, oversized files.

To enable locally:

```bash
pip install pre-commit       # or: pipx install pre-commit
pre-commit install           # one-time, installs the git hook
pre-commit run --all-files   # run all hooks against the whole tree
```

CI is the authoritative gate — local hooks can be bypassed with `--no-verify`, but `[lint.yml](.github/workflows/lint.yml)` runs `pre-commit run --all-files` on every PR and push to `main` and will block merges on any failure.
