#!/bin/sh
# gweb's dev-build suite (docs/dev-builds.md).
#
#   GOOSE=/path/to/goose test/devbuild.sh
#
# 1. Compiler errors: each once, with its source line and no instantiation chain (page.html, a component, page.goose
#    keeps goose's caret); a template error has its column and a short excerpt; a missing field names its view's
#    Props and fields; --raw-errors and GWEB_RAW_ERRORS=1 show goose's own output; gweb check and test condense too;
#    an unknown function's hints and the left-out library errors (1.7).
# 2. gweb build --dev: unhashed URLs; a rebuild with nothing changed skips the C compile; the binary reads public/
#    from disk, uncached.
# 3. gweb dev: a change under public/ alone needs no compile and restarts the same binary (pages reload); a page
#    change rebuilds.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4041}
[ -x "$GWEB" ] || { echo "devbuild.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-devbuild.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
PID=""
DEVPID=""
stopdev() {   # gweb dev and its server (see test/hooks.sh)
  kill -TERM -"$DEVPID" 2>/dev/null || { pkill -TERM -P "$DEVPID" 2>/dev/null; kill -TERM "$DEVPID" 2>/dev/null; }
  for i in $(seq 1 20); do kill -0 "$DEVPID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -"$DEVPID" 2>/dev/null || { pkill -KILL -P "$DEVPID" 2>/dev/null; kill -KILL "$DEVPID" 2>/dev/null; }
  DEVPID=""
}
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$DEVPID" ] && stopdev
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }
fresh() { rm -rf "$WORK/$1"; cp -R "$HERE/devbuild/site" "$WORK/$1"; }
count() { printf '%s\n' "$1" | grep -cF -- "$2"; }
URL="http://127.0.0.1:$PORT"

# 1. Errors. A page.html error is in a generated function goose excerpts whole, once per instantiation.
fresh bad
printf '<!doctype html>\n<h1>Hi {props.n}</h1>\n<p>{props.nosuch}</p>\n@Card(props.card)\n' > "$WORK/bad/app/page.html"
printf '<script goose>\nstruct State { n: i64 }\n</script>\n<b>{also_missing + s.n}</b>\n' > "$WORK/bad/components/Card.gshtml"
out=$("$GWEB" -C "$WORK/bad" build 2>&1); rc=$?
check "$([ "$rc" = 1 ] && echo ok)" "a template error fails gweb build (exit $rc)"
check "$([ "$(count "$out" 'app/page.html:3:5: error: app/page.goose: Props has no field "nosuch" (it has: n, card)')" = 1 ] && echo ok)" \
  "the page.html error is shown once, at its column, naming the Props and its fields"
check "$([ "$(count "$out" 'components/Card.gshtml:4:5: error: unknown identifier: also_missing')" = 1 ] && echo ok)" "the component error is shown once, at its .gshtml line and column"
check "$(printf '%s\n' "$out" | grep -A1 -xF '<p>{props.nosuch}</p>' | grep -qxF '    ^~~~~~~~~~~~' &&
         printf '%s\n' "$out" | grep -A1 -xF '<b>{also_missing + s.n}</b>' | grep -qxF '    ^~~~~~~~~~~~' && echo ok)" "each error is followed by its source line and a caret"
check "$(! printf '%s\n' "$out" | grep -qF 'instantiated from' && ! printf '%s\n' "$out" | grep -qF 'out.append(' && echo ok)" "no instantiation chain and no generated code"
check "$(! printf '%s\n' "$out" | grep -qF ' | ' && echo ok)" "no numbered excerpt (errors.txt has those)"
[ "$fail" = 0 ] || show "$out"
raw=$("$GWEB" -C "$WORK/bad" build --raw-errors 2>&1)
check "$(printf '%s\n' "$raw" | grep -qF 'instantiated from' && printf '%s\n' "$raw" | grep -qF 'gweb::put(out, props.nosuch)' && echo ok)" "--raw-errors shows goose's whole output"
check "$([ "$(count "$raw" 'app/page.html:3: error:')" -gt 1 ] && echo ok)" "--raw-errors keeps the repeats"
raw2=$(GWEB_RAW_ERRORS=1 "$GWEB" -C "$WORK/bad" build 2>&1)
check "$(printf '%s\n' "$raw2" | grep -qF 'instantiated from' && echo ok)" "GWEB_RAW_ERRORS=1 shows goose's whole output"
out=$("$GWEB" -C "$WORK/bad" check 2>&1)
check "$([ "$(count "$out" 'app/page.html:3:5: error:')" = 1 ] && ! printf '%s\n' "$out" | grep -qF 'instantiated from' && echo ok)" "gweb check condenses as build does"
"$GWEB" -C "$WORK/bad" dev --once >/dev/null 2>&1
check "$([ "$(grep -c '^app/page.html:3:5: error:' "$WORK/bad/.gweb.dev/errors.txt")" = 1 ] && grep -qF '>   3 | <p>{props.nosuch}</p>' "$WORK/bad/.gweb.dev/errors.txt" && echo ok)" \
  "dev --once: errors.txt has each error once, with its excerpt"
