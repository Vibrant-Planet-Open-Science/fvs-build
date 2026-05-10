# fvs-build: out-of-tree Meson overlay for FVS source repos.
#
# This project does not contain FVS source. It points at a checked-out source
# tree via the `fvs_source_dir` option, parses the upstream-style per-variant
# `bin/FVS<variant>_sourceList.txt` manifests at configure time, and emits
# native binaries (executable + shared library) per requested variant.
#
# Supported hosts: Linux, macOS (darwin), Windows (e.g. MinGW-w64 / MSYS2 with
# gfortran). Flags follow USDAForestService `bin/makefile` where applicable;
# macOS shared libraries use `.dylib` (Meson default on darwin).

project(
  'fvs-build',
  ['c', 'cpp', 'fortran'],
  version: '0.1.0',
  meson_version: '>=1.1.0',
  default_options: [
    'c_std=c11',
    'cpp_std=c++14',
    'buildtype=debugoptimized',
    'warning_level=0',
  ],
)

host_sys = host_machine.system()
if host_sys != 'linux' and host_sys != 'darwin' and host_sys != 'windows'
  error(
    'fvs-build supports linux, darwin, and windows; got @0@'.format(host_sys),
  )
endif

src_dir = get_option('fvs_source_dir')
if src_dir == ''
  error('fvs_source_dir is required. Pass -Dfvs_source_dir=/abs/path/to/upstream/checkout to meson setup.')
endif

variants = get_option('variants')
if variants.length() == 0
  error('variants option is empty. Pass -Dvariants=pn (or any subset) to meson setup.')
endif

extra_fortran_flags = get_option('extra_fortran_args')

py = find_program('python3')
parser = files('tools/parse_sourcelist.py')

cc = meson.get_compiler('c')

# libm: FOFEM C code calls exp/log/pow/sqrt; SQLite3 amalgamation can also
# pull in libm symbols. Upstream's bin/makefile gets away with no explicit
# -lm because it uses gfortran as the linker for the variant binary, and
# gfortran pulls in libm transitively. Our C-only shared libraries (FVSsql,
# FVSfofem) are linked by gcc, so libm has to be explicit on Unix.
# Windows (MinGW): math is provided by the runtime; no separate libm link.
if host_sys == 'windows'
  m_dep = declare_dependency()
else
  m_dep = cc.find_library('m', required: true)
endif

# USFS bin/makefile: WIN is -DWINDOWS on Windows, -Dunix on Linux and macOS
# (fvsSQL.c and related).
if host_sys == 'windows'
  os_c_args = ['-DWINDOWS']
  # w64 link recipe: static DLL with full symbol export; static executable.
  shlib_link_args = ['-static', '-shared', '-Wl,--export-all-symbols']
  exe_link_args = ['-static']
  objs_pic = false
else
  os_c_args = ['-Dunix']
  shlib_link_args = []
  exe_link_args = []
  # Linux (l64): USFS uses -fPIC. macOS: PIC for dylib objects (departure from
  # USFS empty PIC on osx).
  objs_pic = true
endif

# Compiler flags transcribed from upstream bin/makefile. We pin them here rather
# than pulling whatever the system compiler defaults to, so a build of fvs-build
# against an upstream tag matches the upstream-built binary closely given the
# same gfortran version.
common_c_args = [
  '-DANSI',
  '-DCMPgcc',
] + os_c_args + [
  '-DSQLITE_THREADSAFE=0',
  '-DSQLITE_OMIT_LOAD_EXTENSION',
]

common_fortran_args = [
  '-cpp',
  '-DCMPgcc',
  '-DANSI',
  '-Wall',
  '-Wno-integer-division',
  # Upstream F77 uses patterns gfortran's flow analysis flags as uninitialized
  # (-Wmaybe-uninitialized); not actionable for third-party sources.
  '-Wno-maybe-uninitialized',
  '-ffpe-trap=invalid,zero,underflow,overflow,denormal',
  '-fbacktrace',
] + extra_fortran_flags

