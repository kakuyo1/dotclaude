# Type and class design

## Class design

**Virtual functions are a backbone of this style — reach for them.** They do
*two* distinct jobs, and both are worth an interface:

1. **Dispatch / dependency injection** — one shared caller works across subtypes
   it doesn't know. This is what replaces *branching on a type tag*
   (`switch (getType())`, `if (type == Dog)`) to pick behavior: let the vtable
   dispatch, so adding a subtype touches no existing branch. Without it, every new
   subtype copy-pastes the shared logic and one requirement change means editing N
   files. The payoff is **open for extension, closed for modification** —
   a new subtype, even one written later by another module or plugin, slots in
   behind the interface without reopening any caller.

   ```cpp
   void feed(Animal *a) { puts("feeding"); a->speak(); puts("done"); }
   ```

2. **Implementation hiding** — the interface lives in the header, the concrete
   `…Impl` lives in the `.cpp`. This is worthwhile *even with a single
   implementation*: a compile firewall (member types and heavy/third-party
   headers stay out of your public header, callers don't recompile when the impl
   changes), a clean ABI boundary, and a ready test seam. (See
   "single-implementation interface" below.)

The only thing to avoid is the *empty* interface — a `virtual` that delivers
neither job: you already hold the concrete type, there is exactly one
implementation, and you gain no hiding, seam, or ABI benefit. That is pure
overhead. Everywhere a real seam exists — polymorphism **or** build/ABI/test —
prefer the interface.

**Escalate abstraction only as far as the duplication demands.** Lift a repeated
value to a variable, repeated logic to a function, a clump of arguments to a
struct, shared state-plus-behavior to a class, a fixed set of variants to an
`enum`, a fixed set of *types* to a `std::variant`, and an open set of behaviors
to a `virtual` interface — in that order. Don't jump to the interface when a
function would do. The real cost of copy-paste is not the typing — it is the typo
you later make in one rarely-run branch. When the type set is closed and known at
compile time, resolve it at compile time — a `variant` or `concept`-constrained
overloads (not an `if constexpr` type-switch; see
`references/generics-compile-time.md`).

**One interface, one responsibility.** Never mix concerns (e.g. IO *and*
computation) in one abstract class — it forces an N×M subclass explosion. Split
into independent interfaces and let a high-level function combine them:

```cpp
struct Inputer { virtual ~Inputer() = default; virtual std::optional<int> fetch() = 0; };
struct Reducer { virtual ~Reducer() = default; virtual int init() = 0; virtual int add(int, int) = 0; };
int reduce(Inputer *in, Reducer *r);   // 2+2 classes, unlimited combinations
```

**Template Method — public non-virtual wrapper, protected virtual `do_xxx`.**
The public method owns the contract and supplies ergonomic overloads; subclasses
override only the raw `do_xxx`. (As in `std::pmr::memory_resource`.)

```cpp
struct Converter {
    void process(std::string_view sv) { do_process(sv.data(), sv.size()); }
    void process(char const *s)       { do_process(s, std::strlen(s)); }
protected:
    virtual void do_process(char const *s, size_t n) = 0;
};
```

**Strategy vs Template Method — which to pick.** Many independent behaviors on one
object → *Strategy*: hold pointers to injected strategy interfaces (a `Character`
with separate `move` and `attack` strategies). A single behavior that needs the
object's own members → *Template Method*: the base *is* the strategy, the
`virtual` reads its own fields (a `Weapon` whose `attack` uses its `damage` /
`range`). One axis of variation that owns no state → functor; several axes, or
state-carrying behavior → strategy objects.

**Thin virtual core, fat non-virtual API.** Put only primitives behind `virtual`
(`do_read`, `do_write`, `do_seek`); build the rich convenience API
(`getline`, `flush`) as non-virtual methods on top. Few virtuals, much reuse.

**Compose, don't multiply subclasses.**
- *Adapter*: wrap an interface, return the same interface, add one capability.
  Adapters compose orthogonally instead of `N×M` subclasses.
- *State as class*: encode states as classes implementing a `State` interface,
  not `enum + switch`. Adding a state touches no existing branch.
- *Component*: a `GameObject` holds `vector<unique_ptr<Component>>`. Use dynamic
  composition for behavior, **never multiple inheritance.**
- *CRTP*: auto-implement boilerplate virtuals (`clone`, `accept`) once in a
  `template <class D> struct Impl : Base` mixin instead of per subclass.