# A long template line: an excerpt around the column, not the whole line.
fresh long
pad=$(printf 'word %.0s' $(seq 1 30))
printf '<!doctype html>\n<p>%s{props.nosuch}%s</p>\n' "$pad" "$pad" > "$WORK/long/app/page.html"
out=$("$GWEB" -C "$WORK/long" build 2>&1)
src=$(printf '%s\n' "$out" | sed -n 2p)
car=$(printf '%s\n' "$out" | sed -n 3p)
at_src=$(awk -v s="$src" 'BEGIN { print index(s, "props.nosuch") }')
at_car=$(awk -v s="$car" 'BEGIN { print index(s, "^") }')
check "$(printf '%s\n' "$out" | grep -qF 'app/page.html:2:155: error: ' && [ "${#src}" -lt 100 ] && printf '%s' "$src" | grep -q '^\.\.\..*\.\.\.$' &&
         [ "$at_src" -gt 0 ] && [ "$at_src" = "$at_car" ] && [ "$(printf '%s' "$car" | tr -d ' ')" = '^~~~~~~~~~~~' ] && echo ok)" \
  "a long line is shown as a short excerpt, the caret under the column"
[ "$fail" = 0 ] || show "$out"
# Another view's Props: the view is named, with its fields.
rm -rf "$WORK/views"; cp -R "$HERE/views/site" "$WORK/views"
printf '{#var a = v_widgets_Hero::Props { .. }}<p>By {a.titel}</p>\n<div class="text">@gweb::markdown(props.body)</div>\n' > "$WORK/views/views/widgets/Text.html"
out=$("$GWEB" -C "$WORK/views" test 2>&1)
check "$(printf '%s\n' "$out" | grep -qxF 'views/widgets/Text.html:1:47: error: views/widgets/Hero: Props has no field "titel" (it has: title, count, shout, badge, more, ctas)' &&
         ! printf '%s\n' "$out" | grep -qF 'instantiated from' && echo ok)" "another view's Props is named, with its fields (gweb test condenses too)"
printf '<div class="text">{props.bdy}</div>\n' > "$WORK/views/views/widgets/Text.html"
out=$("$GWEB" -C "$WORK/views" test 2>&1)
check "$(printf '%s\n' "$out" | grep -qxF 'views/widgets/Text.html:1:20: error: views/widgets/Text: Props has no field "bdy" (it has: body)' && echo ok)" \
  "the view's own props too"
[ "$fail" = 0 ] || show "$out"
# .length, .size or .count on an array or text: the hint (1.6), in a template, a .goose file and JSON diagnostics.
fresh len
mkdir -p "$WORK/len/app/len"
printf 'import std;\nimport net.http;\nimport gweb;\nstruct Props { title: u8[..40] }\nfn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props { return Props { title: "x" }; }\n' > "$WORK/len/app/len/page.goose"
printf '<p>{props.title.length}</p>\n' > "$WORK/len/app/len/page.html"
out=$("$GWEB" -C "$WORK/len" build 2>&1)
check "$(printf '%s\n' "$out" | grep -qxF 'app/len/page.html:1:5: error: no field access on a value of type u8[..40] (arrays and text have .len)' && echo ok)" \
  "a template's .length on text: the .len hint"
