# Addendum 22: a text type for view Props

View Props hold text as `u8[..N]`: `title: u8[..300] = ""`, `body: u8[..60000] = ""`. The developer guesses `N`, every
Props carries every cap inline (an Article is 61 KB, zeroed on each read), and long text is cut where nobody sees it.
This addendum picks a replacement. Migration step 1 is built (in the release after 1.3.0, so "1.3" below is 1.4); see
"As built" at the end for where it differs.

## Where text is cut today

| Path | What happens to text over `N` |
|---|---|
| Form, browser | `g_form` writes `maxlength="N"`. The browser stops typing there and cuts a paste with no message. `maxlength` counts UTF-16 units, `N` is bytes. |
| Form, server | `form_text` refuses it: "Use at most N characters." (it counts bytes). Visible, but the count is wrong for non-ASCII. |
| JSON read | `_jr_text` cuts on a character boundary and adds one to the warning count. The count is a number; no field is named, the editor shows the cut text, and the next save stores it. |
| goose-cms merge | Works on canonical JSON spans, so it never cuts. But it re-reads through the view, so a cut on read becomes a cut on save. |

## Facts checked with goose v2026.4

| # | Program | Result |
|---|---|---|
| F1 | `struct P { a: u8[>..], b: u8[>..] }` | refused: "resizable field a of struct P must be the final field; use root struct for independently stored fields". This is why a repeater must be the last Props field. |
| F2 | `I[>..<]` where `I` has a `u8[>..]` field | refused: "grow-shrink array elements must be fixed-size". Repeater items cannot hold growable text. |
| F3 | `root struct P { a: u8[>..] = "hi", b: u8[>..] = "yo", items: I[>..<] = [], n: i64 = 0 }` | works: several growable fields, string defaults, `P { .. }`, `p.a.append`, passed as `P&` and `const P&`, generic `fn r<T>(p: const T&)`. |
| F4 | `fn make() -> P` for a root struct | refused: "root struct P can only be owned by a local or global variable; return a reference instead". Nor can it be a field of another struct. |
| F5 | `type Text = u8[>..];` then `a: Text = "hi"` in a root struct | works. |
| F6 | `struct P { a: u8[], b: u8[] }` (variable-size) | works from literals; the sizes are fixed at construction (Addendum 19 E4: such a type is `P..` everywhere). |
| F7 | 200,000 times: make a Props, fill four fields with 100 to 200 bytes | fixed caps 300/60000/120/600: 5,000 ns each (zeroing 61 KB). Root struct of `u8[>..]`: 9 ns each. Peak RSS 1.6 MB either way. |

## Options

**A. Keep `u8[..N]`, fix the cuts.** Drop `maxlength`, count characters, name cut fields on read. Cheap and additive,
but the guess and the 61 KB stay.

**B. `gweb::Text`, growable, in a root struct (recommended).** `type Text = u8[>..];` in gweb. A view whose Props
has a `Text` field declares `root struct Props` (F3). Text is as long as it is; a limit is a validation rule with a
default, checked with a visible error. Repeater items keep `u8[..N]` (F2), with the same visible errors.

**C. A fixed handle into an arena.** `struct Text { off: i32, len: i32 }` into a buffer the Props or the request owns.
Fixed-size, so it works in items and by value. But every use needs the arena: `{props.title}` becomes
`{gweb::text(a, props.title)}`, `.len` and `==` mean nothing, and a handle copied to another Props points at the wrong
bytes with no error. Rejected: every template and `validate` changes, and the failure mode is silent.

**D. Variable-size `u8[]` (`Props..`).** No cap, but the size is fixed at construction (F6): the JSON reader needs two
passes, forms cannot append, items still cannot hold it, and `..` spreads into every signature. Rejected.

**E. A `Text` with one default cap (`u8[..4096]`).** One guess instead of many. Still inline, still cut. Rejected.

## Decision (2026-11-17): Text and LongText

Two types replace the one `gweb::Text` above. Both are `u8[>..]`; everything else in (B) holds.

