---
name: cpp-oop-style
description: >-
  High-quality C++ OOP coding style (archibate / parallel101 lineage) that
  overrides sloppy AI-default C++. Use this skill WHENEVER writing, editing,
  refactoring, or reviewing C++ code (.cpp / .h / .hpp / .cc / .cxx), designing
  C++ classes, interfaces, APIs, or libraries, or when the user mentions C++
  design, OOP, design patterns, dependency injection, RAII, or "clean / modern
  C++". Also use it for CMake-based C++ project setup, module targets, usage
  requirements, third-party dependency acquisition and integration, binary ABI
  compatibility, installation, packaging, and application deployment.
---

# archibate C++ OOP Style

A skill that makes you write C++ the way a senior systems engineer who loves
design patterns writes it — not the way an autocompleter does. When this skill
is loaded, it **overrides** your default C++ instincts.

## The one rule

> **"Abstract class, data class, or value type. Nothing else."**

Every type you introduce is one of these three kinds — never the muddy middle:

- **Abstract class** — *behavior only*. A pure-virtual interface with no data
  members of its own; any injected collaborators live in its concrete `…Impl`,
  not in the interface. Always has `virtual ~T() = default;`. This is the unit of
  *polymorphism and dependency injection*.
- **Data class** — *data only*. A plain `struct` with public fields, built with
  designated initializers. No business logic, no getters/setters wrapping plain
  fields. This is the unit of *value passing and configuration*.
- **Value / resource type** — a concrete, value-semantic type that either owns a
  resource (an RAII wrapper) or enforces one invariant (a strong type: `Money`,
  `EmailAddress`, a math `Vector3`, a C-handle wrapper). It has a small, total
  interface and behaves like a built-in — the *Regular* type. This is the one
  concrete-class-with-methods that earns its keep.

Reject the muddy middle that models reach for by default: a concrete class that
mixes private fields, a grab-bag of public methods, *and* a scatter of free
helper functions — neither a clean interface, nor plain data, nor a focused value
type. That shape is the single biggest tell of AI-slop C++.

So a concrete class with methods is allowed only when it is **(a)** the
implementation of an abstract class (`struct FooImpl final : Foo`, defined
in a `.cpp`, never a header), or **(b)** a value/resource type as above.
Everything else is behavior behind an interface, or data in a struct.

## What you are overriding

| AI-slop default | This skill |
|---|---|
| Free functions `dep1DoX()`, `dep2DoX()` | One abstract interface `Dep`, injected |
| Concrete class with public mutable fields + methods | Abstract class (behavior) **or** data struct (data) |
| `Dog dog; dog.doThing(globalThing);` | Inject the collaborator: `dog.doThing(dep)` |
| `void f(string n, int a, int p, int addr)` | `void f(FooConfig const &cfg)` (designated init) |
| `new T` / `delete` / `new T[]` | `make_unique` / `make_shared` / `vector<T>` |
| `int parseInt()` returning `-1` on failure | `optional<int> parseInt()` |
| `enum Mode` + `switch` dispatch | inject a strategy / functor, or a state class |
| `pair<bool, It>` / `tuple<...>` returns | named result struct |
| `const T& x`, `const T* p` | East const: `T const &x`, `T const *p` |

## Named anti-patterns (real smells this overrides)

These are the concrete shapes that mark sloppy or dated C++ — name them and
refuse them:

- **God-base interface** — one abstract class fusing *data and behavior*, with a
  pile of public mutable members (e.g. a node base every node both reads state
  from and overrides). Split it: behavior → interface, state → data struct.
- **Global object + free functions** — a global instance poked by a scatter of
  free helpers. Make it a class with a clear owner and inject it.
- **Stringly-typed API** — `setParam("mode", "fast")`, sockets/params keyed by
  string. Use `enum class`, strong types, and named fields so the compiler
  checks them. Relatedly, **fetch an abstract handle once** rather than re-passing
  a string key on every call: `auto *dev = api->getDevice("CD"); dev->play();`,
  not `api->playDevice("CD")` then `api->stopDevice("CD")`.
- **Sentinel returns** — `(size_t)-1`, `-1`, empty string, or null on failure.
  Use `optional` / `expected` or a result struct (see `references/error-handling.md`).

## The canonical shape

