# Dev builds

`gweb dev` and `gweb build --dev` build for speed; `gweb build`, `start` and `export` are unchanged.

- **Fast C.** `goose build -O0` (no Goose inlining), and the program's C at `cc -O0` through a wrapper that gweb
  writes to `~/.cache/gweb/cc-HASH/cc` around the compiler `goose toolchain` names (so `GOOSE_CC` counts). The
  runtime and packages' native C build as goose asks; goose keys those objects by the compiler's path, so they build
  once more for the wrapper. `GWEB_DEV_CC=0` turns the wrapper off (goose's compiler and flags, still `-O0` Goose).
- **Same C, no compile.** The wrapper keeps the last C, link inputs and binary beside goose's `build/prog/*/main.c`;
  when they match it copies the binary (`the C was unchanged, so its compile was skipped`).
- **`public/` from disk.** A dev build does not embed `public/` files, hash their URLs or gzip them: the server reads
  each file per request, `Cache-Control: no-store`. So run a dev binary from the project folder. When only `public/`
  changed (no hook ran) and gen writes what the last binary was built from, `gweb dev` restarts that binary (kept in
  `.gweb.dev/server`) without calling goose; open pages reload on the new `/__gweb/id`. A new or removed file, or an
  `@image()` whose size changed, changes the generated code and compiles.
- **Errors once.** `build`, `start`, `export`, `dev` and `check` show each compiler error once with its source line,
  without the instantiation chain or the generated code. `--raw-errors` or `GWEB_RAW_ERRORS=1` shows goose's output.

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
  constants would each be one per part. Doing it right means knowing what goose emits, so gweb does not do it.

## Proposal (goose)

1. `goose -o DIR --units N` (and `goose build --units N`): a shared header (types, prototypes, `extern` globals and
   string constants), one unit with the definitions of globals and constants, and N units of function bodies split
   by size, with hidden-visibility external linkage. `goose build` compiles the units in parallel. Expected: the dev
   C compile from 5.2 s to about 1.2 s; a dev rebuild from 5.8 s to about 2.5 s. gweb passes the flag in dev builds.
2. Stable names: specializations and constants named from their content or declaration (a hash, or namespace plus
   ordinal within it) instead of program-wide counters; functions placed in units by namespace. `goose build` then
   caches unit objects by content hash, as it does packages' native C. Expected for a one-template edit: Goose 0.9 s,
   one unit and the link well under a second.
