# CMake and compiler hygiene

## CMake-first project structure

- **Make the target graph mirror the module graph.** Give each architectural
  module its own directory, `CMakeLists.txt`, and library target; let executable
  targets be composition roots that link those modules.
- **Keep public structure explicit.** Put exported headers under
  `include/<module>/`, implementations under `src/`, include them as
  `<module/Foo.h>`, and use the module name as the C++ namespace.
- **Attach requirements to the target that owns them.** Sources, include paths,
  definitions, options, and dependencies use `target_*`; choose `PRIVATE`,
  `PUBLIC`, or `INTERFACE` from whether consumers need the requirement.
- **Name repeated configuration profiles with CMake Presets.** When developers
  repeatedly choose among several options, build types, or toolchains, commit a
  `CMakePresets.json` so configure, build, and test use short named profiles with
  separate build trees instead of reconstructed `-D...` command lines.
- **Prefer an `OBJECT` library for an internal module folded into final products
  in one build tree.** Multiple in-tree apps, tests, or probes do not require an
  archive. Use `STATIC` or `SHARED` when the library is itself a deliberate
  archive, runtime, ABI, installation, or deployment boundary.
- **Normalize each third-party dependency to one CMake target.** Prefer an
  upstream target whether its source is vendored with `add_subdirectory` or
  discovered as an installed package. Wrap header-only trees, pkg-config data,
  legacy variables, and raw binary SDKs behind a target instead of scattering
  include paths and flags across consumers.
- **Give each logical dependency one provider and version in the final graph.**
  Resolve diamonds at the composition root; do not let two parents silently
  embed incompatible copies of the same library.
- **Choose the delivery contract before adding packaging machinery.** Public
  libraries and geek-oriented CLI tools get a textbook install target and source
  archive; end-user applications get a dedicated artifact pipeline; pybind11
  extensions are installed into a Python wheel staging tree.

Read `references/cmake-first-projects.md` before creating or restructuring a
CMake C++ project, changing module targets, or deciding dependency visibility.
For acquiring, building, finding, vendoring, or wrapping a third-party library,
or for diagnosing a binary dependency ABI mismatch, read
`references/dependencies/router.md` first.
For any install, package, release archive, portable bundle, AppImage, native
installer, or Python-extension distribution task, read
`references/deployment/router.md` first. It routes further by deliverable type
and distribution scope.


## Undefined behavior

Establish each operation's bounds, lifetime, type, arithmetic, and synchronization
preconditions before executing it. Validate external input in release builds;
passing tests or running without a crash does not prove absence of UB. Classify
behavior against the project's C++ version, distinguishing UB from unspecified
or implementation-defined behavior and compile-time errors.

## Compiler hygiene

Let the compiler enforce the style — most rules above become hard errors instead
of review comments. Build with:

```
-Wall -Wextra -Weffc++
-Werror=return-type -Werror=uninitialized
-Werror=suggest-override          # every override marked `override`
-Wzero-as-null-pointer-constant   # `nullptr`, never `0` / `NULL`
-Wold-style-cast                  # named casts only, never `(T)x`
-Werror=vla                       # `std::vector` / `std::array`, never VLAs
-Wnon-virtual-dtor -Wdelete-non-virtual-dtor
-Wconversion -Wsign-compare       # no silent narrowing
-Werror=unused-result             # don't ignore a [[nodiscard]] result
```

Add `-D_GLIBCXX_DEBUG` in development builds to catch iterator/bounds misuse at
runtime (every linked translation unit must match).