```cpp
// Dep.h — interface only. Pure virtual. Lives in a small header.
struct MethodConfig {
    Point position{};
    float size{};
};

struct Dep {
    virtual ~Dep() = default;
    virtual std::string someQuery() const = 0;
    virtual void someMethod(MethodConfig const &config) = 0;
};

// Animal.h
struct Animal {
    virtual ~Animal() = default;
    virtual void someInterface(Dep *dep) = 0;   // collaborator injected, not owned
};

// Dog.h — concrete impl, declared minimally, defined in .cpp
struct Dog final : Animal {
    void someInterface(Dep *dep) override;
private:
    int somePrivate{};
};

// Dog.cpp
void Dog::someInterface(Dep *dep) {
    auto answer = dep->someQuery();   // reuse, don't reimplement per concrete dep
    // ...
}

// callSite.cpp — the composition root wires concrete to abstract
auto dog = Dog{};
auto dep1 = std::make_unique<Dep1>(someOptions);
dog.someInterface(dep1.get());
```

## Naming & layout

- **No `m_` prefix, no trailing-underscore on members.** Members are bare names.
- **Trailing underscore only on a ctor/setter param that shadows a member:**
  `void setX(double x_) { x = x_; }`.
- Types `PascalCase`; methods & members `camelCase`; constants `kPascalCase`;
  `enum class : uint8_t` with explicit underlying type.
- Predicate methods read as intent: `shouldRetry()`, `canFlush()`.
- **One concept per header**, kept small. `#pragma once`, never include guards.
- **Forward-declare in headers, `#include` in the `.cpp`** to cut compile
  coupling.
- **East const everywhere:** `T const &`, `T const *` — const binds to what
  precedes it, which reads consistently right-to-left.
- **Always `struct`, never the `class` keyword** — even for encapsulated types.
  Open an explicit `private:` / `protected:` section when you need encapsulation
  (`struct Game { void play(); private: Game(); };`). The keyword carries nothing
  the access labels don't, and defaulting to `struct` keeps each type's public
  surface first and visible.
- In headers, share definitions with `inline`, never `static` (which silently
  duplicates per translation unit).

## Use `auto` wisely in local variables

For an ordinary local value, use one of two declaration forms (adding `const`
according to the next section):

```cpp
auto x = rhs;       // deduced form: the type is locally evident
Type x{rhs};        // named receiving form: the type adds missing semantics
```

Use the deduced form when the RHS names the type, the producer and its type are
evident within the same function body, or the exact type is lengthy, unnamed, or
deliberately an implementation detail:

```cpp
auto const i = std::size_t{1};
auto worker = std::make_unique<Worker>(config);
auto values = std::vector<int>(3); // `()` intentionally selects the count ctor
```

Use the named receiving form when a reader cannot recover the type from the
current function without inspecting a callee, and the type is important to the
meaning of the code:

```cpp
State const state{machine.state()};
```

The named form receives an existing expression. When supplying constructor
arguments, put the constructed type on the RHS: `auto dog = Dog{"George", 10};`.
Do not write `Type x = rhs`, `Type x(rhs)`, or an uninitialized `Type x`; those
forms can hide conversions, misuse parentheses, or leave built-in values
indeterminate. Braces make narrowing conversions ill-formed:

```cpp
std::size_t const count{fetchCount()};
// int count = fetchCount();              // implicit narrowing
// int count(fetchCount());               // implicit narrowing
int const count{static_cast<int>(fetchCount())}; // only after a range check
```

Do not optimize for silently surviving return-type changes. A named receiving
type should make narrowing API drift a compile error instead of an implicit
conversion. Braces do not require exact type equality; use strong types when
even otherwise-valid conversions must be rejected.

`auto` deduction does not preserve top-level `const` or references. In
range-for, use `auto const &` to read and `auto &` to modify; bare `auto` copies.
For maps: `for (auto const &[key, value] : map)`.

## The `const` idiom

- **Almost Always Const:** write `auto const value = makeValue();` unless the
  binding must later be reassigned or moved from. Mutation should be deliberate
  and visible at the declaration.
- **Declare every pass-by-value parameter `const`:** spell it `T const`,
  `std::span<T> const`, or `T const *const`. Top-level `const` freezes the local
  parameter binding; element or pointee constness remains a separate choice.
- **Prefer new `const` variables over of reuse:** declare new local variables
  for logically different variable instead of re-assigning existing ones. Only
  reuse when a loop or iteration involves iterative update of a same variable.
- **Mark every observation-only member function `const`.** A query may not
  mutate the object's observable value; require the same qualifier on interface
  declarations and overrides.
- **Expose read-only access with a const view:** `T const &`, `T const *`,
  `std::span<T const>`, or `std::string_view`. Return mutable access only when
  mutation is an explicit part of the API contract.
- **Leave a local non-const when ownership must move from it.** `const` blocks
  moving from move-only values and may turn an intended move into a copy; never
  return `T const` by value for the same reason.
