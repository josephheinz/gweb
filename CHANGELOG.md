# Changelog

## v1.8.4

- A view with `@slot` may hold `gweb::Text`, `gweb::LongText`, a repeater (`T[>..<]`) or a foreign growable type (`cms::RichText`) in its Props. These failed `gweb build` in generated code (`types_render calls into its recursive cycle while non-fixed-size local p ... (§7.8)`), and `gweb gen` refused the text types. The view's `render` now takes the props JSON and reads the Props in each piece of the template between slots, so none is held across the slot. A slot inside `{#if}` or `{#for}` in such a view is a build error at the slot; `{#let}`/`{#var}` do not carry across a slot. See `docs/DESIGN-ADDENDUM-22-TEXT.md`. Test: `test/slotprops.sh`.

From goose-cms round 11 (dx11b):

- `gweb dev`: the message after a failed first build names every folder it watches, `views/` and `locales/` included (it did already watch them).

## v1.8.3

From goose-cms round 9 (dx10a, dx10b):

- `gweb test` and `gweb build` go through the dev compiler's cache (`docs/dev-builds.md`): a build whose C is the same as the last one links the last binary (`gweb build` after a change to `tests/` only, or `gweb test` with nothing changed: 3 to 5 s, was 55 s). `gweb test` builds with goose `-O0` and the C split in units compiled in parallel at `-O2`, so a change to a test compiles a few units (first build about 10 s, was 47 s). `GWEB_BUILD_CACHE=0` brings back the one-file build. The compiler wrapper also takes C that goose names other than `main.c`.
- Tools (`tool cms cli/cms.goose` and the like) are kept in `~/.cache/gweb/tools/`, keyed by their sources: a new app on the same goose-cms checkout or tag takes the binary (the `cms check` hook of a first `gweb dev`: 20 s, now under 1 s).
- `gweb dev`: when the server dies while serving a request (a handler's native stack overflow, for one) it names the request, says what such a crash usually is (a large struct such as `cms::Doc` copied; pass it by reference), and starts the server again. The dev server records the request in flight in `.gweb.dev/serving-N`.
- `gweb help` lists `--port` for dev. `gweb check`: an unknown `site::...` function says to run `cms check` first. A failed `expect_status` and `expect_contains` name the request (`GET shop.localhost/path`; `Tester.last`). A dev build's server started outside its folder says to use `gweb build` for a portable one.
- Docs: `docs/site/goose-for-site-developers.md`, a cheat sheet of the slips a site developer makes (no `?:`, text comparison, casts, `parse_int`, re-binding a `var`, struct literal order, void calls in templates).

## v1.8.2

From goose-cms round 8:

- `expect_contains` that fails prints the needle and a 200-byte excerpt of the body, not the whole body.

## v1.8.1

From goose-cms round 7 (D9):

- `gweb dev`'s `log` mail transport needs no sender: `GWEB_MAIL_FROM` defaults to `dev@localhost` (`gweb test` has `test@localhost`).
- New: `gweb::run_jobs(t)` in route tests runs the jobs a request queued and collects their mails; the job queue exists under `gweb test`. The README's `take_mails`/`jobs::run` order is corrected.
- New: `gweb::origin_ok(req, ctx, res)` for an anonymous form on a cacheable page (a route with `const CSRF = false;`): same-origin check by `Sec-Fetch-Site`, `Origin` or `Referer`. Route tests send an `Origin` header.
- `gweb dev` stops its server when it gets SIGTERM, SIGINT or SIGHUP (the server was left listening).
- Errors: a reserved word used as a name (`pad`, `type`, `where`, `self`) says so; `decode` without a struct named `*Form` says that is the rule.

## v1.8.0

- New: faster `gweb dev` rebuilds (`docs/dev-builds.md`). A goose-cms site, save to page served: a template text
  edit 9.6 s to 2.4 s, a new `{#if}` line 10 s to 3.5 s, a Goose edit 9.6 s to 3.2 s. Production builds are
  unchanged.
  - Template text of a dev build is read from `.gweb/lits` as the server starts, so a text edit leaves the C as it
    was and skips the C compile.
  - The C is split after goose into about four units per hardware thread, compiled at once, each object cached by
    a hash of what it was compiled from; strings and embedded files are named by content, so an edit recompiles one
    or two units. `GWEB_DEV_UNITS=0` compiles the C whole; anything unexpected in the C does that too.
  - Dev binaries are hard links where they can be (macOS checks each new executable on first run), the watcher
    looks every 100 ms, and a dev server stops in about 20 ms (job runners wait 50 ms, not 250).
  - A dev build's line shows its steps: `gen 0.04, goose 1.6, cc 0.5 (1 of 63 units), link 0.06`.
  Test: `test/devbuild.sh`.

From goose-cms reviews (`gweb-todo`): a mailer, feeds, and fixes.

- New: a mailer, `import gweb.ops.mail;`: `gweb::mail_send(ctx, m)`, transports by `GWEB_MAIL` (`log` in dev and test, `smtp://host:port`, `off`), `t.mails` in route tests. Plain SMTP to a loopback or private relay only (goose-net has no TLS; use a local relay, `docs/DEPLOY.md`); another host exits the server with 2. Send from a job for retries (README "Mail"). Tests: `test/mail_test.goose`, `test/mail.sh`. Was `docs/PROPOSAL-MAILER.md`.
- New: `gweb::Feed`: RSS 2.0 and Atom from one list (`import gweb.site.feed;`), `rfc822`, `rfc3339` and `xml_escape` public. Test: `test/routes.sh`.
- Fix: `http::set_header(res, "Content-Type", ...)` replaces the type; it left `text/plain` and added a second line. New `gweb::reply(res, status, type, body)` and `gweb::set_content_type` for RSS, XML, CSV.
- Change: `gweb::redirect` keeps a body and Content-Type the handler set on `res`; with none it sends neither, as before.
- Docs: a body over its limit gets the HTML page only for `Accept: text/html` (a browser's form post); curl and `fetch` send `*/*` and get JSON, by design (they look alike). Test: `test/routes.sh`.
- New: `save_upload` makes the missing folders of `dest` (mode 0700); `gweb::mkdir_p(dir)`. Docs: private upload storage.
- New: compile errors hint common slips: `.length()`, `.push_back`, `.substr`, `.contains`, `string` or `int` as a type, `+` on text. `.length` on text already had its hint (1.6), in `build`, `check` and `test`.
- Change: in `gweb test` a 4xx a handler answers is not logged as `gweb: error`. Docs: `http::code(res.status)`; an `expect_*` takes text temporaries, not a whole reply (goose binds no temporary to a `const&`).
- Already in 1.6, so not redone: `#gw-dev-error` only on a 5xx or crash.

## v1.7.0

From a blind developer review of a goose-cms site. Proposal for a mailer: `docs/PROPOSAL-MAILER.md`.

- Fix: the CSRF token is started per request, only when the reply's body shows it (a rendered `csrf_field` or `csrf_token`, from any template or `lib/` partial) or when `gweb::csrf_begin` runs. Was: a build-time scan for `gweb::csrf_` in a page's files started it on every request, so a catch-all `page.goose` with one form behind an `if` gave every page `Set-Cookie: gw_csrf` and `Cache-Control: no-store`. Every page `fn POST` and unsafe route method is still checked, whatever its GET rendered. `cache_store_key` now refuses a reply only when it shows the token. Tests: `test/routes.sh`, `test/csrf_test.goose`.
- New: an unknown function in a compiler error gets `(did you mean query?)` from its namespace (the file's own functions, a `lib/` namespace, or gweb's), or ``(lib/util.goose declares it: add `import lib.util;` to this file)`` when only the import is missing. Test: `test/devbuild.sh`.
- New: after an error in the app's own files, errors in gweb's generated or library code (`gweb.goose:676: cannot clear v while names is still used`) are left out, with a line that counts them; `--raw-errors` shows them. Test: `test/devbuild.sh`.
- New: `gweb::expect_not_contains(t, text, needle)` and `gweb::expect_no_header(t, res, name)` in route tests. Test: `test/routes.sh`.
- Docs: `req.method`'s `http::Method` variants (`Get`, `Head`, `Post`, `Put`, `Patch`, `Delete`, `Options`, `Other`); `find(text, x) >= 0` as "contains" in tests.

## v1.6.0

Additions and fixes for goose-cms (`NOTES-FOR-GWEB.md`). Proposal for a package's jobs (ask 11): `docs/PROPOSAL-PACKAGE-JOBS.md`.

- Docs: a page's `fn load(req, ctx, res)` keeps the headers it sets on `res` and still renders (a preview's `Cache-Control: no-store`); this already worked. goose-cms ask 7. Test: `test/routes.sh`.
- Docs: `morph(from, to, force, start, end)` and `swap(root, html, force)` from `/_gw/gwi.js` are public, with the range form. goose-cms ask 10. Test: `test/morph_export_test.mjs`.
- Docs: `send_file` streams within the call, so the caller may delete the file once it returns.
- New: a `tool` whose root writes `import views from "...";` builds against the app's generated views (`views::g_*`, `v_<group>_<Name>::read`), from a gen into `.gweb.tools/gen/`, and is rebuilt when the app's code or views change, so a package CLI needs no copy of the view readers. Test: `test/views.sh`.
- Docs: a tool may use goose-blob (or any package that needs gweb) by declaring `gweb`, `net` and the package in its root.
- New: `gweb::public_file(url, out) -> bool` reads the bytes of a `public/` file (the app's, or a package's at its mount) from server code: the embedded bytes, or the file on disk in a dev build. Test: `test/routes.sh`.
- New: goose's `no field access on a value of type u8[..40]` (or any array type) at `.length`, `.size` or `.count` ends with `(arrays and text have .len)`, in condensed errors and `--diagnostics json` (with `--raw-errors` too). Test: `test/devbuild.sh`.
- Change: in `gweb dev` only a crash or a 5xx error page carries `#gw-dev-error`, so a `gweb::fail(ctx, 404, ...)` no longer covers the page with "server error (click to dismiss)". goose-cms ask 17. Test: `test/errors.sh`.
- New: `const MIDDLEWARE = false;` in a `route.goose` skips the `before` and `after` of the middleware from the route's own source: a package's for a package route (a health check that needs no session, on any host), the app's for an app route. The app's middleware above a package's mount still runs, so a package cannot opt out of the app's. In a `page.goose`, or malformed, it is a build error at the line. goose-cms ask 14. Test: `test/packages.sh`.
- Fix: `gweb::not_found(ctx)` or `gweb::fail` in `app/sitemap.goose`'s `entries` or `robots` answers without the sitemap's `Cache-Control: public, max-age=3600`, now documented. Was: the 404 page carried it, so a proxy could keep it an hour. goose-cms ask 12. Test: `test/sitemap.sh`.
- New: `gweb::stream_file(s, root, rel) -> i64` writes a file into a stream in 256 KiB windows and `gweb::file_size(root, rel) -> i64` reads its size, with `send_file`'s path rules, so a download built while it is sent (a backup tar of a snapshot and its media) needs no temp file. goose-cms ask 13. Test: `test/cmsready.sh`.
- Fix: a view's `i64` field is drawn by a call with no `i64` past the sixth parameter (its labels travel in a struct), for the x86-64 Linux Goose issue with such parameters. The foreign-type `gw_field(out, name, v, label, help, editor, errs)` is unchanged: its seven parameters are references and slices, which that issue does not touch. goose-cms ask 8.
- New: route tests can set the client address and test uploads. `t.client_ip` is what `gweb::client_ip` reports (so a per-address rate limit has its own bucket per test address), and `t.trust_proxy = true` reads `X-Forwarded-For` as behind a proxy. `site::post_multipart(t, target, parts)` with `gweb::multipart_field` and `gweb::multipart_file` sends multipart bodies; files go to `t.upload_dir` (`.gweb.test/uploads`) with the server's limits, and an unsaved one is deleted after the reply. Was: a multipart route answered 500 and every request shared one rate-limit bucket. goose-cms asks 5 and 9. Test: `test/routes.sh`.
- New: `gweb::expect_eq(t, got, want, what)` for text and `i64`, which prints both values on failure. goose-cms ask 15. Test: `test/routes.sh`.
- New: in a mounted package's templates, views and components, `@asset("/x.js")` is the package's own `public/x.js` at its mount (`/admin/x.HASH.js`), so a package need not spell where it is mounted. Without such a file the URL is the one written, so `@asset("/admin/x.js")` keeps working. goose-cms ask 4. Test: `test/packages.sh`.
- Fix: a package's `app/` or `lib/` that mentions `gweb::subscribe(` or `gweb::websocket(` starts the push hub, as the app's do; its event stream answered 503. goose-cms ask 3. Test: `test/packages.sh`.
- Fix: a view with an empty `struct Props { }` builds: its `read`, `write`, `defaults`, `form` and `parse` are generated (they called a `gw_read_Props` that was not). goose-cms ask 1. Test: `test/views.sh`.

## v1.5.0

- New: a template compiler error is `file:line:col`, with an excerpt of about 80 characters around the column and a caret, not the whole generated-from line. Test: `test/devbuild.sh`.
- New: goose's `struct Props has no field x` names whose Props it is and lists its fields: `views/items/TeamMember: Props has no field "rol" (it has: title, role, photo, bio)`, or `app/page.goose: ...` for a page's. Test: `test/devbuild.sh`.
- New: `gweb test` condenses compiler errors as `build` does (`--raw-errors` shows goose's output).
- Change: a failing package hook ends with `` gweb: `cms check` failed (exit 1, hook from package cms) `` after its own output, instead of an error at the package's `gweb.package` line. An app's hook still names its `gweb.packages` line. Test: `test/hooks.sh`.
- New: a body over `--max-upload`, `--max-body` or `MAX_UPLOAD` from a browser form or navigation is a 413 page (the nearest `error.html`, or the built-in page) saying `This file is too large. The limit is 32 MiB.`, not raw JSON. Fetch, XHR and fragment requests still get JSON, now with that message. A route posted from a browser form gets the page too. Was: `{"error":"Payload Too Large"}` before the app ran (goose-cms editor review). Test: `test/forms.sh`.
- New: `fn too_large(req, ctx, limit)` beside `fn POST` in `page.goose` or `route.goose` handles that itself, e.g. `gweb::redirect(ctx, "...&ue=...", 303)` back to the form. It runs before the CSRF check, with an empty body. `ctx.too_large` is the limit; `gweb::size_text(out, n)` writes `32 MiB`. `gweb test` applies the limits. Test: `test/forms.sh`.
- Fix: a body over `--max-upload` or `--max-body` is not read, and the connection was closed at once, so a browser still sending could show a connection reset instead of the 413. The reply now says `Connection: close` and the connection lingers, reading and dropping the rest for up to 10 s (goose-net `close_lingering`). Needs goose-net with `close_lingering`. Test: `test/forms.sh`, goose-net `test/spool.sh`.
- Docs: Goose imports load a file into the whole program, so a view without `import lib.site;` still sees `site::` when another file imports it (README, `lib/`).

## v1.4.0

- New: `{#var n = e}` in page, layout and view templates: a mutable local, so a helper can fill it by reference (`{#var p = T { .. }}{#if fill(c, p)}`), as a root struct Props needs. Tests: `test/templates.sh`, `test/text.sh`.
- New: `gweb::Text` (128 characters, `<input>`) and `gweb::LongText` (65,536, `<textarea>`), growable text for view Props, in a `root struct Props` (Addendum 22). `FieldUi.max` changes the limit; `gen` warns `text-max` above 1 MiB. Reading never cuts them; a limit is a visible error that counts characters. A root struct may hold several repeaters, anywhere. A view with `@slot` keeps `u8[..N]` (Goose keeps no growable local across the slot's recursion); `gen` says so. Test: `test/text.sh`.
- New: `read_errs(json, p, errs)` in each view's namespace and `g_read_errs(name, json, out_json, errs, prefix)` in `views` name fields whose stored text was cut or is over its limit; `g_read_errs` also runs `validate`, so merged JSON can be checked. `g_form_req` shows these errors on a GET.
- New: `{props.gap}` for an enum prints its `ENUM_LABELS` label or variant name, not `Gap.Wide`; `gweb::enum_name(v)` is the stored name and `gweb::enum_label(v)` the label.
- New: `ITEM_LABEL` may name an enum field (its label) or a foreign field, through `ns::gw_label(out, v)`; `let ITEM_LABEL: T = "..."` is read too. With several repeaters, each whose item has the field shows it.
- New: `FieldMeta.chars` (the cap counts characters) and `gweb::form_text_max`.
- Change: `g_form_req` draws no `maxlength` (`g_form` keeps its 1.0 markup). `g_parse` says "Use at most 80 bytes (this is 93)." for a `u8[..N]`, and `gweb::check_length` counts characters, not bytes.
- New: dev builds (`gweb dev`, and `gweb build --dev`): Goose `-O0` and `cc -O0`, the C compile skipped when the C is unchanged, and `public/` served from disk so that a change there alone restarts the same binary. A goose-cms site: a template change 28 s to 5.8 s, a CSS change 28 s to 0.04 s. Production builds are unchanged. See `docs/dev-builds.md`, which also has the findings and a proposal for incremental builds in goose. Test: `test/devbuild.sh`.
- New: compiler errors show once each, with the source line, without the instantiation chain or the generated function (review finding 7). `--raw-errors` or `GWEB_RAW_ERRORS=1` shows goose's output. Test: `test/devbuild.sh`.

## v1.3.0

- New: `tool`, `run` and `hook` lines in `gweb.packages` and a package's `gweb.package` (a package with them says `gweb 1.3`). `gweb run NAME [args]` runs a command; a hook runs before `gweb build`, `start`, `export` and `dev` when its paths change, and a failing hook stops the build like a compile error. A tool is a Goose program gweb builds into `.gweb.tools/bin/`, with the app's library sources. `--no-hooks` or `GWEB_HOOKS=0` skips hooks. Add `.gweb.tools/` to `.gitignore`. See Addendum 21. Test: `test/hooks.sh`.
- New: `gweb update [TAG]` moves the checkout, and `goose-net` and `goose-sqlite` beside it, to the latest release, rebuilds `gweb` and links it beside `goose` on `PATH`. Test: `test/update.sh`.
- New: a binary built from other sources than its checkout prints one line on every command: `gweb is older than its source in DIR: run gweb update (...)`. A different `VERSION` still stops the command, now with that line instead of "rebuild gweb".

## v1.2.0

Additions only.

- New: `gweb::redirect` takes URLs up to 8,192 bytes (was 1,024, cut silently), for presigned S3 URLs with a session token. A longer URL, or one holding CR, LF or NUL, is refused: the reply is a 500 with an error id and a log line that says why, never a cut URL. A `Location` that does not fit beside the reply's other headers (goose-net's 4,096 bytes in all) is a bare 500 too. Test: `test/errors.sh` (a 3 KiB URL whole, 9,000 bytes refused, CR LF refused).
- New: the Dockerfile installs the C libraries of the app's Goose packages. The build stage runs `gweb gen`; when the generated root imports goose-blob it adds `libcurl4-openssl-dev`, and the runtime `libcurl4` and `ca-certificates`; goose-postgres adds `libpq-dev` and `libpq5`. `--build-arg APT_BUILD=...` and `APT_RUN=...` name others. Copy `deploy/Dockerfile` into an existing app to get it. Test: `test/ops.sh` runs the step with `apt-get` echoed.
- New: `gw-trigger="input 250ms"` on a GET `<form gw-target>` submits it as you type, after a pause of 50 to 2,000 ms; Enter sends at once and the last request wins. It lives in a new module, `/_gw/gwq.js` (290 bytes, ceiling 384), served only to pages that use it. `gw-url` on a link or GET form puts the fetched URL in the address bar with `history.replaceState` once the fragment lands (in `gwf.js`, 1,517 of its 1,536 bytes). Misplaced or malformed attributes are build errors. Tests: `test/frag_test.mjs`, `test/fragments.sh`.
- New: enum labels in view forms. `let ENUM_LABELS = [gweb::EnumLabel { ty, variant, label }];` shows labels in the `<select>`, and `editor: "radio"` draws a radio group. Values and JSON keep variant names; views without them render as before. Tests: `test/views.sh`.
- Fix: `gw-loading`, `gw-trigger` and `gw-url` no longer warn `unknown-attribute`.
- Docs: "Media storage" with goose-blob (`docs/site/packages.md`), the Docker C libraries (`docs/DEPLOY.md`).

## v1.1.0

A minor release: additions, and fixes that keep documented behaviour.

- New: Goose packages for an app. `package NAME SOURCE` in `gweb.packages` (or in a package's `gweb.package`) declares a library such as goose-postgres in the generated root, so app files say `import pg;`. Works for build, `test`, `check`, `lsp-gen` and `export`. A path, `owner/repo@tag` or a git URL. `GWEB_PKG_NAME` overrides a source. Conflicting versions and reserved names are errors at the line. See `docs/site/packages.md`. Tests: `test/pkgdeps.sh` (a C-free package) and `test/pgdeps.sh` (goose-postgres, skipped without a checkout, libpq or `pg_ctl`).
- New: `g_form_req(out, req, name, json, errs, prefix)` (and `form_req` in the view's namespace), the rich generated form. It shows the posted text of a field that failed (the Addendum 20 gap: `g_parse` keeps a default for text that did not parse), links help text to its control (`id="NAME-help"` and `aria-describedby="NAME-help NAME-error"`), and draws repeater controls: Up, Down, Remove and Add as submit buttons named `PREFIX+field.act`, which `g_parse` applies (it returns false with no errors, so the page draws the form again). `let ITEM_LABEL = "field";` labels each item's legend. `g_form` and `form` keep their markup. Tests: `test/richforms.sh`.
- New: `@slot()` inside `<title>`, `<textarea>`, `<script>` or `<style>` of a layout or view is a build error at the line (it used to compile to text or a stray call). Tests: `test/slotcheck.sh`.
- New: a fragment or boosted request whose session expired gets `401` and a `GW-Login` header from `require_login`, not the 303 that morphed the login page into the target. The runtimes (`gwf.js`, `gwn.js`) send `GW-Auth: 401` and fire a cancelable `gw:unauthorized` event on `window`, then navigate to the requested URL (the server redirects to the login). 1.0 documents the redirect, so the change is gated on that header: a request without it, from a browser, a script or an older runtime, still gets the 303. `gwn.js` is re-minified within its ceiling (its link selector and fetch-error path are shorter). Tests: `test/unauth_test.goose`, `test/unauth_test.mjs`.
- New: `gweb::image_size(data) -> w, h, known` and `gweb::image_size_file(path)` at run time (`import gweb.site.image;`). The build-time reader of `@image()` moved into `site/image.goose`; `cli/image.goose` is a symlink to it, so both read alike. `@image()` output is unchanged. Test: `test/image_test.goose`.
- New: `FileOptions.sandbox` sends `Content-Security-Policy: sandbox` for any type, streamed files included (HTML and SVG always got it). Test: `test/sandbox_test.goose`.
- New: `jobs::every_local(s, name, ms, job)`, a schedule that still fires under `--no-schedule`, for work each instance does itself. Test: `test/everylocal.sh`.

## v1.0.0

The API freeze. `docs/site/stability.md` lists exactly what is stable. Every `Breaking:` line below is covered by
`sh tools/migrate-v1.sh [DIR]`, which does the renames, the `.gweb*` paths and the `--access-log` flag, and prints a
reminder for what it cannot do. `test/migrate.sh` runs it on the v0.7.0 fixtures and the tutorial and builds the result.

- Breaking: generic public functions have prefixed names. `gweb::write` and `end` are `stream_write` and `stream_end`; `send` is `socket_send`; `debug`, `info`, `warn` and `error` are `log_debug`, `log_info`, `log_warn` and `log_error`; `field`, `log`, `emit` and `render` are `log_field`, `log_event`, `log_emit` and `log_render`; `count` and `gauge` are `metric_count` and `metric_gauge`. `tools/migrate-v1.sh` renames them.
- Breaking: the generated folders are `.gweb`, `.gweb.dev`, `.gweb.test`, `.gweb.check`, `.gweb.lsp` and `.gweb.uploads` (were `.gooseweb*`). Update `.gitignore`, Dockerfiles and scripts. `tools/migrate-v1.sh` does.
- Breaking: the server flag `--log` is `--access-log` (`Config.log` is `Config.access_log`). The old flag is refused with a message that names the new one. `--log-format` and `--log-level` are unchanged. `tools/migrate-v1.sh` does.
- Breaking: `gweb::form_int(req, id, out, errs, required)`, the form decoder, is `gweb::form_i64`. The two-argument reader `form_int` keeps its name. `form_enum` moved to `gweb.forms.valid`. `tools/migrate-v1.sh` renames the decoder.
- Breaking: `gweb::cookie_or` and `gweb::cookie_int` percent-decode the value, as `Set-Cookie` writes it, and `cookie_or` returns an owned `u8[>..]` (was a slice). A Props field that held the result must be `u8[>..]` or `u8[..N]`. New: `gweb::cookie_raw` reads the bytes as sent. `tools/migrate-v1.sh` prints a reminder.
- Breaking: `X-Forwarded-Proto` counts only under `GWEB_TRUST_PROXY`. Behind a TLS proxy, set it, or the session and CSRF cookies lose `__Host-` and `Secure`, and `site_url` stays `http`. See DEPLOY-PROXY.
- Breaking: `gweb dev` binds `127.0.0.1` (was all interfaces). `gweb dev --host 0.0.0.0` or `GWEB_HOST` opens it. `start` and the server still bind `0.0.0.0`.
- Breaking: one config rule. Flags and `GWEB_*` variables are the same set, with the same parser, and a bad value exits 2 with a message that names the flag or variable (some used to be ignored). Precedence is flag, then environment (real, then `.env` files), then default. Dev defaults apply only under `--dev-id` and never override either.
- Breaking: names that begin with `_` are internal, and generated-code plumbing and module-private helpers got the prefix (`gweb::new_ctx` is `gweb::_new_ctx`, `gweb::respond` is `gweb::_respond`, and so on). Documented names are unchanged. `tools/migrate-v1.sh` renames the ones an app or a test may have called. `put`, `raw`, `arg`, `has` and `json_text` are not renamed: only generated code calls them. They are not stable.
- Breaking: `gweb::reserved_prefixes()` includes `__gweb`.
- Breaking: `gweb::FieldErrors` holds 64 entries (was 16). When more are added, the last one is a form-level error and the rest are dropped, so an overflow is visible.
- Breaking: `gweb.package` takes a semver minimum: `gweb 1.0` accepts any 1.x. A package that needs a newer gweb stops the build with the two versions named.
- The server's startup line changed. Its text is not stable.
- New: a package learns its mount. `gweb gen` writes a `NAME::MOUNT` constant for each mounted package (`"/admin"`; `""` at the root).
- New: configurable limits `--max-upload-parts` (64), `--max-upload-files` (8, at most 16) and `--max-upload-text` (65536), with `GWEB_MAX_UPLOAD_PARTS`, `_FILES` and `_TEXT`, and the Config fields `upload_parts`, `upload_files`, `upload_text`. `gweb::markdown(out, src, max_input)` takes the input cap. The README has a Limits table of what is configurable and what is fixed (a fixed limit may grow, never shrink).
- New: `gweb help`, `gweb --help`, `gweb -h` and `gweb COMMAND --help`; `server --help`. A wrong command line prints the reason and the usage on stderr and exits 2. `docs/site/cli.md` is current.
- New: `send_file` sends `Last-Modified`, answers `If-Modified-Since` with 304, and a HEAD for a streamed file sends `Content-Length`. Range requests are not implemented.
- Docs: the README Signatures block lists every hook; `docs/site/stability.md` is the 1.0 contract.

## v0.7.0

Made ready for a CMS package (Addendum 20). The integration fixture is `test/cmsready/`.

- `gweb::send_file(req, ctx, res, root, rel, opts)` in `gweb.http.files`: serves a file under a root with `Content-Type`, `ETag` and 304, `Cache-Control` (immutable or revalidate), HEAD, `Content-Disposition`, and a window stream above `stream_over`. Refuses `..`, dotfiles and symlinks out of the root. Also `gweb::mime_type`, `gweb::file_path_ok`, `gweb::FileOptions`.
- `gweb.packages` takes git URLs: `file:///path/repo.git@tag` and `https://host/path@tag`, cloned into the package cache under `url/`.
- Views: `validate` errors get the form prefix, so the generated form shows them. `g_parse` writes the JSON it read after an error, so a form can be drawn again as typed.
- Route tests: `t.host` sets the `Host` header.

## v0.6.0

Library work toward v1 (the gweb side of the CMS design, Addendum 19).

- Views: `views/<group>/<Name>.goose` and `.html` get a generated JSON codec, admin form, form parser and a by-name registry (`import views;`). `@slot("x")` holes, `gweb::ViewMeta`, `FieldUi`, `Renamed`. A package's `views/` merges. See DESIGN-ADDENDUM-19.
- `gweb::markdown(out, src)` and `gweb::markdown_text(out, src, max)`: a safe Markdown subset in Goose.
- `gweb::cache_serve_key`, `cache_store_key` and `epoch_bump()`: your own page-cache keys, and one call that clears every worker's cache.
- `gweb::sitemap_base(s, url)` and an optional `fn robots(req, ctx, out)` in `app/sitemap.goose`.
- `gweb::reserved_prefixes()` is generated into `main.goose`.
- `export { morph }` in `gwi.js` (`gwi.min.js` is 4,079 bytes).
- `app/state.goose` may declare `const VARIABLE_MSG = true;` to send a `Msg` with a variable-size payload (`Msg..`).
- Nested package mounts (`/admin/shop` inside `/admin`) are documented and tested.

## v0.5.1

First release built and tested by CI on macOS and Linux. No API change.

- Linux: test fixes for dash (a reaped server counted as running) and for `usleep` under `-std=c11`.
- `ops.sh` sends its 20 handoff requests however slow the machine.

## v0.5.0

- Breaking: environment variables are `GWEB_*`: `GWEB_SECRET`, `GWEB_CSP`, `GWEB_WORKERS`, `GWEB_TRUST_PROXY`, `GWEB_HSTS`, `GWEB_SESSION_IDLE`, `GWEB_SESSION_MAX`, `GWEB_SECURITY_HEADERS`. The server refuses to start while an old `WEB_*` name is set. `sh tools/migrate-v0.5.sh` renames them in `.env` files, units and Dockerfiles.
- Breaking: `GOOSE_WEB_HOME` is `GWEB_HOME`, and `GWEB_WEB` is `GWEB_SRC`.
- Server log lines start with `gweb:` (was `goose-web:`).
- CI: GitHub Actions test all three repos on macOS and Linux and publish a release for each `v*` tag.

## v0.4.0

Breaking: the package is `gweb` and its modules are in folders. `sh tools/migrate-v0.4.sh` in an app rewrites its imports and calls.

- The repository is `josephheinz/gweb` (was `goose-web`). `import gweb from "josephheinz/gweb@v0.4.0";`
- `web::` is `gweb::`, and `import web;` is `import gweb;`.
- Modules moved:

  | v0.3 | v0.4 |
  |---|---|
  | `web.session`, `crypto`, `csrf`, `rate`, `cors` | `gweb.auth.*` |
  | `web.form`, `valid`, `upload` | `gweb.forms.*` |
  | `web.cache`, `static`, `stream`, `push` | `gweb.http.*` |
  | `web.template`, `meta`, `sitemap`, `i18n`, `errors` | `gweb.site.*` |
  | `web.ops` | `gweb.ops.log` |
  | `web.jobs`, `owner` | `gweb.ops.*` |
  | `web.testing` | `gweb.testing` |

- goose-net and goose-sqlite are tagged v0.4.0 with no code change.

## v0.3.0

Needs the matching goose-net release (spool mode, `net::Hub`, `Loop.detach`, chunked responses, `http::accepts`, `net.lifecycle`).

- Forms: a `*Form` struct in `page.goose` or `route.goose` gets a generated `decode`. New `web::valid`: `FieldErrors`, `check_email`, `check_range`, `check_length`, `check_one_of`, `field_error`, `invalid`, `field_value`, `errors_json`, `set_status`, `unprocessable`.
- 422: a form with errors answers 422. `gwi.js` morphs a 422 fragment reply instead of refusing it.
- Uploads: multipart posts, `web::Upload`, `save_upload`, `check_upload`, `const MAX_UPLOAD`. Flags `--max-upload N` (default 32 MiB) and `--upload-dir D` (default `.gweb.uploads`). Large bodies are spooled to disk. `gw-target` forms with `enctype="multipart/form-data"` send `FormData`.
- Error pages: `error.html` (nearest wins) and `web::fail`. A crashed request now gets the error page instead of hanging; `gweb dev` shows the abort text and source lines. Build errors in the dev overlay get source lines.
- `loading.html` and `gw-loading`: a loading state for slow fragment requests.
- A page `fn POST` or `fn load` may take `res`; `web::done(ctx)` ends the reply itself.
- Breaking: `web::Outcome` has two new variants, `Error` and `Done`. An exhaustive `match` on it needs arms for both.
- Behaviour change: when a worker crashes, its other keep-alive connections are now closed (they leaked before). Clients reconnect.
- `.env` files (`.env.<env>.local`, `.env.local`, `.env.<env>`, `.env`), `WEB_SECRET` with rotation, and typed `web::env_*` helpers.
- Signed cookies and stateless sessions: `web::login`, `logout`, `session`, `require_login`, `require_login_api`, `safe_next`.
- PBKDF2-HMAC-SHA-256 passwords: `web::password_hash`, `password_verify`, `password_needs_rehash`.
- Rate limits shared by all workers: `web::rate_limit`, `rate_limit_key`; `WEB_TRUST_PROXY` for `client_ip`.
- CORS: `web::cors`.
- CSP with a per-request nonce, opt-in with `WEB_CSP`; `web::nonce` for templates; optional `WEB_HSTS`.
- Behaviour change: every response now carries `X-Content-Type-Options`, `Referrer-Policy` and `X-Frame-Options` headers. Opt out with `WEB_SECURITY_HEADERS=0`.
- Behaviour change: `web::login` rotates the CSRF token.
- Apps that use sessions refuse to start in production without `WEB_SECRET`.
- `/_gw/` runtime modules stay at plain URLs (revalidated), so each module loads once.
- Behaviour change: `gweb build`, `start` and `export` minify `public/**/*.css`. `gweb dev` does not. Pass `--no-minify` to keep the files as written.
- Static files are served at a hashed URL too (`/css/site.3f9a1c2b.css`) with `Cache-Control: public, max-age=31536000, immutable`. The plain URL is unchanged. A hashed URL that equals another URL is a build error.
- Text static files of 1 KB or more get a gzip variant at build time, sent to clients that accept it. gweb now links zlib.
- `@asset("/path")` writes the hashed URL; `web::asset_url(path)` does the same at run time.
- `@image(path, alt[, attrs])` writes an `<img>` with its size read at build time, lazy loading and an `@2x` `srcset`.
- `ctx.meta` with `web::meta_description`, `meta_canonical`, `meta_image` and `meta_robots`, and `@meta()` in `layout.html` for description, canonical, robots, Open Graph and Twitter tags. `web::site_url(req, out)` and the `SITE_URL` variable give the base URL.
- `app/sitemap.goose` turns on `/sitemap.xml` and `/robots.txt`; `web::sitemap_add` adds entries and `const SITEMAP = false;` leaves a page out.
- `const REVALIDATE = N;` in `page.goose` caches a page's GET reply per worker for N seconds, with an ETag. A page that uses a CSRF token cannot have it.
- `gweb export [-o DIR]` writes the site as static files. A dynamic page lists its paths in `fn static_paths()`.
- Streaming responses: `web::stream_begin`, `web::write` and `web::end(ctx, s)`.
- Server push: `web::subscribe` (SSE) and `web::websocket`, with `web::publish`, `web::send`, `web::close_socket` and `web::subscribers`, over one `net::Hub` thread. `app/socket.goose` handles `open`, `message` and `close`. `web::websocket` refuses a cross-origin `Origin`.
- New `Config` flag `--export DIR`; new `Ctx` fields `meta`, `hub`, `conn_fd`.
- New `docs/DEPLOY-PROXY.md`: Caddy and nginx in front of goose-web.
- Route tests: `web.testing` and `tests/*.goose`, run by `gweb test` against the real dispatcher with no socket.
- i18n: `locales/<tag>.txt` catalogs compile to a typed `t::` module; the locale comes from the `locale` cookie or `Accept-Language`.
- Operations: `/__gweb/health` and `/__gweb/ready`; graceful shutdown on SIGTERM and SIGINT (`--drain-ms`, `--drain-delay-ms`); SIGUSR2 and systemd socket activation restart without dropping a request (`net.lifecycle` in goose-net).
- Logs: `--log-format json`, `--log-level`, request ids, and `web::info`, `web::log` and friends.
- Metrics (`--metrics`, Prometheus text at `/__gweb/metrics`) and OpenTelemetry tracing (OTLP/HTTP JSON, `traceparent`).
- Background jobs and schedules: `app/jobs.goose`, `jobs::enqueue`, `jobs::every`, `jobs::cron`, `--no-schedule`.
- Linux and Docker: a Dockerfile and `.dockerignore` for new apps, systemd units in `deploy/`, `test/linux.sh`, and `docs/DEPLOY.md`. Windows is supported through WSL2 and Docker only.
- Jobs can `web::publish` to SSE and WebSocket clients.
- Behaviour change: `/__gweb/` is reserved; an `app/__gweb` folder is a build error.
- Reactive components: `@prop`, `@state`, `@computed`, `@watch`. gweb finds which markup reads which names and, after a handler, updates only those text nodes, attribute lists and `{#if}`/`{#for}` blocks. Markup names state directly (`{count}`). A throwing handler leaves the page unchanged. `struct State` components still work.
- Pages call reactive components with named props: `@Counter(start: 3, label: p.name)`.
- Async handlers: `await http::get` and `http::post` with typed replies. A failure restores what the handler wrote and raises `gw:error`.
- Lifecycle: `@mount`, `@unmount`, `@every(ms)`.
- Events: `dblclick`, `keydown`, `keyup`, `focus`, `blur`, and modifiers `on:keydown.enter.prevent`, `stop`, `300ms`.
- Nested components with props (`@Card(title: x, key: id)`) and child events (`@event fn`, `on:change="picked"`).
- Shared stores: `stores/Name.gshtml` and `@use`, optionally kept in `localStorage`.
- Client navigation: `<body gw-boost>`.
- Transitions: `gw-enter` and `gw-leave`.
- Server push, client half: `gw-sse="/events"`, and `web::sse_event`, `web::sse_fragment`, `web::sse_store`.
- Warnings: `gen`, `build`, `start` and `test` take `--strict` and `--diagnostics json`. New codes: `unkeyed-for`, `unknown-attribute`, `unknown-event`, `child-key`, `prop-keyword`, `state-keyword`, `computed-keyword`, `computed-no-state`, `watch-no-state`, `state-unused`. `gweb dev` shows warnings in a corner box.
- Runtime split: `gwi.js` is the 4 KB core. Fragments and each other feature are optional modules (`gwf`, `gwh`, `gwl`, `gwm`, `gwc`, `gwn`, `gws`, `gwt`, `gwe`), served only to sites that use them. Fragment pages now load `gwf.js` and `gwi.js`.
- Changed: a component root with a text part gets `<!--g-->` markers in its HTML.

## v0.2.1

- Fix: `gweb test` no longer deletes `.gweb/`; it generates into `.gweb.test/`. Add `.gweb.test/` to `.gitignore`.

Pins goose-net v0.2.1 and goose-sqlite v0.2.1.

## v0.2.0

- Breaking: CSRF tokens are on by default. Every page `fn POST` and every `route.goose` `POST`, `PUT`, `PATCH` or `DELETE` answers 403 until its forms add `@web::csrf_field(ctx)`, or the route declares `const CSRF = false;`. `Sec-Fetch-Site: same-site` is refused as well as `cross-site`, and `web::cross_site` is removed.
- Catch-all routes: a `[...name]` folder matches one or more trailing segments and `[[...name]]` zero or more. `web::param` returns the raw tail, and `web::path_decode` decodes it. A tail over 1,024 bytes, or with an empty or dot segment, `%2F`, `\` or a control byte, gets a 404.
- Behaviour change: `public/` files are now tried before every route for GET and HEAD. A public file that an `[id]` route at the same depth used to shadow is now served. A route that has the same URL as a public file is still a build error.
- A route folder deeper than 16 folders is now a build error; it was silently never matched.
- Keyed morph: `gw-key` keeps element identity and focus when list items move, appear or disappear.
- SQLite writes: the owner-thread writer pattern, documented, with the shop's `/db/todos` demo; needs goose-sqlite v0.2.0.

Pins goose-net v0.2.0 and goose-sqlite v0.2.0.

## v0.1.1

The repos moved from `jheinz-bzs` to `josephheinz`. `gweb` now pins `josephheinz/goose-*@v0.1.1`.

Pins goose-net v0.1.1 and goose-sqlite v0.1.1.

## v0.1.0

First tagged release: file-based routes, templates, components, fragments, cookies, owner state, and the `gweb` command line.

Pins goose-net v0.1.0 and goose-sqlite v0.1.0.