| Type | Default max (characters) | Form control |
| --- | --- | --- |
| `gweb::Text` | 128 | `<input>` |
| `gweb::LongText` | 65,536 | `<textarea>` (or the field's `editor`) |

- `FieldUi.max` still overrides either default.
- `Text` over 128 needs `max` set and stays an `<input>`; a long body is a `LongText`.
- The rule "`Text` above 200 draws a `<textarea>`" (Forms) is dropped: the type picks the control.

## The recommendation (B)

### Declaring

```goose
// views/types/Article.goose
root struct Props {
    title: gweb::Text,                          // required, at most 128 characters (120 with the UI below)
    summary: gweb::Text = "",
    body: gweb::LongText = "",
    date: cms::Date = cms::Date { .. },
    links: Link[>..<],                          // a repeater no longer has to be last; several are allowed
}
struct Link { label: u8[..80] = "", url: u8[..500] = "" }          // items keep u8[..N]
let UI = [gweb::FieldUi { field: "title", max: 120 }, gweb::FieldUi { field: "body", editor: "markdown", max: 200000 }];
```

- `gweb::Text` is `u8[>..]`. A Props with one is a `root struct`. A plain `struct Props` with a `Text` field is a build
  error at its line: `a Props with gweb::Text is a root struct: write root struct Props`. gweb does not add `root`
  itself, because it changes what the app may do with Props (F4).
- **The limit** is `FieldUi.max` (new, `i64 = 0`), in characters (code points), default 128 for `Text` and 65,536 for
  `LongText` (the multipart text default, `--max-upload-text`). Above `--max-body` (1 MiB) it cannot be reached; `gweb gen` warns (`text-max`).
- **`Text` is a top-level Props field only.** In a fieldset struct (`badge: Badge`) that struct would have to be a root
  struct too, which cannot be a field (F4). Fieldsets and items keep `u8[..N]`.
- Under a root struct, the repeater-last rule goes (F1 was its reason), and the 32-field cap stays.

### JSON

Unchanged on disk: a JSON string, canonical order, so stored content needs no migration and goose-cms's merge sees the
same spans. Reading a `Text` never cuts. Text over its `max` is kept whole and named (below). `u8[..N]` fields still
cut on read (they must), but are named too.

### Read errors that name the field

`read(json, p) -> i64` keeps its warning count. New: `read_errs(json, p, errs: gweb::FieldErrors&)` (in the view's
namespace, and `views::g_read_errs(name, json, p_json_out, errs)`), which adds `"Stored text is 70,412 characters; the
limit is 65,536."` or `"Stored text was cut to 80 bytes."` under the field. `g_form_req` calls it on a GET, so the
editor sees the problem before saving over it. This also answers goose-cms ask 6 (validating merged props): the same
function validates JSON that did not come from a form.

### Forms

- `g_form_req` draws `Text` as `<input>`, or `<textarea>` when `editor` is `textarea` or `markdown`; `LongText` as
  `<textarea>`. **No `maxlength`** on `Text`, and none on `u8[..N]` in `g_form_req` (a browser cut is the silent cut).
  `g_form` keeps its 1.0 markup, as stability.md requires.
- `g_parse` checks the limit before `validate`: `"Use at most 120 characters (this is 131)."`, counted in code points.
  For `u8[..N]` the message counts bytes and says so: `"Use at most 80 bytes (this is 93)."`. The rich form shows the
  posted text, as for any error.
- New helper `gweb::form_text_max(req, field, out: u8[>..]&, errs, required, max)`; `form_text` is unchanged.

### Templates

No change. `Text` is a `u8` array: `{props.title}`, `{#if props.body.len > 0}`, `@image(props.src)`, `{#raw
markdown::html(props.body)}` all compile as before. `validate` keeps `p.title.len` and `gweb::check_length` (whose
message should count characters; a fix in the same release).

### Generated code

| Piece | Change |
|---|---|
| struct scan (`cli/structs.goose`, `add_field`) | accept `root struct Props`; `gweb::Text` (and `Text` after `import gweb`) is kind Text with `cap` 0 and a `max`; error for `Text` outside top-level Props or in a plain struct |
| `read` / `gw_read_Props` | `gweb::_jr_text_all(r, v.f, max, warn)` for `Text`: appends the whole string |
| `read_errs` | new, beside `read` |
| `write` | unchanged (`json::format_string`) |
| `form`, `form_req` | `_vf_text` gets `max` and a flag for "no maxlength" |
| `parse` | `_vp_text_max` for `Text`; the byte message for `u8[..N]` |
| `views` registry | `g_read_errs`; `FieldMeta.cap` holds `max` for `Text`, and `FieldMeta.chars: bool` (new, default false) says the cap counts characters |
| `g_render`, `g_form`, `g_defaults`, `g_parse` | already make `var p = Props { .. }` locally and pass `Props&`, which a root struct allows (F3) |

### goose-cms

- **Field merge:** no change; it compares JSON spans.
- **`cms check`'s generated `lib/site.goose`:** `fn props_Article(c) -> v_types_Article::Props` returns by value and
  `struct Item_Author { props: v_items_Author::Props }` embeds one. Both are refused for a root struct (F4). They
  become `fn props_Article(c, p: v_types_Article::Props&) -> bool` and `Item_Author { id, json }` with
  `fn item_props_Author(it, p&) -> bool`. `cms check` makes the change when it regenerates; a template that called
  `props_Article(c).title` needs a `{#let}` (or a `Doc` helper) instead. This is the main cost of B.
- `cms check` learns `FieldUi.max` (its UI checks list the keys it knows).

### Performance and memory

- Read and render: a `Text` costs its length, not its cap. F7: 9 ns against 5,000 ns per Props, and a 60 KB body cap
  no longer means 60 KB per Props on each worker's stack, per view rendered.
- A root struct's growable fields are stored as `u8[>..]` locals are, and go when the local does. Nothing outlives
  the request, and nothing is shared between workers.
- The worst case is bounded by `--max-body` for forms and by the stored JSON for reads: a 1 MiB document read in full
  is 1 MiB, where today it is cut to `N`.
- Items: unchanged (`u8[..N]` inline, at most 64 per repeater).

### Components

`@prop` already takes `u8[:]`, which has no cap. `@state` keeps `u8[..N]`: state is mirrored in JavaScript and the
state struct is copied whole. Out of scope.

## Migration

1. **gweb 1.3 (additive).** `gweb::Text`, `root struct Props`, `FieldUi.max`, `read_errs` / `g_read_errs`, the counts
   in characters, no `maxlength` in `g_form_req`. A `u8[..N]` view keeps working byte for byte, except that `g_form_req`
   loses `maxlength` (its markup is not frozen; `g_form`'s is).
2. **`tools/migrate-text.sh [DIR]`.** For each `views/**/*.goose`: top-level `name: u8[..N]` becomes `name: gweb::Text`
   with `gweb::FieldUi { field: "name", max: N }` added (bytes become characters, so the limit only loosens),
   `struct Props` becomes `root struct Props`, and it prints the places that return or embed a Props (F4). `gweb check`
   on the result finds the rest.
3. **goose-cms** regenerates `site.goose` with `cms check` (the new shape), and its scaffold and examples use `Text`.
4. **gweb 1.4 or later:** a warning `fixed-text` on a top-level `u8[..N]` in a view's Props. Never an error in 1.x.

## Open

- Whether `Text` may sit in a fieldset struct (`badge: Badge`). It would make `Badge` a root-only type too; v1 says no.
- Whether `FieldUi.max` or a type parameter (`gweb::Text<120>`, if Goose grows one) is the long-term spelling.
- Items with long text (an FAQ answer in a repeater) still need a cap. Option C for items only, or a child view per
  item (goose-cms sections already work that way), would lift it.

## As built (2026-11-17)

Step 1 of the migration, with the Decision above. Tests: `test/text.sh`. Where it differs from the design:

- **Spelling.** Only `gweb::Text` and `gweb::LongText`. A bare `Text` after `import gweb` does not work: an import
  brings no names into scope (Goose spec 11.1).
- **`FieldUi.max`** applies to `Text` and `LongText` only; on any other field it is a build error. `text-max` warns
  above 1,048,576 (the default `--max-body`), not above the flag a server runs with.
- **`read`** counts a `Text` over its limit as one warning (the text is kept), so the count still means "the JSON
  does not fit the view".
- **`g_read_errs(name, json, out_json, errs, prefix) -> bool`.** It takes the form prefix, writes the canonical JSON,
  and runs `validate` when reading added no error, so it is also goose-cms ask 6 (`g_validate`). The namespace's
  `read_errs(json, p, errs) -> i64` names fields without a prefix and does not validate.
- **Form markup.** `Text` and `LongText` have no `maxlength` in either form; a `u8[..N]` keeps it in `g_form` only. The
  text control takes one `gweb::_TextUi` struct (`_vf_text_ui`) instead of twelve parameters, which also answers
  goose-cms ask 8 for text. `_vf_text` stays for old generated code.
- **Several repeaters.** `gw_act_Props` handles each; `ITEM_LABEL` labels each repeater whose item has the field. It
  may also name an enum (its label) or a foreign field (`ns::gw_label(out, v)`), so a `cms::ItemRef` can label items.
- **`FieldMeta.ty`** is `gweb::Text` or `gweb::LongText` for those fields, beside `chars`.
- **Struct errors.** A struct of Props declared `root struct` is a build error (F4).
- **Enums in templates** (goose-cms ask 2, with this release). Each view enum gets a `format` hook, so `{props.gap}`
  prints its `ENUM_LABELS` label or variant name, and `gweb::enum_name(v)` / `gweb::enum_label(v)` overloads.
