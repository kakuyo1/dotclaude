# Conversions and invariants

## When to use `explicit` constructor

- **Default to `explicit`** for every converting constructor, including
  multi-argument constructors used through `{...}`.
- Allow implicit conversion only when the source and destination are genuinely
  substitutable values and the conversion is unsurprising and lossless, such as
  a UTF-8 string literal becoming an owning `std::string`.
- Different semantics require `explicit`: a count is not a container, a raw
  handle is not an owning resource, and an integer is not an age merely because
  their representation matches.
- When construction modes differ by intent, use named factories rather than
  constructor overloads: `Angle::fromDegrees(x)` and `Angle::fromRadians(x)`.

```cpp
struct BigInt {
    BigInt(std::int32_t value); // exact, lossless value-domain extension
};

struct Dog {
    explicit Dog(std::string const &name);
};

void sendMsg(std::string const &msg);
void showBigInt(BigInt const &big);
void showDog(Dog const &dog);

void usage() {
    sendMsg("hello");
    showBigInt(42);
    showDog(Dog{"George"});
}
```

## C++ cast ladder

Pick casts by the semantic conversion being requested. For arithmetic values,
"up-cast" and "down-cast" are misleading: signedness, range, precision, and the
runtime value all matter.

- **Known-safe constant → braces.** List initialization rejects narrowing at
  compile time: `auto channel = std::uint8_t{42};` is valid while
  `std::uint8_t{300}` is ill-formed.
- **Runtime integral conversion → check, then `static_cast`.** In C++20 use
  `std::in_range`; in C++17 compare against `numeric_limits` with signedness
  handled explicitly:

  ```cpp
  std::optional<std::size_t> toSize(std::int32_t value) {
      if (not std::in_range<std::size_t>(value)) return std::nullopt;
      return static_cast<std::size_t>(value);
  }
  ```

- **Floating-point → integer → define the policy first.** Reject non-finite and
  out-of-range values, then choose truncation, floor, ceil, or rounding before
  the final `static_cast`. A naked cast silently bakes in truncation and is
  undefined when the finite result is outside the destination range.
- **Representation conversion → `std::bit_cast`** only between equally sized,
  trivially-copyable types. In C++17 use `std::memcpy` with the same static
  assertions. This is not numeric conversion.

For a polymorphic `Dog : Animal` hierarchy:

- Derived-to-base pointer/reference conversion is implicit. Returning
  `unique_ptr<Animal>` from a factory deliberately hides `Dog`.
- Prefer virtual dispatch over recovering the concrete type. When a boundary
  genuinely requires checked base-to-derived conversion, `dynamic_cast<Dog *>(p)`
  returns `nullptr` on mismatch; `dynamic_cast<Dog &>(r)` throws `std::bad_cast`.
- Use `static_cast<Dog *>(p)` only when a nearby invariant proves the dynamic
  type. Assert that invariant where it is established; a wrong unchecked
  downcast has undefined behavior.

Avoid `reinterpret_cast`. Its legitimate uses are narrow low-level boundaries,
such as the implementation-required pointer/`uintptr_t` round trip. Converting
an object pointer to `void *` is implicit; converting a byte buffer to a packed
struct is not a safe zero-copy parser because alignment, lifetime, and aliasing
still apply. Copy bytes with `memcpy`/`bit_cast`, then validate the fields.

Avoid `const_cast`. It is tolerable only when adapting a legacy API whose
signature incorrectly omits `const` and which is known not to write. Modifying an
object that was originally defined `const` is undefined behavior.

Ban C-style casts `(T)x`: they can silently combine `static_cast`,
`const_cast`, and `reinterpret_cast`. Use braces, a named C++ cast, or a
domain-specific conversion function that makes validation visible.

## C++ arithmetic types

Choose an integer type from the value's meaning, not from a blanket ban:

- Use `std::int8_t` / `std::uint32_t` and friends when an exact width is part of
  a wire format, file layout, ABI, SIMD lane, or hardware register. Exact-width
  typedefs are optional on platforms that cannot provide that width.
- Use `int` for ordinary small signed arithmetic when no exact width is part of
  the contract. Do not serialize it or expose its layout as an ABI promise.
- Use a container's `size_type` (usually `std::size_t`) for sizes and indices
  that must interoperate with that container. Use `std::ptrdiff_t` for signed
  distances and subtraction. Do not mix signed and unsigned values casually.
- Use `std::uintptr_t` only when the implementation provides it and an integer
  must round-trip an object pointer. It is not a generic "native integer."
- Avoid bare `long` in portable layouts: it differs between LP64 and LLP64.

Use `float`, `double`, or `long double` according to the required precision,
range, ABI, and measured performance. Append `f` to a floating literal intended
to be `float`, such as `3.14f`; do not rely on an implicit `double` conversion.

## Add assert when you made assumption

Use `static_assert` for compile-time properties and `assert` for internal runtime
invariants. Put the check next to the assumption it protects:

```cpp
auto const b = someInt();
auto const a = someInt();
auto const diff = b - a;
// Keep a future return-type change from making `diff < 0` always false.
static_assert(std::is_signed_v<decltype(diff)>);
if (diff < 0) {
    return false;
}
```

```cpp
auto const v = internalAlgorithm();
assert(not v.empty());
return v.back() - v.front();
```

`assert` disappears when `NDEBUG` is defined. Never use it to validate external
input or report a recoverable failure:

```cpp
auto const v = fetchFromInternet();
if (v.empty()) return std::nullopt;
return v.back() - v.front();
```

**Construction as validation:** put one invariant in a value type so downstream
code cannot receive an invalid value. Encapsulation earns its place by making
the illegal state unrepresentable.

```cpp
struct Age {
    static std::optional<Age> fromYears(std::int32_t value_) noexcept {
        if (value_ < 0 or value_ > 130) return std::nullopt;
        return Age{value_};
    }

    std::int32_t value() const noexcept { return raw; }

private:
    explicit Age(std::int32_t raw_) noexcept : raw(raw_) {}
    std::int32_t raw;
};

struct UserConfig {
    Email email;
    UserName name;
    Age age;
};

auto const age = Age::fromYears(inputAge);
if (not age) return false;
registry->registerUser(UserConfig{.email = email, .name = name, .age = *age});
return true;
```

Return C++23 `std::expected` when the caller needs an error reason. In C++20/17,
use the project's `expected` backport, a named result struct, or `optional` when
no error detail is needed.

`UserConfig` remains an aggregate data class because each field is independently
valid. If validity depends on a relationship among several fields, replace it
with one composite value type and a validating named factory; a struct with a
validating constructor is no longer the skill's "data only" data class.

