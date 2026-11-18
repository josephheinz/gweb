# Dev builds

`gweb dev` and `gweb build --dev` build for speed; `gweb build`, `start` and `export` are unchanged.

- **Fast C.** `goose build -O0` (no Goose inlining), and the program's C at `cc -O0` through a wrapper that gweb
  writes to `~/.cache/gweb/cc-HASH/cc` around the compiler `goose toolchain` names (so `GOOSE_CC` counts). The
  runtime and packages' native C build as goose asks; goose keys those objects by the compiler's path, so they build
  once more for the wrapper. `GWEB_DEV_CC=0` turns the wrapper off (goose's compiler and flags, still `-O0` Goose).
- **Template text out of the code.** In a dev build each literal run of a page, layout or view template is
  `gweb::_dev_lit(out, T, N)` (template T's run N, counted per template) and its text goes to `.gweb/lits`, which the
  server reads as it starts. A change to text alone (not a new line, tag or expression) leaves the C as it was, so
  only goose runs. Start a dev binary from its project folder; elsewhere it exits with `cannot read .gweb/lits`.
- **Split C, compiled in parallel, cached by unit.** The wrapper hands the program's C to `gweb __devcc`
  (`cli/devcc.c`), which splits it after goose: a header (runtime, types, data, prototypes without `static`; the
  mutable statics `extern`, defined once), about four units of function bodies per hardware thread, cut where a
  function's name (digits left out) hashes to 0 so that cuts follow the code, and `ublob.c` with the embedded files.
  goose's numbered constants (`gs_strN`, `gs_blobN`) are renamed by their content, and each unit defines the strings
  it uses, so one new string does not change every unit. Each unit compiles at `-O0`, all at once, to an object
  named by a hash of the compiler, its flags, the header and the unit; an object that exists is reused (those of
  the last two builds are kept, beside goose's `main.c` in `gweb-units/`). Anything in the C it does not expect,
  or a failed unit, and the wrapper compiles the C whole as before. `GWEB_DEV_UNITS=N` sets the units; `0` turns
  the split off; `GWEB_DEVCC_DEBUG=1` says why it gave up.
- **Same C, no compile.** The wrapper keeps the last C, link inputs and binary beside goose's `build/prog/*/main.c`;
  when they match it links the binary (`the C was unchanged, so its compile was skipped`). Dev binaries are hard
  links where they can be: macOS checks each new executable file the first time it runs (about 0.3 s here), and a
  file it has run before starts at once.
- **Shorter restarts.** `gweb dev` looks for changes every 100 ms (was 250), and a dev server's job runners wait
  50 ms at a time for work (was 250), so the old server stops in about 20 ms. The old server serves until the new
  binary is linked.
- **Times.** A dev build's line ends with its steps: `(2.3 s: gen 0.04, goose 1.6, cc 0.5 (1 of 63 units), link
  0.06)`; `hooks` when they took 0.05 s or more.
- **`public/` from disk.** A dev build does not embed `public/` files, hash their URLs or gzip them: the server reads
  each file per request, `Cache-Control: no-store`. So run a dev binary from the project folder. When only `public/`
  changed (no hook ran) and gen writes what the last binary was built from, `gweb dev` restarts that binary (kept in
  `.gweb.dev/server`) without calling goose; open pages reload on the new `/__gweb/id`. A new or removed file, or an
  `@image()` whose size changed, changes the generated code and compiles.
- **Errors once.** `build`, `start`, `export`, `dev`, `check` and `test` show each compiler error once with its source
  line, without the instantiation chain or the generated code. A template error is `file:line:col`, with an excerpt
  of about 80 characters around the column and a caret (the column comes from `srcmap.txt`). goose's
  `struct Props has no field x` names the struct: `app/page.goose: Props ...` or, for a view's,
  `views/items/TeamMember: Props has no field "x" (it has: ...)`; gweb finds the receiver's type where the generated
  code declares it (`props`, a `{#var}`, a `{#let}` of a struct literal). `--raw-errors` or `GWEB_RAW_ERRORS=1` shows
  goose's output.

Test: `test/devbuild.sh`.

## Timings

A goose-cms site (`cms new`: 14 routes, 26 pages, 12 static files), Apple M-series (10 cores), clang 21, goose
v2026.4. The C is one file: 13.5 MB at Goose `-O2`, 11.0 MB at `-O0`.

| Step | Time |
|---|---|
| Goose to C, `-O2` / `-O1` / `-O0` | 1.24 / 1.00 / 0.90 s |
| C to binary, Goose `-O2` C, `cc -O0` / `-O1` / `-O2` | 5.70 / 20.67 / 26.96 s |
| C to binary, Goose `-O0` C, `cc -O0` / `-O1` / `-O2` | **5.16** / 20.17 / 25.06 s |
| of which: `cc -fsyntax-only` (front end) / link | 0.87 / 0.05 s |
| TinyCC | not possible: `goose run` refuses threaded programs (TinyCC cannot place TLS), `--cc` takes no tcc |

| Command | Before | After |
|---|---|---|
| `gweb build` | 27.6 s | 27.6 s |
| `gweb dev`, a template change | 28 s | 5.8 s |
| `gweb dev`, a save that leaves the C as it was | 28 s | 1.1 s |
| `gweb dev`, a CSS change | 28 s | 0.04 s build, page reloaded 0.56 s after the save |
| first dev build on a machine (native objects for the wrapper) | | 9.0 s |

The fastest correct choice is Goose `-O0` with `cc -O0`: `cc -O1` costs four times as much.

### 1.8

The same site from `cms new` today (17 routes, 28 pages, 29 static files; the C is 20 MB at `-O0`, 6 MB of it
embedded files), 10 cores (4 performance), with other builds running on the machine. Save to the new page served
by `gweb dev` (curl polling `/` every 10 ms), three runs each:

| Edit | 1.7 build | 1.7 served | 1.8 build | 1.8 served |
|---|---|---|---|---|
| template text inside a line of `views/layouts/Main.html` | 8.5–9.2 s | 9.5–9.8 s | 1.7–2.3 s | 2.1–2.7 s |
| a new `{#if}` line in that layout | 8.5–10.2 s | 9.8–11.1 s | 2.6–3.4 s | 3.2–4.0 s |
| a string in `app/sitemap.goose`'s `robots` | 8.5–9.0 s | 9.5–9.8 s | 2.2–2.9 s | 2.9–3.5 s |

1.7, the `{#if}` edit: goose and `cc -O0` of one 20 MB file 8.4 s; hooks and gen 0.1 s; restart 0.25 s; the
watcher up to 0.3 s. 1.8: goose 1.6–2.2 s (the floor: goose's own front end, 1.5 s unloaded), the split 0.2 s,
two of 63 units 0.5–0.7 s, link 0.07 s, restart 0.05 s plus macOS's first run of a new binary, 0.3 s. Every unit
(a first dev build, or a change to a type or a specialization) is 2.1 s on 10 cores, against 7.8 s whole.

## Incremental builds: findings

- goose writes one C file per program. `goose help c` and `goose help internals` offer no split; goose's
  implementation notes say codegen "emits one C file", and namespaces add no separate compilation.
- The program is specialized as a whole: a template's `render<Z = cms::fill>` is instantiated from a package, so a
  C file per Goose package or module is not a cut goose has.
- Names are not stable. String constants (`gs_strN`) and specializations (`name_NNNN`) are numbered across the
  program: adding one comment to one widget template changed 18,947 lines of the C. Cached objects keyed on their C
  would almost all miss.
- Splitting the C after goose, at top-level function boundaries (a 24,000-line shared prefix of types and
  prototypes, the program's functions made extern), and compiling the parts in parallel at `-O0`:

  | Parts | 1 | 2 | 4 | 8 | 10 |
  |---|---|---|---|---|---|
  | `cc -O0 -c`, wall | 4.95 s | 2.90 s | 1.68 s | 1.13 s | 1.20 s |

  Those parts do not link as they are: mutable statics, the runtime's thread-local data-stack state and the string
  constants would each be one per part. 1.8 does it (`cli/devcc.c`, above) from what goose v2026.4 emits: the
  mutable statics are few and all before the prototypes (the data-stack state, `gs_rf`, `gs_lret_*`, the globals'
  main instance, `gs_program_initialized`); goose keeps a program instance's globals in one struct, so no other
  global needs care; every function after `---- code ----` has a prototype but `gs_init_globals`,
  `gs_program_init` and `main`. The embedded files are 6 of the 7 MB before the code, so they move to their own
  unit, and the header a unit includes costs about 0.08 s.
- Specializations are still numbered: an edit that adds one renumbers the later ones, and every unit that calls them
  compiles again. String constants no longer matter (renamed by content).
- Tried and dropped: a precompiled header (37 MB; building it, 0.9 s, cost more than it saved); compile flags at
  `-O0` (`-fno-stack-protector`, no unwind tables: no change; machine code generation is 70% of a unit); one compile
  per hardware thread (slower than starting all units at once); fixed-size cuts (an edit moved every later cut);
  skipping goose when the generated code is unchanged (goose also reads the packages, gweb's library and embedded
  files, which `.gweb/` does not hold, so the skip would need their state too; goose's 1.5 s is the largest step
  left).

## Proposal (goose)

gweb 1.8 does item 1 and the constants of item 2 itself, after goose; goose doing them would make them safe
against changes in what goose emits.

1. `goose -o DIR --units N` (and `goose build --units N`): a shared header (types, prototypes, `extern` globals and
   string constants), one unit with the definitions of globals and constants, and N units of function bodies split
   by size, with hidden-visibility external linkage. `goose build` compiles the units in parallel. Expected: the dev
   C compile from 5.2 s to about 1.2 s; a dev rebuild from 5.8 s to about 2.5 s. gweb passes the flag in dev builds.
2. Stable names: specializations and constants named from their content or declaration (a hash, or namespace plus
   ordinal within it) instead of program-wide counters; functions placed in units by namespace. `goose build` then
   caches unit objects by content hash, as it does packages' native C. Expected for a one-template edit: Goose 0.9 s,
   one unit and the link well under a second.