[ "$fail" = 0 ] || show "$out"
out=$("$GWEB" -C "$WORK/len" build --diagnostics json 2>&1)
check "$(printf '%s\n' "$out" | grep -qF '"message":"no field access on a value of type u8[..40] (arrays and text have .len)"' && echo ok)" "the hint in JSON diagnostics"
out=$("$GWEB" -C "$WORK/len" build --diagnostics json --raw-errors 2>&1)
check "$(printf '%s\n' "$out" | grep -qF '(arrays and text have .len)"' && echo ok)" "the hint in JSON diagnostics with --raw-errors"
printf '<p>{props.title.len}</p>\n' > "$WORK/len/app/len/page.html"
printf 'fn gw_count(xs: const i64[:]) -> i64 { return xs.count; }\n' >> "$WORK/len/app/len/page.goose"
out=$("$GWEB" -C "$WORK/len" build 2>&1)
check "$(printf '%s\n' "$out" | grep -qxF 'app/len/page.goose:6: error: no field access on a value of type const i64[:] (arrays and text have .len)' && echo ok)" "a .goose file's .count on an array: the hint"
[ "$fail" = 0 ] || show "$out"
# 1.7: an unknown function's did-you-mean and missing lib import; library errors after an app error are left out.
fresh hint
mkdir -p "$WORK/hint/app/hint" "$WORK/hint/lib"
printf 'namespace util;\n\nfn hello() -> i64 { return 1; }\n' > "$WORK/hint/lib/util.goose"
printf 'import std;\nimport net.http;\nimport gweb;\nstruct Props { n: i64 }\nfn helper(x: i64) -> i64 { return x + 1; }\nfn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props { return Props { n: helpr(1) }; }\nfn b() -> i64 { return util::hello(); }\nfn c() -> i64 { return util::helo(); }\nlet KIDS = [];\n' > "$WORK/hint/app/hint/page.goose"
printf '<p>{props.n}</p>\n' > "$WORK/hint/app/hint/page.html"
out=$("$GWEB" -C "$WORK/hint" build 2>&1)
check "$(printf '%s\n' "$out" | grep -qF 'unknown function: helpr (did you mean helper?)' && echo ok)" "a bare unknown function: did you mean"
check "$(printf '%s\n' "$out" | grep -qF 'unknown function: util::hello (lib/util.goose declares it: add `import lib.util;` to this file)' && echo ok)" \
  "a lib function without its import: the import hint"
check "$(printf '%s\n' "$out" | grep -qF 'unknown function: util::helo (did you mean util::hello?)' && echo ok)" "a lib namespace's unknown function: did you mean"
check "$(printf '%s\n' "$out" | grep -qF 'can never receive elements' && ! printf '%s\n' "$out" | grep -qF 'gweb.goose:' &&
         printf '%s\n' "$out" | grep -qE '^gweb: [0-9]+ more errors? in generated or library code left out' && echo ok)" \
  "after an app error, gweb's own errors are left out and counted"
out=$("$GWEB" -C "$WORK/hint" build --raw-errors 2>&1)
check "$(printf '%s\n' "$out" | grep -qF 'gweb.goose:' && echo ok)" "--raw-errors keeps them"
[ "$fail" = 0 ] || show "$out"
# A .goose error: goose's excerpt is the source line, so its caret stays.
fresh goose
sed 's/n: 1,/n: 1 + "x",/' "$HERE/devbuild/site/app/page.goose" > "$WORK/goose/app/page.goose"
out=$("$GWEB" -C "$WORK/goose" build 2>&1)
check "$(printf '%s\n' "$out" | grep -q '^app/page.goose:7: error:' && printf '%s\n' "$out" | grep -qF 'return Props { n: 1 + "x",' && printf '%s\n' "$out" | grep -q '^ *\^~' && echo ok)" \
  "a page.goose error keeps goose's excerpt and caret"
[ "$fail" = 0 ] || show "$out"

# 2. gweb build --dev.
fresh ok
out=$("$GWEB" -C "$WORK/ok" build --dev 2>&1)
check "$(printf '%s\n' "$out" | grep -q 'built .gweb/server' && echo ok)" "gweb build --dev: $out"
check "$(grep -qF '_send_dev_static(res, "public/site.css"' "$WORK/ok/.gweb/main.goose" && ! grep -qF 'embed_file("../public/site.css")' "$WORK/ok/.gweb/main.goose" && echo ok)" \
  "a dev build reads public/ from disk instead of embedding it"
