# Goose for site developers

The slips a site developer makes in the first week. Each snippet here was compiled. The language itself is documented
in the Goose SDK's `reference.md`, `stdlib.md` and `tutorial.md`.

## No `?:`: `if` is an expression

```goose
let label = if n > 1 { "many" } else { "one" };      // both branches, same type
```

`n > 1 ? "many" : "one"` is `expected ';' in variable declaration, found '?'`.

## Text

```goose
let same = a == b;                  // == and != work on text
let before = compare(a, b) < 0;     // -1, 0 or 1, byte by byte: "09:00" and "13:00" compare right
let has = find(a, "an") >= 0;       // position of a part, -1 when it is not there
```

`a < b` on text is `ordering comparison requires numeric operands`: use `compare`. To order times, parse them:

```goose
fn minutes(hhmm: const u8[:]) -> i64 {          // "09:30" is 570
    let h, ok1 = parse_int(hhmm[..2]);
    let m, ok2 = parse_int(hhmm[3..]);
    if !ok1 || !ok2 { return -1; }
    return h * 60 + m;
}
```

`const u8[:]` is text you read (a literal, a field, a slice); `u8[>..]` is text you build:

```goose
var out: u8[>..] = [];
out.append("A");
format(out, " and ", 5, " ", true);              // writes each value as text
```

## Numbers

```goose
let n = c as i64;                   // u8, i32, ... to i64: `x as T`, not i64(x)
let half = n as f64 / 2.0;
let tenths = (half * 10.0) as i64;
let v, ok = parse_int("12x");       // there is no atoi: (0, false) here; parse_flt for decimals
```

- `i64(c)` is `expression expected, found 'i64'`.
- Mixed signs and widths do not mix: `i64 * u64` is `operands of * have no common type`; convert one side with `as`.
- A widening conversion is allowed without `as` where the value fits; `as` on one that is already implicit is a warning.

## A `var` that is set again to something from another scope

```goose
var place = "";                     // a reference to static text
place = v.title;                    // re-binding place with a reference rooted at a different scope depth is not supported
```

A `var` that holds a reference cannot be pointed somewhere else later. Build into a buffer you own:

```goose
var place: u8[>..] = [];
place.append(v.title);              // or: place.clear(); place.append(other.title);
```

A `let` is bound once, so `let place = if a { x.title } else { y.title };` is also fine.

## Struct literals

```goose
struct Box { a: i64 = 0, b: u8[..16] = "", c: bool = false }
let x = Box { a: 1, b: "hi", .. };      // `..` takes the rest from the defaults
let y = Box { b: "x", .. };
```

Name fields in declaration order whenever a value is a call: `Box { b: "x", a: next() }` is `field initializers must
follow declaration order`. (Plain values may be written in any order.) The order of a struct is where it is declared:
for `cms::Find` see `lib/doc.goose` (`under, vtype, sort, by, order, limit, offset, where, is, ref, where2, ...`).
Or compute the value first: `let k = next(); Box { b: "x", a: k }`.

## Words you cannot use as names

`pad` is a reserved word (`var pad` is `expected identifier in variable declaration`). So are the other keywords of
Goose (Appendix A of `reference.md`). A function that calls itself, directly or through another, is declared
`recursive fn`.

## A call in a template that returns nothing

A template expression needs a value. `{#let _x = mark(3)}` with a `void` helper is `initializer has no value`, and
`{mark(3)}` cannot print it. Two ways:

```goose
fn mark(n: i64) -> bool { seen += n; return true; }                  // return a bool, and bind it
fn side(out: u8[>..]&, n: i64) { seen += n; }                      // or take `out` first, writing nothing
```

```html
{#let _ok = mark(3)}
@side(3)
```

`@f(a)` calls `f(out, a)`, so it works for a helper that writes nothing too.

## `{#else}`, not `{:else}`

```html
{#if props.n > 1}<b>many</b>{#else if props.n == 1}<b>one</b>{#else}<b>none</b>{/if}
```

## Reference keys in a cms view: `node`, `item`, `items`, `asset`

In a goose-cms view's `.goose` file these four names are for fields of the types `cms::PageRef`, `cms::ItemRef`,
`cms::ItemRefs` and `cms::Media`. `cms check` refuses any struct in that file with a field of one of those names and
another type (a helper `struct Rows { items: Item[..8] }` too):

```
views/types/Menu.goose:12: error: field "items" is a reference key; name it otherwise, or make it cms::ItemRefs
```

Call it `rows`, `entries`, `list`: any other name is free.
