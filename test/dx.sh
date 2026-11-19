#!/bin/sh
# Developer tooling (1.8.3): what a site developer sees when something goes wrong or takes long.
#
#   GOOSE=/path/to/goose PORT=4044 test/dx.sh        (GWEB=/path/to/gweb to try another binary)
#
# 1. gweb help lists --port for dev; gweb check on an unknown site:: function says to run cms check first.
# 2. A failed expect_status and expect_contains name the request: its method, host and path.
# 3. A dev build's server run outside its folder says to use gweb build.
# 4. gweb dev: a handler that overflows the stack ends the server; gweb dev names the request, says what it usually is,
#    and starts the server again.
# 5. Rebuilds: gweb build with nothing changed (or only tests/ changed) does not compile the C again; gweb test with
#    nothing changed does not, and after a change to one test file compiles one unit, not all.
#
# Needs curl, and gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts one dev server on $PORT.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB=${GWEB:-"$ROOT/gweb"}
PORT=${PORT:-4044}
[ -x "$GWEB" ] || { echo "dx.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-dx.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
DEVPID=""
stopdev() {
  kill -TERM -"$DEVPID" 2>/dev/null || { pkill -TERM -P "$DEVPID" 2>/dev/null; kill -TERM "$DEVPID" 2>/dev/null; }
  for i in $(seq 1 20); do kill -0 "$DEVPID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -"$DEVPID" 2>/dev/null || { pkill -KILL -P "$DEVPID" 2>/dev/null; kill -KILL "$DEVPID" 2>/dev/null; }
  DEVPID=""
}
cleanup() { [ -n "$DEVPID" ] && stopdev; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }
has() { case "$1" in *"$2"*) echo ok ;; esac; }

P=$WORK/site
mkdir -p "$P/app/boom" "$P/app/zz" "$P/tests"
printf '<h1>Home</h1>\n' > "$P/app/page.html"
cat > "$P/app/boom/route.goose" <<'GOOSE'
import std;
import net.http;
import gweb;

recursive fn deep(n: i64) -> i64 {
    var room: u8[..60000] = "";
    room.append("x");
    if n <= 0 { return room.len; }
    return deep(n - 1) + room.len;
}

fn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {
    let n = deep(100000);
    http::text(res, http::Status.Ok, "deep");
}
GOOSE
cat > "$P/tests/msgs.goose" <<'GOOSE'
import std;
import net.http;
import gweb;
import gweb.testing;

fn test_ok(t: gweb::Tester&) {
    t.host.clear();
    t.host.append("shop.localhost");
    let res = site::get(t, "/");
    gweb::expect_status(t, res, 200);
    gweb::expect_contains(t, res.body, "Home");
}

fn test_msgs(t: gweb::Tester&) {
    t.host.clear();
    t.host.append("shop.localhost");
    let res = site::get(t, "/?q=1");
    gweb::expect_status(t, res, 201);
    gweb::expect_contains(t, res.body, "Absent");
}
GOOSE

# 1. help and the check hint.
out=$("$GWEB" help 2>&1)
check "$(has "$out" '--port N for another')" "gweb help: dev lists --port"
printf 'import std;\nimport net.http;\nimport gweb;\n\nfn GET(req: const http::Request&, ctx: gweb::Ctx&, res: http::Response&) {\n    let r = site::children_Nope(1);\n}\n' > "$P/app/zz/route.goose"
out=$("$GWEB" -C "$P" check 2>&1)
check "$(has "$out" 'unknown function: site::children_Nope (run `cms check`')" "gweb check: unknown site::children_* says to run cms check first"
rm -rf "$P/app/zz"

# 2. The request in a failed expect.
out=$("$GWEB" -C "$P" test 2>&1)
check "$(has "$out" 'status 200, want 201 (GET shop.localhost/?q=1)')" "expect_status names the request"
check "$(has "$out" "lacks 'Absent' in ")" "expect_contains still says what it lacks"
check "$(has "$out" ' of GET shop.localhost/?q=1: ')" "expect_contains names the request"
[ "$fail" = 0 ] || show "$out"

# 5a. gweb test builds the C once; a change to a test file compiles one unit.
"$GWEB" -C "$P" test >/dev/null 2>&1
out=$("$GWEB" -C "$P" test 2>&1)
check "$([ -f "$P/.gweb.test/.cc-skipped" ] && echo ok)" "gweb test with nothing changed does not compile the C again"
sed -i.bak 's/"Home"/"Hom"/' "$P/tests/msgs.goose"
"$GWEB" -C "$P" test >/dev/null 2>&1
units=$(sed -n 's/^units //p' "$P/.gweb.test/.cc-times")
n=${units%% *}; of=${units##* }
check "$([ -n "$n" ] && [ "$n" -ge 1 ] && [ "$n" -le $((of / 4)) ] && echo ok)" "a changed test file compiles few units ('$units' = compiled of all)"

# 5b. gweb build: the C is not compiled again when it is the same, and tests/ is not part of it.
"$GWEB" -C "$P" build >/dev/null 2>&1
out=$("$GWEB" -C "$P" build 2>&1)
check "$(has "$out" 'the C was unchanged, so its compile was skipped')" "gweb build with nothing changed does not compile the C again"
printf '\n// a change\n' >> "$P/tests/msgs.goose"
out=$("$GWEB" -C "$P" build 2>&1)
check "$(has "$out" 'the C was unchanged, so its compile was skipped')" "gweb build after a change to tests/ only does not compile the C again"
[ "$fail" = 0 ] || show "$out"

# 3. A dev build's server away from its folder.
"$GWEB" -C "$P" build --dev >/dev/null 2>&1
out=$(cd "$WORK" && "$P/.gweb/server" --port "$PORT" 2>&1)
check "$(has "$out" 'built by gweb dev')" "a dev server outside its folder says it is a dev build"
check "$(has "$out" 'gweb build')" "... and to use gweb build"
[ "$fail" = 0 ] || show "$out"

# 4. A crash in a handler.
rm -rf "$P/.gweb" "$P/.gweb.dev"
( cd "$P" && exec "$GWEB" dev --port "$PORT" > "$WORK/dev.log" 2>&1 ) &
DEVPID=$!
up=""
for i in $(seq 1 120); do
  if curl -s -o /dev/null "http://127.0.0.1:$PORT/"; then up=1; break; fi
  sleep 0.5
done
check "$([ -n "$up" ] && echo ok)" "gweb dev came up"
curl -s -m 20 -o /dev/null "http://127.0.0.1:$PORT/boom"
back=""
for i in $(seq 1 40); do
  if [ "$(curl -s -m 2 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 200 ]; then back=1; break; fi
  sleep 0.5
done
log=$(cat "$WORK/dev.log")
check "$(has "$log" 'while it was serving')" "gweb dev says the server stopped while serving a request"
check "$(has "$log" 'GET /boom')" "... and names the request"
check "$(has "$log" 'a handler'"'"'s stack is too big')" "... and says what it usually is"
check "$(has "$log" 'cms::Doc')" "... and names cms::Doc"
check "$([ -n "$back" ] && echo ok)" "gweb dev started the server again"
[ "$fail" = 0 ] || show "$log"
stopdev

echo "dx: $pass passed, $fail failed"
[ "$fail" = 0 ]