- *Visitor / double-dispatch*: when behavior depends on two types (or you'd
  otherwise write `getType()` / `isEatable()` and switch on it), use
  `accept`/`visit` so the compiler picks the overload — don't query a type tag.
- *Closed-set variant*: a fixed, known set of types → `std::variant` + `std::visit`
  instead of a class hierarchy — value semantics, no heap or vtable. Use a
  `virtual` interface instead when the set is open. (See
  `references/generics-compile-time.md`.)
- *Flyweight*: when many objects share identical heavy data (a texture, a lookup
  table), hoist it into a separate type held by a `shared_ptr`; keep only the
  per-instance data (position, velocity) local. 1000 bullets, one shared sprite —
  not 1000 texture copies. The owner's method just *forwards* to the shared object
  (`sprite->draw(position)`) — that delegation is the *proxy* idiom.

**Interface/implementation split (header hygiene).** Put the pure-virtual
interface in a small header; keep the concrete `…Impl final` entirely in the
`.cpp`. Hand back the interface through a **factory**, so callers never see — or
`#include` — the concrete type:

```cpp
// Foo.h
struct Foo { virtual ~Foo() = default; virtual void run() = 0; };
std::unique_ptr<Foo> createFoo(FooConfig const &cfg);   // factory returns the interface
```

This is also how you select backends: define the factory once per backend
directory and let the build system link exactly one. Swapping an implementation
(real vendor SDK ↔ a fake for tests/replay) becomes a build-variable change, not
a code change — the test double is just another implementation behind the seam.

**A single-implementation interface is justified — for hiding, not dispatch.**
Even when only one `…Impl` will ever exist, the compile-firewall / ABI / test-seam
payoff of point 2 still earns the interface — the deliberate exception to "don't
over-abstract." The public header carries only the interface and a factory; the
sole `…Impl` and its heavy headers stay in the `.cpp`:

```cpp
// Widget.h — interface + factory are the whole public surface
struct Widget {
    virtual ~Widget() = default;
    virtual void draw() = 0;
};
std::unique_ptr<Widget> makeWidget(WidgetConfig const &cfg);

// Widget.cpp — the lone impl and its <heavy/thirdparty.h> are hidden here
struct WidgetImpl final : Widget {
    heavy::thirdparty::Object object;

    explicit WidgetImpl(WidgetConfig const &cfg) { /* ... */ }
    void draw() override { /* ... */ }
};

std::unique_ptr<Widget> makeWidget(WidgetConfig const &cfg) {
    return std::make_unique<WidgetImpl>(cfg);
}
```

Prefer this over classic value-semantic PIMPL since it allows a test fake or a
second backend later; plain PIMPL gives *only* the compile firewall, no seam.

**Command/callback pairs (Api / Spi).** For a subsystem with inversion of
control, split the two directions into two interfaces: an **`Api`** (the
*application programming interface* — commands you call *into* the subsystem) and
an **`Spi`** (the *service provider interface* — events the subsystem calls *back*
out to you). The owner implements the `Spi` and holds the `Api`; wire the two with
`api->setSpi(this)`.

```cpp
struct PlayerSpi {                       // you implement — called back on events
    virtual ~PlayerSpi() = default;
    virtual void onTrackEnded() = 0;
};
struct PlayerApi {                       // you call in — commands
    virtual ~PlayerApi() = default;
    virtual void setSpi(PlayerSpi *spi) = 0;
    virtual void play(Track const &t) = 0;
};

struct App final : PlayerSpi {           // owner: implements Spi, holds Api
    explicit App(PlayerApi *api) : api(api) { api->setSpi(this); }
    void onTrackEnded() override { api->play(next()); }   // reacts to the callback
    PlayerApi *api;
};
```

**Singleton — encapsulate the one instance, never a bare global.** For a genuinely
process-wide subsystem, hide the constructor, delete copy/move, and hand out the
instance through one accessor — define it in the `.cpp` like any other method:

```cpp
// Game.h
struct Game {
    void update();
    static Game &instance();        // the sole accessor
    Game(Game &&) = delete;
private:
    Game();
};
// Game.cpp
Game &Game::instance() { static Game inst; return inst; }   // lazy, thread-safe (C++11)
```

A header form — a header-only util, or the generic
`template <class T> T &singleton() { static T inst; return inst; }` — must be
`inline`, not `static`, and gets a separate copy per Windows DLL. A singleton is
still global state: prefer injection through the composition root, and reserve it
for subsystems that are truly one-per-process.

## Dependency injection

