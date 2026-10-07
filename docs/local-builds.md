# Local builds

The supported way to build FVS is the reusable workflows (see the [README](../README.md#build-fvs-with-reusable-github-workflows)). This page covers running the Meson build by hand, for working on `fvs-build` itself.

## Prerequisites

- Linux x86_64 or aarch64
- `gfortran` and `gcc` (the workflows select a GCC major with `gcc_major`; any reasonably recent gfortran works for local experimentation)
- `meson >= 1.1`, `ninja`
- `python3` (stdlib only)
- An FVS source tree at FS2026.3 or later (see [Supported FVS versions](../README.md#supported-fvs-versions))

## Configure and build

```bash
git clone --recurse-submodules --branch FS2026.3 \
  https://github.com/USDAForestService/ForestVegetationSimulator /tmp/fvs-source

# fvs_source_dir is required; variants defaults to ['pn'];
# profile defaults to reference (goldens-aligned, matches upstream bin/makefile).
cd /path/to/fvs-build
meson setup builddir --buildtype=plain \
  -Dfvs_source_dir=/tmp/fvs-source \
  -Dvariants=pn \
  -Dprofile=reference

# The first build is ~10 minutes for one variant; incremental rebuilds are seconds.
meson compile -C builddir

# Smoke run: prints the variant banner, then stops with exit 20 on empty stdin
# (upstream behavior). Run from a scratch directory: gfortran writes fort.<N>
# files to the working directory for units FVS uses without opening.
mkdir -p /tmp/fvs-smoke && cd /tmp/fvs-smoke
/path/to/fvs-build/builddir/FVSpn < /dev/null
```

`-Dvariants` takes a comma-separated list, e.g. `-Dvariants=pn,nc,wc`. The full set that builds cleanly is the 22 US variants: `ak,bm,ca,ci,cr,cs,ec,em,ie,kt,ls,nc,ne,oc,op,pn,sn,so,tt,ut,wc,ws` (~5–10 min on a modern workstation). Change options on an existing build directory with `meson configure builddir -Dvariants=pn,nc`.

To clean, `meson compile --clean -C builddir` drops objects and binaries but keeps the configure state; `rm -rf builddir` starts over.

## Outputs

For variant `<v>`, `meson compile` produces in `builddir/`:

- `FVS<v>` (`FVS<v>.exe` on Windows) — standalone CLI executable; does not load the shared library at runtime (matches upstream `bin/makefile` `%.prg` linking)
- `FVS<v>.so` (Linux and macOS) / `.dll` (Windows) — embedder shared library for PyFVS, rFVS, fvs2py (no `lib` prefix; same basename as upstream)
- `libfvs_<v>_objs.a` — internal static object carrier; not a deliverable

Toolchain and host details captured at configure time are in `builddir/meson-logs/`.

## Build profiles

| Profile | Purpose |
| ------- | ------- |
| `reference` (default) | Goldens-aligned build matching upstream `bin/makefile`: `plain` buildtype, `-g`, five-condition FPE traps (four on arm64, which has no denormal trap), no optimization. |
| `debug` | Paranoid checks for runtime debugging: adds `-O0`, `-fcheck=all`, and sentinel initialization. Not goldens-compatible. |

Local-only Meson options not exposed through workflows:

- `-Dtraps=` — override FPE traps (`default`, `none`, or a verbatim `-ffpe-trap=` value; not goldens-compatible).
- `-Dextra_fortran_args=` — additive flags for ad-hoc experiments.
