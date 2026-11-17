#!/bin/sh
# gweb's dev-build suite (docs/dev-builds.md).
#
#   GOOSE=/path/to/goose test/devbuild.sh
#
# 1. Compiler errors: each once, with its source line and no instantiation chain (page.html, a component, page.goose
#    keeps goose's caret); --raw-errors and GWEB_RAW_ERRORS=1 show goose's own output; gweb check condenses too.
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
check "$([ "$(count "$out" 'app/page.html:3: error: struct Props has no field nosuch')" = 1 ] && echo ok)" "the page.html error is shown once"
check "$([ "$(count "$out" 'components/Card.gshtml:4: error: unknown identifier: also_missing')" = 1 ] && echo ok)" "the component error is shown once, at its .gshtml line"
check "$(printf '%s\n' "$out" | grep -qxF '<p>{props.nosuch}</p>' && printf '%s\n' "$out" | grep -qxF '<b>{also_missing + s.n}</b>' && echo ok)" "each error is followed by its source line"
check "$(! printf '%s\n' "$out" | grep -qF 'instantiated from' && ! printf '%s\n' "$out" | grep -qF 'out.append(' && echo ok)" "no instantiation chain and no generated code"
check "$(! printf '%s\n' "$out" | grep -qF ' | ' && echo ok)" "no numbered excerpt (errors.txt has those)"
[ "$fail" = 0 ] || show "$out"
raw=$("$GWEB" -C "$WORK/bad" build --raw-errors 2>&1)
check "$(printf '%s\n' "$raw" | grep -qF 'instantiated from' && printf '%s\n' "$raw" | grep -qF 'gweb::put(out, props.nosuch)' && echo ok)" "--raw-errors shows goose's whole output"
check "$([ "$(count "$raw" 'app/page.html:3: error:')" -gt 1 ] && echo ok)" "--raw-errors keeps the repeats"
raw2=$(GWEB_RAW_ERRORS=1 "$GWEB" -C "$WORK/bad" build 2>&1)
check "$(printf '%s\n' "$raw2" | grep -qF 'instantiated from' && echo ok)" "GWEB_RAW_ERRORS=1 shows goose's whole output"
out=$("$GWEB" -C "$WORK/bad" check 2>&1)
check "$([ "$(count "$out" 'app/page.html:3: error:')" = 1 ] && ! printf '%s\n' "$out" | grep -qF 'instantiated from' && echo ok)" "gweb check condenses as build does"
"$GWEB" -C "$WORK/bad" dev --once >/dev/null 2>&1
check "$([ "$(grep -c '^app/page.html:3: error:' "$WORK/bad/.gweb.dev/errors.txt")" = 1 ] && grep -qF '>   3 | <p>{props.nosuch}</p>' "$WORK/bad/.gweb.dev/errors.txt" && echo ok)" \
  "dev --once: errors.txt has each error once, with its excerpt"
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
