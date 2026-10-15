# Taste: what to imitate, and when to stop

## Pragmatics — when to dial it back

This is a style for code that must live and change. Don't weaponize it:

- **Don't pre-abstract.** A one-off internal helper does not need an interface.
  Add the *dispatch* seam when a second implementation actually appears (or is
  imminent). This is about polymorphism only — a single-implementation interface
  for a compile firewall, ABI boundary, or test seam is still justified (see
  "single-implementation interface" under Class design).
- **Hot paths prefer a template `Func` over `std::function`/virtual** for
  zero-overhead dispatch. (See `references/functors-callbacks.md`.) In a *measured*
  inner loop it is even fine to drop OOP entirely — raw intrinsics, free
  functions, value-semantic SIMD wrappers — provided every such kernel is paired
  with a reference-checked test and a benchmark. Performance you can't measure is
  not a reason to abandon the style. (See `$cpp-hpc-optimization`.)
- **`shared_ptr` vs `unique_ptr`:** prefer a single clear owner (`unique_ptr`,
  or a process-lifetime raw owning pointer for singletons); reach for `shared_ptr`
  only when ownership is genuinely shared.

## Exemplar libraries — good API to imitate

When unsure what a well-designed API looks like, study these. Each is a clean
demonstration of one principle:

| Library | Principle it demonstrates |
|---|---|
| **fmt** / `std::format` | type-rich, compile-time-checked format API; no unsafe varargs |
| **ranges-v3** / `std::ranges` | composable lazy adaptors over concrete containers |
| **magic_enum** | type-safe enum reflection without macros or codegen |
| **nlohmann-json** | RAII ownership and type-deduced `get<T>()` |
| **tl::expected** / `std::expected` | value-based error propagation |
| **structopt** | struct-as-API — a plain data class drives the interface |

## What not to imitate

Fine to *use*; wrong to *copy the style of*:

- **poco** — raw `new`/`delete` throughout, Java-style OOP, no value semantics.
- **rapidjson / jsoncpp** — SAX template maze / weakly-typed `Value` tree.
- **tinyxml2, legacy OpenCV C API, stb** — raw-pointer, pre-RAII style.

Qt is a different case: it is *excellent* **classic** OOP — object-tree ownership,
signals/slots, `QObject` parenting. Its `m_` members, raw `new`, and
parent-owns-child idioms are deliberate and correct *for that paradigm*. Keep
them inside Qt code; just don't carry them into value-semantic modern C++, where
this skill's conventions apply.