out=$("$GWEB" -C "$WORK/ok" build --dev 2>&1)
check "$(printf '%s\n' "$out" | grep -qF 'the C was unchanged, so its compile was skipped' && echo ok)" "a dev rebuild of the same C skips the compile: $out"
check "$([ -x "$WORK/ok/.gweb/server" ] && echo ok)" "and leaves .gweb/server in place"
echo '<p>new</p>' >> "$WORK/ok/app/page.html"
out=$("$GWEB" -C "$WORK/ok" build --dev 2>&1)
check "$(printf '%s\n' "$out" | grep -q 'built .gweb/server' && ! printf '%s\n' "$out" | grep -qF 'skipped' && echo ok)" "a page change compiles again: $out"
(cd "$WORK/ok" && exec ./.gweb/server --port "$PORT" --workers 1 >"$WORK/ok.log" 2>&1) &
PID=$!
up=""
for i in $(seq 1 40); do curl -s -m 2 -o /dev/null "$URL/" && { up=yes; break; }; sleep 0.25; done
check "$([ -n "$up" ] && echo ok)" "the dev binary serves: $(cat "$WORK/ok.log")"
page=$(curl -s -m 5 "$URL/")
check "$(printf '%s\n' "$page" | grep -qF 'href="/site.css"' && printf '%s\n' "$page" | grep -qF '<p>new</p>' && echo ok)" "the page links the unhashed URL: $page"
check "$(curl -s -m 5 "$URL/site.css" | grep -qF 'color: red' && echo ok)" "/site.css"
echo 'h1 { color: blue; }' > "$WORK/ok/public/site.css"
check "$(curl -s -m 5 "$URL/site.css" | grep -qF 'color: blue' && echo ok)" "a changed public/ file is served without a rebuild"
check "$(curl -s -m 5 -D - -o /dev/null "$URL/site.css" | tr -d '\r' | grep -qix 'cache-control: no-store' && echo ok)" "uncached"
kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""

# 3. gweb dev.
fresh dev
D="$WORK/dev"
set -m
"$GWEB" -C "$D" dev --port "$PORT" >"$WORK/dev.out" 2>&1 &
DEVPID=$!
set +m
up=""
for i in $(seq 1 120); do sleep 0.5; curl -s -m 2 -o /dev/null "$URL/" && { up=yes; break; }; done
check "$([ -n "$up" ] && echo ok)" "gweb dev answers: $(cat "$WORK/dev.out")"
waitfor() {   # waitfor N: the dev output has N changes seen and N + 1 builds
  for i in $(seq 1 120); do
    sleep 0.25
    [ "$(grep -c 'change seen' "$WORK/dev.out")" -ge "$1" ] && [ "$(grep -c 'built .gweb/server' "$WORK/dev.out")" -gt "$1" ] && return 0
  done
  return 1
}
id0=$(curl -s -m 5 "$URL/__gweb/id")
sleep 1
echo 'h1 { color: green; }' > "$D/public/site.css"
waitfor 1
check "$(grep -qF 'only public/ changed, so the last binary serves it' "$WORK/dev.out" && echo ok)" "a public/ change needs no compile: $(tail -n 3 "$WORK/dev.out")"
up=""
for i in $(seq 1 40); do id1=$(curl -s -m 2 "$URL/__gweb/id"); [ -n "$id1" ] && [ "$id1" != "$id0" ] && { up=yes; break; }; sleep 0.25; done
check "$([ -n "$up" ] && echo ok)" "the server restarted with a new id, so open pages reload"
check "$(curl -s -m 5 "$URL/site.css" | grep -qF 'color: green' && echo ok)" "it serves the new file"
sleep 1
echo '<p>more</p>' >> "$D/app/page.html"
waitfor 2
check "$([ "$(grep -c 'only public/ changed' "$WORK/dev.out")" = 1 ] && grep -qF 'change seen, rebuilding' "$WORK/dev.out" && echo ok)" "a page change rebuilds: $(tail -n 3 "$WORK/dev.out")"
up=""
for i in $(seq 1 40); do curl -s -m 2 "$URL/" | grep -qF '<p>more</p>' && { up=yes; break; }; sleep 0.25; done
check "$([ -n "$up" ] && echo ok)" "the rebuilt page is served"
sleep 1
# A public/ change that alters the generated code (a new file) is not static-only in effect: gen differs, so it compiles.
echo 'x' > "$D/public/new.txt"
waitfor 3
check "$([ "$(grep -c 'only public/ changed' "$WORK/dev.out")" = 1 ] && echo ok)" "a new public/ file compiles: $(tail -n 3 "$WORK/dev.out")"
up=""
for i in $(seq 1 40); do [ "$(curl -s -m 2 "$URL/new.txt")" = x ] && { up=yes; break; }; sleep 0.25; done
check "$([ -n "$up" ] && echo ok)" "and is served"
stopdev

echo "devbuild.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
