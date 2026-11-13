# fvs-build: out-of-tree Meson overlay for FVS source repos (see README.md).

project(
  'fvs-build',
  ['c', 'cpp', 'fortran'],
  meson_version: '>=1.8.0',
  default_options: [
    'c_std=c11',
    'cpp_std=c++14',
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

profile = get_option('profile')
traps_opt = get_option('traps')
extra_fortran_flags = get_option('extra_fortran_args')

# aarch64 has no denormal-operand exception and libgfortran warns on every
# start when asked for one. The other four have no effect either: the arm64
# cores we build and run on do not trap in hardware.
if host_machine.cpu_family() == 'aarch64'
  profile_trap_flag = '-ffpe-trap=invalid,zero,underflow,overflow'
else
  profile_trap_flag = '-ffpe-trap=invalid,zero,underflow,overflow,denormal'
endif

if traps_opt == 'default'
  trap_flag = profile_trap_flag
elif traps_opt == 'none'
  trap_flag = ''
else
  trap_flag = '-ffpe-trap=' + traps_opt
endif

fortran_base_args = [
  '-cpp',
  '-DCMPgcc',
  '-DANSI',
  '-Wall',
  '-Wno-integer-division',
  # Upstream F77 patterns trip this; not actionable for third-party sources.
  '-Wno-maybe-uninitialized',
  '-g',
  '-fbacktrace',
  # gfortran 10+ rejects legacy FVS argument-type mismatches; this downgrades
  # them to warnings. Not -std=legacy, which would relax other checks silently.
  '-fallow-argument-mismatch',
]

if profile == 'reference'
  profile_fortran_args = []
elif profile == 'debug'
  profile_fortran_args = [
    '-O0',
    '-fcheck=all',
    '-finit-real=snan',
    '-finit-integer=-99999',
  ]
else
  error('Unknown profile @0@; expected reference or debug'.format(profile))
endif

common_fortran_args = fortran_base_args
if trap_flag != ''
  common_fortran_args += trap_flag
endif
common_fortran_args += profile_fortran_args + extra_fortran_flags

py = find_program('python3')
parser = files('tools/parse_sourcelist.py')

# base/version.f90 (MODULE FVSVERSION) reads six -DFVS_GIT_* macros. Source
# trees at or before FS2026.2 predate it and build without them.
fs = import('fs')
version_flags = []
if fs.exists(src_dir / 'base' / 'version.f90')
  info_run = run_command(
    py, files('tools/fvs_build_info.py'),
    '--source-dir', src_dir,
    check: true,
  )
  foreach line : info_run.stdout().strip().split('\n')
    version_flags += line.strip()
  endforeach
elif fs.exists(src_dir / 'base' / 'version.f')
  error(
    'This source tree has base/version.f (free-form Fortran in a .f file), which '
    + 'fvs-build does not build. Use a ref at or before FS2026.2, or at or after '
    + 'the upstream .f90 rename.',
  )
endif

cc = meson.get_compiler('c')

# The SQLite and FOFEM C archives need libm explicitly on Unix (upstream gets it
# transitively from gfortran). MinGW's runtime provides math, but with
# `-static` linking gcc does not always pull in libgfortran's libquadmath.
if host_sys == 'windows'
  m_dep = declare_dependency()
  quadmath_dep = cc.find_library('quadmath', required: true)
else
  m_dep = cc.find_library('m', required: true)
  quadmath_dep = declare_dependency()
endif

if host_sys == 'windows'
  os_c_args = ['-DWINDOWS']
  # The exe must link_whole fvs_objs, not link_with the DLL: both are static,
  # so that would duplicate Fortran runtime entry points.
  shlib_link_args = ['-static', '-shared', '-Wl,--export-all-symbols']
  exe_link_args = ['-static']
  objs_pic = false
else
  os_c_args = ['-Dunix']
  # PIC on macOS departs from upstream, which builds without it there.
  objs_pic = true
  if host_sys == 'darwin'
    # Without these the Mach-O load commands reference the build machine's
    # Homebrew libgfortran by absolute path, absent on end-user Macs. libSystem
    # cannot be static, so only the GCC runtime is.
    fortran_runtime_static = [
      '-static-libgfortran',
      '-static-libgcc',
      '-static-libquadmath',
    ]
    shlib_link_args = fortran_runtime_static
    exe_link_args = fortran_runtime_static
  else
    # Linux: the shared library links the GCC runtime dynamically, because
    # libgfortran.a is not built -fPIC and cannot go into a shared object;
    # wheels vendor it with auditwheel. The executable links it statically
    # and needs only glibc. -static-libquadmath is GCC 13+ (CI uses 14).
    shlib_link_args = []
    exe_link_args = ['-static-libgfortran', '-static-libgcc']
    if meson.get_compiler('fortran').has_link_argument('-static-libquadmath')
      exe_link_args += '-static-libquadmath'
    endif
  endif
endif

common_c_args = [
  '-DANSI',
  '-DCMPgcc',
] + os_c_args + [
  '-DSQLITE_THREADSAFE=0',
  '-DSQLITE_OMIT_LOAD_EXTENSION',
]

section_order = [
  'fortran_sources',
  'main_source',
  'c_sources_variant',
  'c_sources_sql',
  'c_sources_fofem',
  'nvel_sources',
  'include_dirs',
]

# [archive name, parser section, directory under fvs_source_dir]
common_groups = [
  ['fvs_sqlite', 'c_sources_sql', 'dbsqlite'],
  ['fvs_fofem', 'c_sources_fofem', 'fire/fofem'],
  ['fvs_nvel', 'nvel_sources', 'volume/NVEL'],
]

variant_sections = {}
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

  variant_sections += {v: sections}
endforeach

# SQLite, FOFEM and NVEL never call into FVS and upstream lists the same files
# for every variant, so they are built once from the first variant's lists.
first = variant_sections[variants[0]]
foreach v : variants
  foreach group : common_groups
    g = group[1]
    if variant_sections[v][g] != first[g]
      error(
        'Source list for @0@ differs from @1@ in @2@; fvs-build compiles '.format(v, variants[0], g)
        + 'that group once for all variants. Build these variants separately.',
      )
    endif
  endforeach
endforeach

# Only the group's own directory is on the include path, so it cannot silently
# depend on variant headers. NVEL's Fortran modules reach variant code through
# Meson's module directory for linked targets.
common_libs = []
foreach group : common_groups
  inc = ['-I' + (src_dir / group[2])]
  common_libs += static_library(
    group[0],
    first[group[1]],
    c_args: common_c_args + inc,
    fortran_args: common_fortran_args + inc,
    pic: objs_pic,
    install: false,
  )
endforeach

foreach v : variants
  sections = variant_sections[v]
  fortran_sources   = sections['fortran_sources']
  main_source       = sections['main_source'][0]
  c_sources_variant = sections['c_sources_variant']
  include_dirs      = sections['include_dirs']

  # Raw -I rather than include_directories(), which is restrictive about paths
  # outside the Meson source tree. .F77/.inc files are INCLUDE'd, never
  # compiled: do not add them to the sources below.
  inc_args = []
  foreach d : include_dirs
    inc_args += '-I' + d
  endforeach

  # Common archives merged in whole keep upstream's topology: one
  # self-contained shared library per variant, with no sibling libraries.
  fvs_objs = static_library(
    'fvs_' + v + '_objs',
    fortran_sources + c_sources_variant,
    # version_flags must stay after inc_args: provenance.py's flag extractor
    # stops at the first -I, which keeps git metadata out of build-info.json.
    fortran_args: common_fortran_args + inc_args + version_flags,
    c_args: common_c_args + inc_args,
    cpp_args: common_c_args + inc_args,
    pic: objs_pic,
    link_whole: common_libs,
    dependencies: [m_dep],
    install: false,
  )

  fvs_lib = shared_library(
    'FVS' + v,
    [],
    name_prefix: '',
    name_suffix: host_sys == 'windows' ? 'dll' : 'so',
    link_whole: fvs_objs,
    # With no sources Meson would pick the C linker, which does not understand
    # -static-libgfortran.
    link_language: 'fortran',
    dependencies: [m_dep, quadmath_dep],
    link_args: shlib_link_args,
    install: false,
  )

  fvs_exe = executable(
    'FVS' + v,
    [main_source],
    fortran_args: common_fortran_args + inc_args,
    link_whole: [fvs_objs],
    # fvs_objs' C objects would make Meson pick the C driver, which does not
    # add the libquadmath that static libgfortran.a needs.
    link_language: 'fortran',
    dependencies: [m_dep, quadmath_dep],
    link_args: exe_link_args,
    install: false,
  )

  alias_target('fvs_' + v + '_artifacts', [fvs_lib, fvs_exe])
endforeach
