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
# 4. Template text and the split compile: a change to template text alone leaves the C as it was (.gweb/lits);
#    gweb __devcc compiles changed units only and reuses cached objects; a string's new text with the same length is
#    served (constants are named by content); a missing object is compiled again; GWEB_DEV_UNITS=0 compiles the C
#    whole; a production gen has no dev text; a dev binary outside its folder says why it cannot start.
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
# 1.8: slips from other languages get what to write instead; `let n = s.length;` on text (a `const u8[:]`) too.
printf 'fn gw_s1(s: const u8[:]) -> i64 { let n = s.length; return n; }\nfn gw_s2(s: const u8[:]) -> i64 { let b = s.length(); return 0; }\nfn gw_s3(o: u8[>..]&) { o.push_back(1); }\nfn gw_s4(s: const u8[:]) -> i64 { let c = s.substr(0, 1); return 0; }\nfn gw_s5(s: const u8[:]) -> i64 { let d = s.contains("x"); return 0; }\nfn gw_s6() -> i64 { let e: string = "x"; return 0; }\nfn gw_s7(s: const u8[:]) -> i64 { let f = s + "x"; return 0; }\n' >> "$WORK/len/app/len/page.goose"
out=$("$GWEB" -C "$WORK/len" build 2>&1)
for want in 'no field access on a value of type const u8[:] (arrays and text have .len)' 'unknown function or member: length (arrays and text have .len, a property)' \
            'unknown function or member: push_back (.push(byte) adds one element' 'unknown function or member: substr (slice with text[a..b])' \
            'no matching overload for call to contains (text has no .contains: find(text, x) >= 0)' 'unknown type: string (text is u8[:]' \
            'operator + cannot be applied to const u8[:] and const u8[:] (join text with format('; do
  check "$(printf '%s\n' "$out" | grep -qF "$want" && echo ok)" "slip hint: $want"
done
out=$("$GWEB" -C "$WORK/len" build --diagnostics json 2>&1)
check "$(printf '%s\n' "$out" | grep -qF '"message":"unknown function or member: length (arrays and text have .len, a property)"' && echo ok)" "a slip's hint in JSON diagnostics"
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

# 1b. Hints (1.8.1): a reserved word as a name, and decode for a struct that is not named *Form.
fresh hints
printf 'import std;\nimport net.http;\nimport gweb;\nstruct Props { n: i64 }\nfn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {\n    var pad = 3;\n    return Props { n: pad };\n}\n' > "$WORK/hints/app/page.goose"
out=$("$GWEB" -C "$WORK/hints" build 2>&1)
check "$(printf '%s\n' "$out" | grep -qF "'pad' is a reserved word in Goose" && echo ok)" "a reserved word as a name says so: $(printf '%s\n' "$out" | head -n 4)"
printf 'import std;\nimport net.http;\nimport gweb;\nimport gweb.forms.form;\nstruct Signup { email: u8[..100] }\nstruct Props { n: i64 }\nfn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props {\n    var f = Signup { email: "" };\n    var errs = gweb::no_errors();\n    decode(req, ctx, f, errs);\n    return Props { n: 1 };\n}\n' > "$WORK/hints/app/page.goose"
out=$("$GWEB" -C "$WORK/hints" build 2>&1)
check "$(printf '%s\n' "$out" | grep -qF "struct whose name ends in Form" && echo ok)" "decode without a *Form struct says why: $(printf '%s\n' "$out" | head -n 4)"

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
# A SIGTERM to gweb dev alone (not its group) stops the server child too (1.8.1).
kill -TERM "$DEVPID" 2>/dev/null
gone=""
for i in $(seq 1 40); do curl -s -m 1 -o /dev/null "$URL/" || { gone=yes; break; }; sleep 0.25; done
check "$([ -n "$gone" ] && echo ok)" "SIGTERM to gweb dev stops its server (port $PORT is free)"
stopdev