- **Reserve `mutable` only for logical constness**, such as a cache or mutex that
  does not change the observable value. Never for hiding ordinary state changes.

## Signature clarity

Function signatures should be self-explained. An interface should convey its expected behavior from its declaration. A function should explain its purpose solely from name and types without ambiguity.

**Why:** when writing code, reading the header can explains the expected behavior for most trivial functions.

Use a name telling full story e.g. `Process::isRunning()` instead of `Process::check()`, unless the class already locks the context e.g. `OutOfOrderChecker::check()`.

Avoid ambiguious function and class names, rename them immediately once you flag one.

**Why:** a confusing interface name may confuse future agents to risk misuse them.

When there are ambiguity of generic type in argument, define and use type-rich classes `sleep(Duration const &)`, `findByName(Name const &)`.

When there are multiple argument whose order and meaning are ambiguious, use `fill(Rect const &)` and invoke with `Rect{...}`.

**Why:** saves future agent from drifting type semantics during refactor.

## Boolean expression style

Prefer the C++ alternative operator tokens `not`, `and`, and `or` in
human-written boolean expressions. They are core-language keywords with exactly
the same semantics and precedence as `!`, `&&`, and `||`, but they are harder to
miss while scanning:

```cpp
if (not isReady() or (isExpired() and canRetry())) {
    return false;
}
```

- Parenthesize mixed `and` / `or` expressions even when precedence already gives
  the intended result.
- Prefer a positive named predicate over a dense negation; introduce
  `isUnavailable()` when it communicates a recurring domain concept better than
  `not isAvailable()`.
- Keep `!=` and bitwise operators symbolic. Do not generalize this rule to
  uncommon spellings such as `not_eq`, `bitand`, or `xor`.
- This rule is for boolean expressions, not rvalue references (`T &&`) or
  declarations such as `operator&&`. Match third-party and generated code rather
  than rewriting it solely for house style.

## Prefer brace initialization

Prefer direct-list initialization (`{}`) over direct initialization (`()`) when
the two forms select the same constructor:

```cpp
struct Dog {
    explicit Dog(std::string name, std::int32_t age);
};

auto dog = Dog{"George", 10};  // NEVER: Dog dog("George", 10);
```

This is **list initialization**, not an "aggregate constructor." Aggregate
initialization is only the constructor-free data-class case such as
`Point{.x = 1, .y = 2}`. `Dog` above has a user-declared constructor and is not
an aggregate.

Use `()` when braces intentionally select an `initializer_list` overload with
different semantics. `std::vector` is the canonical example:

```cpp
auto oneValue = std::vector<std::int32_t>{3}; // one element: {3}
auto threeZeros = std::vector<std::int32_t>(3); // three elements: {0, 0, 0}

auto twoValues = std::vector<std::int32_t>{3, 42}; // {3, 42}
auto threeValues = std::vector<std::int32_t>(3, 42); // {42, 42, 42}
```

An implicit constructor permits copy-list initialization at a call site. This is
not aggregate initialization either:

```cpp
struct Dog {
    Dog(std::string const &name, int age);
};

void showDog(Dog const &dog);

showDog({"George", 10});

auto dogs = std::vector<Dog>();
dogs.push_back({"George", 10});
```

## Function size discipline

**Function discipline.** Decompose programs into named, single-responsibility
functions — don't pile logic into `main`, and don't fuse unrelated jobs (a `sum`
that also prints; let the caller decide what to do with the result). Prefer
early-return guard clauses over deep nesting, and keep each function within a
screenful — Linus's rule of thumb: ≤3 levels of nesting, ≤24 lines, ≤80 columns.

## References

You MUST proactively load these when the task touches their area:

- `references/decoupled-modules.md` — definite computation vs tacit I/O or GUI
  boundaries, interface seams, agent-operable harnesses, and integration gates.
  Load me before decomposing a new C++ project or multi-module architecture.
- `references/cmake-first-projects.md` — course-derived CMake-first directory
  layout, target kinds, usage requirements, named configuration presets, source
  discovery, third-party dependencies, and embeddable subprojects. Load me
  before creating or restructuring CMake C++ targets or dependency wiring.
- `references/dependencies/router.md` — third-party dependency router by source
  control, package metadata, graph ownership, and ABI risk. Load me first for
  vendoring, package discovery, manual library integration, binary SDKs,
  dependency diamonds, or C++ ABI mismatches; then follow the matching leaf.
- `references/deployment/router.md` — deployment router by deliverable type,
  audience, and portability scope. Load me first for installation, packaging,
  release archives, application artifacts, native installers, or Python wheels;
  then follow only the matching child routes.