# Parses one stanza of the parser's delimited text schema. Returns a dict
# mapping section names to lists of (string) paths.
section_order = [
  'fortran_sources',
  'main_source',
  'c_sources_sql',
  'c_sources_fofem',
  'include_dirs',
  'mod_sources',
]

foreach v : variants
  parser_run = run_command(
    py, parser,
    '--source-dir', src_dir,
    '--variant', v,
    check: true,
  )

  sections = {}
  foreach s : section_order
    sections += {s: []}
  endforeach

  current = ''
  foreach raw : parser_run.stdout().split('\n')
    line = raw.strip()
    if line == ''
      continue
    endif
    if line.startswith('### ')
      current = line.substring(4)
    else
      cur_list = sections[current]
      cur_list += line
      sections += {current: cur_list}
    endif
  endforeach

  fortran_sources = sections['fortran_sources']
  main_source     = sections['main_source'][0]
  c_sources_sql   = sections['c_sources_sql']
  c_sources_fofem = sections['c_sources_fofem']
  include_dirs    = sections['include_dirs']

  # Include flags must reach both Fortran (for INCLUDE'd .F77/.inc files
  # gathered from common/, pn/common/, volume/NVEL/, etc.) and C (for
  # #include'd .h files in fire/fofem/ and dbsqlite/). We pass them via -I
  # in c_args/fortran_args rather than include_directories() because the
  # paths point outside the meson source tree (into fvs_source_dir) and
  # include_directories() is restrictive about that.
  #
  # IMPORTANT: .F77 and .inc files are not Fortran *sources* in this build;
  # they are include files brought in by Fortran INCLUDE statements. Meson's
  # default Fortran extension set (.f .for .f90 .F .F90 ...) does not cover
  # .F77, which is what we want — we only need their parent dirs on the
  # include path. Future contributor: do NOT add .F77 files to the
  # static_library sources list below.
  inc_args = []
  foreach d : include_dirs
    inc_args += '-I' + d
  endforeach

  # All-but-main objects (Fortran + C) collapsed into a single static carrier
  # (PIC on Linux and macOS; not on Windows per USFS w64). This matches the
  # topology of upstream's bin/makefile rather than upstream's
  # bin/CMakeLists.txt: there is exactly one shared library per variant.
  # The CMake split into FVSsql / FVSfofem / FVS_<v> is unworkable under a
  # strict `-Wl,--no-undefined` link policy because apisubsc.c (categorized
  # "SQL" upstream) references Fortran-defined symbols, creating a cycle
  # between FVSsql and FVS_<v>. Collapsing them also produces the "one .so per
  # variant" output the PRD describes.
  #
  # Meson auto-discovers Fortran `module`/`use` dependencies across these
  # sources (including the *_mod.f files in volume/NVEL/) and orders
  # compilation correctly without manual declarations — the headline
  # reason ADR-001 picked Meson over CMake for this codebase.
  fvs_objs = static_library(
    'fvs_' + v + '_objs',
    fortran_sources + c_sources_sql + c_sources_fofem,
    fortran_args: common_fortran_args + inc_args,
    c_args: common_c_args + inc_args,
    cpp_args: common_c_args + inc_args,
    pic: objs_pic,
    dependencies: [m_dep],
    install: false,
  )

  # Shared library: libFVS<v>.so (Linux), libFVS<v>.dylib (macOS), libFVS<v>.dll
  # (Windows). link_whole pulls in every object from the static carrier; libm
  # comes through from the static lib's deps on Unix.
  fvs_lib = shared_library(
    'FVS' + v,
    [],
    link_whole: fvs_objs,
    dependencies: [m_dep],
    link_args: shlib_link_args,
    install: false,
  )

  # FVS<v> executable (.exe on Windows). main.f is matched by basename in the
  # parser, so this works even if upstream reorders entries in the source
  # list across releases.
  executable(
    'FVS' + v,
    [main_source],
    fortran_args: common_fortran_args + inc_args,
    link_with: [fvs_lib],
    link_args: exe_link_args,
    install: false,
  )
endforeach