- **Inject abstractions into high-level functions, never concrete types.** The
  caller chooses the implementation; the callee depends only on the interface.
- **Inject a factory, not a product, when the callee must create many.** Give a
  `Gun` whose `virtual unique_ptr<Bullet> shoot()` the callee calls repeatedly —
  not a single pre-made `Bullet`.
- **A single composition root does all the wiring.** One `main.cpp` (or one
  setup function) calls the factories and injects via constructor args or
  setters. No globals reach across modules; production vs test differ only by
  which factories the root calls.
- **Collaborators are borrowed, not owned.** Pass dependencies as raw interface
  pointers (`Dep *`) or references; the injectee never owns its collaborators.
  Ownership lives in the composition root. (See `references/ownership-lifetime.md`.)


## Type-rich data classes

Make illegal states unrepresentable and make call sites self-documenting. The
compiler is your reviewer.

- **Bundle ≥3 related params into a named struct with designated init.** Names
  beat positions; adding a defaulted field breaks zero callers.
  `void foo(FooConfig const &cfg);` then `foo({.name = "x", .age = 24});`
- **Return a named struct, never `pair`/`tuple`.** `result.success` not
  `result.first`.
- **`optional<T>` for nullable returns** — never a sentinel like `-1` or a
  nullable raw pointer. (Error handling: `references/error-handling.md`.)
- **Don't reflexively wrap fields in `optional<T>`** — reserve it for genuinely
  sometimes-absent data; on an always-present field it just sprays null-checks. A
  real either/or is a `std::variant` or distinct types, not a nullable.
- **`enum class` for flags/states** — blocks implicit `int` conversion and
  argument-order bugs.
- **Strong types for primitives that should not interconvert.** Wrap in a
  one-member struct or `enum class FileHandle : int {}` so `read(fd, …)` can't
  silently take the wrong `int`.
- **`std::span<T>` / `string_view` for non-owning buffer/string params** —
  length travels with the data, no `ptr,len` mismatch.
- **`std::chrono` for time**, never raw integers — `time_point + time_point`
  becomes a compile error instead of a 54-year sleep.
- **Plain data is a `struct` with public fields**, constructed by aggregate
  initialization — `Foo{a, b}` or designated `Foo{.x = a, .y = b}` — with no
  hand-written constructor and no encapsulation ceremony.
- **Getters/setters earn their place only to guard an invariant** — inside a
  value/resource type. Independent fields stay public (a `Point`'s `.x`/`.y` need
  no `getX`/`setX`); fields coupled by an invariant hide behind hook methods with
  mutation banned (a `vector` exposes `size()`/`resize()` and a read-only `data()`
  because resizing must reallocate).
- **Name constructors by intent — use named static factories** when variants
  differ in meaning, not signature (`Cake::makeChoco()` / `Cake::makeMoca()`,
  not `Cake(double)` vs `Cake(int)`).


## Duty class

Keep class interface small and orthogonal. Alert god-class tendency. When a class is piling too many methods and can be classified into orthogonal categories, consider breakdown heavy duty cluster into duty class.

E.g. `std::unique_ptr<Painter> Canvas::getPainter()` + `Painter::fill(Path const &, Brush const &)` + `Painter::stroke(Path const &, Pen const &)`. Here `Painter` can be another abstract class, and `Canvas` implements `Paintable` which requires `Paintable::getPainter()`. `Canvas.cpp` can implement that as `CanvasPainter` privately using anonymous namespace (a typical implementation can holds a `Canvas *` pointer). This keeps the `Canvas` interface stay focused, also reserve for future `Paintable` implementations.

**Why:** programmers and LLMs works better when knowledge is progressively disclosed. Reading a god-class floods context by side-cars unrelevant to the goal. So keep interface small and hierarchy to avoid dilution.

## Don't repeat yourself

When there are more than 2~3 paths sharing common pattern or concept: extract into abstracted class. E.g. `Path` for `Line`, `Arc`, `Bezier`; `Brush` for `Color`, `Gradient`; saves `fill()` from combination hell.

Two approaches to abstraction:
- Potentially vast expansion in future -> **Dynamic polymorphism**: `Path` as abstract class; pointer semantics; pass as `Path const &` (or `Path *` if mutable); return and store as `std::unique_ptr<Path>`.
- Fixed types, likely won't expand -> **Static polymorphism**: `Brush` as a data-class wrapped `std::variant`; value semantics; pass as `Brush const &`; return and store as `Brush`.

Avoid using function overload and templates for polymorphism unless the context is metaprogramming or performance.