- `references/debug-instrumentation.md` — discriminating state capture, mature
  logging backends, stable instrument keys, JSONL, and bounded hot-path probes.
  Load me before adding or structuring temporary diagnostic logs.
- `references/debug-harnesses.md` — minimal harnesses, application or GDB REPLs,
  durable developer surfaces, customer diagnostics, live calibration, and fast
  diagnostic builds. Load me when debugging needs controllable execution or when
  designing persistent development and support controls.
- `references/undefined-behavior.md` — UB checklist, focused constexpr probes,
  and integrated sanitizer checks. Load me before writing or reviewing
  pointer/bounds/lifetime operations, type punning, arithmetic boundaries,
  sequencing, library preconditions, or shared mutable state, and when
  investigating suspected UB.
- `references/ownership-lifetime.md` — no raw `new`, smart pointers vs `vector`,
  references vs pointers, RAII for C resources, the rule of five, dangling
  temporaries. Load me before smart pointers, or resource management design.
- `references/functors-callbacks.md` — template `Func` vs `std::function`,
  lambdas over `std::bind`, capture lifetime, closures as structs. Load me on
  function-programming context.
- `references/error-handling.md` — recoverable vs unrecoverable, `optional` /
  `expected`, `[[noreturn]]`, the result-struct / error-sink / bool+log fallbacks.
  Load me before I/O interface, business logic, error handling, or third-party error
  code wrapper.
- `references/wrapping-c-resources.md` — RAII wrappers for opaque C handles:
  move-only handle template, `error_category`, check-on-assign with
  `source_location`, builders, scope-guard binds. Load me before integrating
  third-party libraries (e.g. OpenGL, CUDA) or manage OS resources with C handles.
- `references/generics-compile-time.md` — compile-time dispatch via
  `concept`-constrained overloads (not type-switching), `if constexpr` capability
  gating, `std::variant` + `std::visit` closed-set polymorphism, perfect forwarding.
  Load me when static polymorphism could surpass dynamic polymorphism.
- `references/type-erasure.md` — subtype hiding vs non-intrusive erasure,
  choosing standard wrappers, and a C++17-compatible interface/model wrapper.
  Load me when wrapping type erased interface.
- `references/text-encoding.md` — character/code-unit types, UTF-8 storage,
  filesystem paths, and Qt/platform text boundaries. Load me when handling
  Unicode, encodings, local paths, or text across library/platform boundaries.
- `$cpp-hpc-optimization` — evidence-driven data-oriented layout, numerics,
  cache/locality, SIMD, parallelism, and hot-path polymorphism. Load it before
  designing or optimizing a high-throughput kernel or data structure; keep this
  skill's abstract boundaries on the cold/control side and dispatch into
  homogeneous data batches on the measured hot side. For hot closed-set
  polymorphism, prefer dense per-concrete-type pools such as
  `vector<Dog>` plus `vector<Cat>` over per-element base pointers or variants;
  keep any virtual dispatch at the pool/batch boundary.
- `references/sources.md` — original parallel101 material, exemplar code, and
  further-study tools. Load me when verifying provenance or rationale, or when
  looking for deeper examples behind a rule.
- `references/type-and-class-design.md` — the three kinds of type argued in full,
  class design (dispatch vs branching on a tag, implementation hiding, the
  single-implementation interface and its factory, Template Method vs Strategy,
  adapters, state as class, components and CRTP, visitor, closed-set `variant`,
  flyweight), dependency injection, type-rich data classes, duty classes, and DRY.
  Load me before designing a type, an interface, a seam between modules, or a data
  class.
- `references/cmake-and-hygiene.md` — CMake-first project structure (the target
  graph mirroring the module graph, include layout, usage requirements, presets,
  OBJECT vs STATIC, normalizing one third-party target per dependency, the delivery
  contract), the undefined-behaviour checklist, and the compiler-hygiene flag set.
  Load me before restructuring CMake targets or dependency wiring, and before
  pointer, bounds, lifetime, or arithmetic-boundary work.
- `references/conversions-and-invariants.md` — when a constructor is `explicit`,
  the cast ladder (braces, `static_cast` after a range check, `bit_cast`,
  `dynamic_cast`), integer and floating-point type choice, and `assert` versus
  validating external input, including construction as validation. Load me before
  converting between types, picking a numeric type, or placing a runtime
  assumption.
- `references/taste.md` — when to dial this style back (don't pre-abstract, hot
  paths prefer templates, `unique_ptr` by default), the exemplar libraries worth
  imitating and what each demonstrates, and the dated styles not to imitate. Load
  me when a rule above would fight the task at hand.