# 4. Template text and the split compile.
fresh split
S4="$WORK/split"
serve() {   # serve TEXT: .gweb/server of split answers / with TEXT in it
  (cd "$S4" && exec ./.gweb/server --port "$PORT" --workers 1 >"$WORK/split.log" 2>&1) &
  PID=$!
  got=""
  for i in $(seq 1 40); do curl -s -m 2 "$URL/" | grep -qF -- "$1" && { got=yes; break; }; sleep 0.25; done
  kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""
  [ -n "$got" ]
}
units() { printf '%s\n' "$1" | sed -n 's/.*cc [0-9.]* (\([0-9]*\) of \([0-9]*\) units).*/\1 \2/p'; }
out=$("$GWEB" -C "$S4" build --dev 2>&1)
u=$(units "$out")
check "$([ -n "$u" ] && [ "${u% *}" -gt 0 ] && echo ok)" "a dev build compiles the C in units: $out"
check "$(grep -rq "gweb::_dev_lit(out, " "$S4/.gweb" && grep -qF '<h1>Hi ' "$S4/.gweb/lits" && echo ok)" \
  "template text is in .gweb/lits, not the code"
sed 's|<h1>Hi |<h1>Hello |' "$HERE/devbuild/site/app/page.html" > "$S4/app/page.html"
out=$("$GWEB" -C "$S4" build --dev 2>&1)
check "$(printf '%s\n' "$out" | grep -qF 'the C was unchanged, so its compile was skipped' && echo ok)" "a change to template text alone skips the C compile: $out"
check "$(serve '<h1>Hello 1</h1>' && echo ok)" "and the binary serves the new text: $(cat "$WORK/split.log")"
sed 's/n: 1,/n: 1 + 41,/' "$HERE/devbuild/site/app/page.goose" > "$S4/app/page.goose"
out=$("$GWEB" -C "$S4" build --dev 2>&1)
u=$(units "$out")
check "$([ -n "$u" ] && [ "${u% *}" -ge 1 ] && [ "${u% *}" -lt "${u#* }" ] && echo ok)" "a Goose change compiles some units, not all: $out"
check "$(serve '<h1>Hello 42</h1>' && echo ok)" "and is served"
cp "$HERE/devbuild/site/app/page.goose" "$S4/app/page.goose"
out=$("$GWEB" -C "$S4" build --dev 2>&1)
check "$([ "$(units "$out" | cut -d' ' -f1)" = 0 ] && echo ok)" "undoing it compiles no unit (the objects are cached): $out"
check "$(serve '<h1>Hello 1</h1>' && echo ok)" "and the old page is back"
# Strings: goose numbers them program-wide; gweb names them by content, so the same length must not mix them up.
printf 'fn tag() -> const u8[:] { "abc" }\n' >> "$S4/app/page.goose"
sed 's|<h1>Hello {props.n}</h1>|<h1>Hello {props.n} {tag()}</h1>|' "$S4/app/page.html" > "$S4/page.tmp" && mv "$S4/page.tmp" "$S4/app/page.html"
out=$("$GWEB" -C "$S4" build --dev 2>&1)
check "$(serve '<h1>Hello 1 abc</h1>' && echo ok)" "a new string is served: $out"
sed 's/"abc"/"abd"/' "$S4/app/page.goose" > "$S4/page.tmp" && mv "$S4/page.tmp" "$S4/app/page.goose"
out=$("$GWEB" -C "$S4" build --dev 2>&1)
u=$(units "$out")
check "$([ -n "$u" ] && [ "${u% *}" -lt "${u#* }" ] && echo ok)" "its new text, same length, compiles some units: $out"
check "$(serve '<h1>Hello 1 abd</h1>' && echo ok)" "and the new text is served"
# A lost object is compiled again.
objs=$(ls -d "$HOME"/.goose/build/prog/main-*/gweb-units 2>/dev/null; ls -d "${GOOSE_HOME:-/nonexistent}"/build/prog/main-*/gweb-units 2>/dev/null)
mine=""
for d in $objs; do grep -q "$S4/.gweb/main.goose" "$d/../main.c" 2>/dev/null && mine=$d; done
if [ -n "$mine" ]; then
  rm -f "$mine"/o/*.o
  echo '<p>again</p>' >> "$S4/app/page.html"
  out=$("$GWEB" -C "$S4" build --dev 2>&1)
  u=$(units "$out")
  check "$([ -n "$u" ] && [ "${u% *}" = "${u#* }" ] && echo ok)" "with its objects gone every unit compiles again: $out"
  check "$(serve '<p>again</p>' && echo ok)" "and the binary serves"
else
  bad "the program's gweb-units folder was not found"
fi
echo '<p>whole</p>' >> "$S4/app/page.html"
out=$(GWEB_DEV_UNITS=0 "$GWEB" -C "$S4" build --dev 2>&1)
check "$(printf '%s\n' "$out" | grep -q 'built .gweb/server' && ! printf '%s\n' "$out" | grep -qF ' units)' && echo ok)" "GWEB_DEV_UNITS=0 compiles the C whole: $out"
check "$(serve '<p>whole</p>' && echo ok)" "and the binary serves"
(cd "$WORK" && "$S4/.gweb/server" --port "$PORT" >"$WORK/away.log" 2>&1); rc=$?
check "$([ "$rc" = 2 ] && grep -qF 'cannot read .gweb/lits' "$WORK/away.log" && echo ok)" "a dev binary away from its folder says why: $(cat "$WORK/away.log")"
"$GWEB" -C "$S4" gen >/dev/null 2>&1
check "$(! grep -rq '_dev_lit' "$S4/.gweb" && [ ! -f "$S4/.gweb/lits" ] && grep -rqF 'out.append("<h1>Hello ' "$S4/.gweb" && echo ok)" "a production gen inlines template text"

echo "devbuild.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
