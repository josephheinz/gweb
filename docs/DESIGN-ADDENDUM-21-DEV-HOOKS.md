# Addendum 21: commands, hooks, `gweb update`, the stale line

Three gaps. goose-cms needs `cms check` run after a view changes, and developers forget it. Updating gweb takes three
`git` checkouts and a build. A gweb binary older than its checkout fails with compile errors that do not say why.

## What was built

| Item | Where |
|---|---|
| `tool`, `run` and `hook` lines; `gweb run`; hooks in `build`, `start`, `export` and `dev` | `cli/gweb.goose` (section "tools, commands and hooks") |
| A file stamp for a hook that watches a file (macOS `nftw` refuses one) | `gweb_tree_stamp` in `cli/proc.c` |
| `gweb update [TAG]` | `cli/gweb.goose` (section "update") |
| The stale line | `SELF_FILES`, `SELF_DATA`, `warn_stale` in `cli/gweb.goose` |
| Tests | `test/hooks.sh` and `test/hooks/`, `test/update.sh` |

## D1. Where: the files that exist

`gweb.packages` (the app) and `gweb.package` (a package) take three more kinds of line. They already share
`package NAME SOURCE` lines, gweb reads both, and a package's lines merge into the app's the same way. `gweb.build` is
the compiler's file (C sources), not gweb's. No new file.

```
tool NAME FILE.goose     a Goose program, built by gweb (D3)
run NAME COMMAND         gweb run NAME [args] runs COMMAND
hook PATHS COMMAND       runs COMMAND before a build when PATHS change
```

- `NAME`: letters, digits, `_ - .`; not starting with `-` or `.`.
- `FILE`: relative to the folder that declares it (the package, or the app), no `..`, ending `.goose`.
- `PATHS`: folders or files of the app, split by commas, no spaces, no `..`, not absolute, not `.gweb*`.
- `COMMAND`: the rest of the line, for `/bin/sh`, under 2,048 bytes.
- `run at /x` (and `tool`, `hook`) followed by `at` is still a folder of that name, mounted, as `package at /x` is.
- A package with these lines says `gweb 1.3`: gweb 1.2 refuses an unknown line.

## D2. Where a command runs

Every command and hook runs in the **app's folder**, whoever declared it. That is what `cms check` needs (it reads
`views/` and writes `lib/site.goose`). It gets:

| Variable | Value |
|---|---|
| `PATH` | `<app>/.gweb.tools/bin` first |
| `GWEB_APP` | the app's folder |
| `GWEB_PKG_DIR` | the declaring package's folder (the app's, for the app) |
| `GWEB` | this gweb binary |

`gweb run NAME a b` appends the arguments (`COMMAND "$@"`) and execs, so the exit status is the command's.
`gweb run` alone lists the commands. Arguments after `NAME` are the command's, `--help` included.

## D3. Tools: how the binary is found

A command names a tool by its `NAME` as a word. Before the command runs, gweb builds each tool it names into
`.gweb.tools/bin/NAME` (git-ignored by `gweb new`), when the binary is missing or its key changed. The key is the
gweb version, the rewritten root, and the folder's stamp (a path package or the app). A git package is a fixed tag, so
only the root decides.

A package's tool must build outside the package's own checkout layout. goose-cms's `cli/cms.goose` imports
`sqlite from "../../goose-sqlite"`, which holds beside the repo and not in `~/.cache/gweb/pkgs/`. So gweb:

1. builds a tree in `.gweb.tools/src/NAME/`: each entry along `FILE`'s path is a link to the package's, and the root
   is a copy. Relative imports, `embed_file` and links like `cli/cms -> ../lib` resolve as in the package. The package
   folder is never written to (a cached tag stays clean; a checkout gets no stray files).
2. rewrites each `import X from "SOURCE";` of the root: `gweb`, `net` and `sqlite` take the app's sources (the ones
   `gweb version` prints), a Goose package from a `package` line (the app's or any package's) takes its source, and
   any other relative source becomes absolute. The tool links the same library versions as the server.
3. runs `goose build -o .gweb.tools/bin/NAME`. A failure is an error at the `tool` line, with the compiler's output.

An app's tool (`tool` in `gweb.packages`) is built where it is, as written.

Rejected: building in the package folder (writes into a cache or a checkout); copying the package (goose-cms is
24 MB with its examples' build output); a `goose` override of import sources (there is none).

## D4. Hooks: when and in what order

- `gweb build`, `start`, `export` and `dev` run hooks before `gen`. `gen`, `test`, `check`, `routes` and `lsp` do
  not: they read the tree, they do not change it.
- `build`, `start` and `export` run every hook. `gweb dev` runs every hook before its first build (a view may have
  changed while it was off), then, on each change, only the hooks whose paths changed since they last passed.
- The packages' hooks run first, in `gweb.packages` order, then the app's, in file order. The app has the last word.
- A hook's paths join what `gweb dev` watches. What hooks write is not a change: the dev stamp is taken after them, so
  `cms check` rewriting `lib/site.goose` starts no second rebuild.
- `--no-hooks` (`build`, `start`, `export`, `dev`) or `GWEB_HOOKS=0` skips them, for a container build where the
  tool cannot be built.

## D5. A failing hook

A hook that exits non-zero stops the build like a compile error: its output, then
``gweb.package:8: error: hook `cms check` failed (exit 1)``. `gweb build` exits 1. `gweb dev` keeps the old server
and writes both to `.gweb.dev/errors.txt`, so the page shows them, with excerpts of any `path:line:` the hook printed.
A failed hook is not recorded as passed, so it runs again on the next change. Under `--diagnostics json` the output is
one JSON object.

## D6. Names

- Two tools with one name: an error at the second line.
- A command in the app and in a package: the app's wins (an override, as npm's own scripts are the app's).
- A command in two packages and not the app: `gweb run NAME` refuses, naming both, and says to declare it in
  `gweb.packages`.
- Tool names and Goose package names are separate: goose-cms has both `cms`.

## goose-cms

Its `gweb.package`, once gweb 1.3 is out:

```
name cms
gweb 1.3
package uni josephheinz/goose-unicode@v0.1.0
package blob josephheinz/goose-blob@v0.1.0
tool cms cli/cms.goose
run cms cms
run check cms check
hook views cms check
```

Then an app runs `gweb run cms seed`, `gweb run check`, and `cms check` runs on every change under `views/` in
`gweb dev` and before every `gweb build`. Checked against a copy of goose-cms 9776a6d (`gweb run cms check` on
`examples/site`, with `gweb 1.2` in the copy): the tool builds with no goose-sqlite beside it.

## D7. `gweb update [TAG]`

The checkout beside the binary (`gweb version`'s `gweb` line; `$GWEB_HOME`), and `../goose-net` and `../goose-sqlite`
when they are git checkouts, go to the latest release tag at their `origin` (the highest `vX.Y.Z`, no prerelease), or
`TAG`. The three repos release together with one tag, so every one must have it.

1. **Refuse first.** A checkout with changes to tracked files (untracked files are fine): every one is named, nothing
   changes. No checkout (a copied gweb): says so. An `origin` that cannot be reached (`git ls-remote` fails): "cannot
   reach the origin of DIR; nothing changed". A tag missing in one repo, or a branch the tag does not fast-forward,
   stops before any checkout moves.
2. **Move.** Per repo: at the tag, nothing. Past it (the tag is an ancestor of `HEAD`, and no `TAG` was given), left as
   it is: a gweb developer on `main` keeps `main`. On a branch the tag fast-forwards, `merge --ff-only`. Otherwise
   (detached, as `git clone --branch` leaves it, or a given `TAG`) `checkout --detach`, saying the branch it left.
   A shallow clone fetches the tag with `--depth 1`.
3. **Build** when a repo moved, the binary is missing or stale (D8): `goose build -o gweb.new`, then a rename over
   `gweb`. A failure leaves the old binary.
4. **Link** `DIR/gweb` to the checkout's binary. `DIR` is `$GWEB_BIN_DIR`, else the folder of `goose` on `PATH`
   (`~/.local/bin` on this machine), else `~/.local/bin`. A link elsewhere, or a copy, is replaced, and the line says
   which. If another `gweb` comes first on `PATH`, or `DIR` is not on it, a note says so.
5. Nothing to do: `gweb update: up to date (v1.3.0)`.

It asks nothing and prints one line per thing it did. It does not update the compiler or an app's pinned packages.

## D8. The stale line

The binary embeds every file it is built from (`SELF_FILES`: `cli/*`, `VERSION`, the client runtimes, the LSP
server, the Dockerfile) and compares each with the checkout at start. Any difference prints

```
gweb is older than its source in DIR: run gweb update (or goose build -o gweb cli/gweb.goose)
```

once on stderr, and the command goes on. Content, not mtimes: a `git checkout` touches files without changing them,
and a copied binary has no build time to trust. A copied gweb with no checkout prints nothing. It replaces the
`VERSION` check, which stopped with "rebuild gweb" only when `VERSION` differed and missed a stale binary of the same
version. The binary grows by 0.6 MB; the check reads 0.8 MB and takes under 5 ms. `test/update.sh` fails if a file in
`cli/` or `client/` is missing from the list. `update` prints its own lines instead; `lsp-gen` and `test-css` skip it
(machine-read output).

## Not done

- Per-package opt-out of a hook (`--no-hooks` is all or nothing).
- Globs in `PATHS`.
- A tool's stamp walks the whole path package, so an edit anywhere in it rebuilds the tool (about 3 s for goose-cms).
