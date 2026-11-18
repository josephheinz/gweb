#!/bin/sh
# The mailer's SMTP transport (ops/mail.goose) against a fake relay on loopback (python3, test/mail_server.py).
#
#   GOOSE=/path/to/goose PORT=60910 test/mail.sh
#
# 1. The dialogue: EHLO, MAIL FROM, RCPT TO, DATA, the dot-stuffed message, QUIT; the message is RFC 5322 with an encoded Subject.
# 2. A refused RCPT, a closed port, a relay that never greets and one that stalls: false, with the reason, inside the 10 s limit.
# 3. The server exits 2 at startup for a public GWEB_MAIL host (and for a TLS scheme), and starts for loopback.
#
# Needs python3 and gweb built beside this folder (goose build -o gweb cli/gweb.goose). Uses PORT and PORT+1.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
GOOSE=${GOOSE:-goose}
PORT=${PORT:-60910}
DEAD=$((PORT + 1))
if [ ! -x "$GWEB" ]; then echo "mail.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose" >&2; exit 2; fi
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-mail.XXXXXX")
PID=""
cleanup() { [ -n "$PID" ] && kill "$PID" 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
show() { echo "$1" | sed 's/^/    /'; }

if ! "$GOOSE" build -o "$WORK/mail_send" "$HERE/mail_send.goose" >"$WORK/build.txt" 2>&1; then bad "building mail_send"; show "$(cat "$WORK/build.txt")"; exit 1; fi
printf 'Hello\n.hidden line\n..two\nlast.\n' > "$WORK/body.txt"

# serve MODE: starts the fake relay on PORT, waits until it listens.
serve() {
  : > "$WORK/seen"
  python3 -I "$HERE/mail_server.py" "$PORT" "$WORK/seen" "$1" > "$WORK/srv.txt" 2>&1 &
  PID=$!
  n=0
  while ! grep -q listening "$WORK/srv.txt" 2>/dev/null && [ $n -lt 50 ]; do sleep 0.1; n=$((n + 1)); done
}
send() { # port; sets rc, out and secs
  t0=$(date +%s)
  out=$(GWEB_MAIL="smtp://127.0.0.1:$1" GWEB_MAIL_FROM=site@example.org "$WORK/mail_send" "$WORK/body.txt" 2>&1)
  rc=$?
  secs=$(( $(date +%s) - t0 ))
}
stop() { kill "$PID" 2>/dev/null; wait "$PID" 2>/dev/null; PID=""; }

# 1. The dialogue.
serve ok
send "$PORT"
wait "$PID" 2>/dev/null; PID=""
check "$([ "$rc" = 0 ] && echo ok)" "a delivery returns true (got $rc)"; [ "$rc" = 0 ] || show "$out"
seen=$(cat "$WORK/seen")
order=$(printf '%s' "$seen" | tr -d '\r' | grep -E '^(EHLO|MAIL FROM|RCPT TO|DATA|QUIT)' | tr '\n' '|')
check "$([ "$order" = 'EHLO localhost|MAIL FROM:<site@example.org>|RCPT TO:<ann@example.com>|DATA|QUIT|' ] && echo ok)" "commands in order: $order"
check "$(printf '%s' "$seen" | grep -q '^\.\.hidden line' && echo ok)" "a line that starts with a dot is stuffed (..hidden line)"
check "$(printf '%s' "$seen" | grep -q '^\.\.\.two' && echo ok)" "..two is sent as ...two"
check "$(printf '%s' "$seen" | grep -q '^last\.' && echo ok)" "a dot inside a line is left alone"
check "$(printf '%s' "$seen" | grep -q '^Subject: =?utf-8?B?R3LDvMOfZSwgQW5u?=' && echo ok)" "a non-ASCII Subject is an encoded word"
check "$(printf '%s' "$seen" | grep -q '^Message-ID: <[0-9a-f]*@example.org>' && echo ok)" "Message-ID"
check "$(printf '%s' "$seen" | grep -q '^MIME-Version: 1.0' && echo ok)" "MIME-Version"
check "$(printf '%s' "$seen" | grep -q '^To: ann@example.com' && echo ok)" "To header"
bare=$(python3 -I -c 'import sys; d=open(sys.argv[1],"rb").read(); print(sum(1 for i,c in enumerate(d) if c==10 and (i==0 or d[i-1]!=13)))' "$WORK/seen")
check "$([ "$bare" = 0 ] && echo ok)" "every line ends in CRLF ($bare bare LF)"
check "$(python3 -I -c 'import sys; print(open(sys.argv[1],"rb").read().endswith(b"last.\r\n.\r\nQUIT\r\n"))' "$WORK/seen" | grep -q True && echo ok)" "the message ends with CRLF . CRLF, then QUIT"

# 2. Failures.
serve reject
send "$PORT"
stop
check "$([ "$rc" = 1 ] && echo ok)" "a refused RCPT returns false"
check "$(printf '%s' "$out" | grep -q 'mail not sent: server said 550 no such user' && echo ok)" "the 550 reason is logged"
check "$(grep -q '^DATA' "$WORK/seen" && echo bad || echo ok)" "no DATA after a refused RCPT"

send "$DEAD"
check "$([ "$rc" = 1 ] && [ "$secs" -le 6 ] && echo ok)" "a closed port returns false at once ($secs s)"
check "$(printf '%s' "$out" | grep -q 'mail not sent: cannot connect to 127.0.0.1:' && echo ok)" "the connect failure is logged"

serve hang
send "$PORT"
stop
check "$([ "$rc" = 1 ] && [ "$secs" -ge 9 ] && [ "$secs" -le 13 ] && echo ok)" "a relay that never greets: false after about 10 s ($secs s, rc $rc)"
check "$(printf '%s' "$out" | grep -q 'mail not sent: no reply' && echo ok)" "the timeout is logged"

serve slow
send "$PORT"
stop
check "$([ "$rc" = 1 ] && [ "$secs" -ge 9 ] && [ "$secs" -le 13 ] && echo ok)" "a relay that stalls mid-dialogue: false inside the 10 s total ($secs s, rc $rc)"

# 3. Startup: the generated main refuses a public relay.
cp -R "$HERE/mail/site" "$WORK/site"
if ! out=$("$GWEB" -C "$WORK/site" build 2>&1); then bad "gweb build of the mail site"; show "$out"; exit 1; fi
SERVER="$WORK/site/.gweb/server"
for spec in smtp://smtp.example.com:587 smtp://8.8.8.8:25 smtps://127.0.0.1:465; do
  GWEB_MAIL="$spec" PORT=$DEAD "$SERVER" > "$WORK/start.txt" 2>&1 &
  p=$!
  n=0
  while kill -0 $p 2>/dev/null && [ $n -lt 30 ]; do sleep 0.1; n=$((n + 1)); done
  if kill -0 $p 2>/dev/null; then kill $p 2>/dev/null; wait $p 2>/dev/null; rc=running; else wait $p; rc=$?; fi
  check "$([ "$rc" = 2 ] && grep -q '^GWEB_MAIL: ' "$WORK/start.txt" && echo ok)" "GWEB_MAIL=$spec: exit 2 and a reason (got $rc)"
done
GWEB_MAIL="smtp://127.0.0.1:$PORT" PORT=$DEAD "$SERVER" > "$WORK/start.txt" 2>&1 &
p=$!
sleep 1
check "$(kill -0 $p 2>/dev/null && echo ok)" "GWEB_MAIL=smtp://127.0.0.1: the server starts"
kill $p 2>/dev/null; wait $p 2>/dev/null

# The recipe in the README runs under gweb test.
if out=$("$GWEB" -C "$WORK/site" test 2>&1) && printf '%s' "$out" | grep -q 'routes: 3 tests, .* 0 failed'; then ok; else bad "gweb test of the mail site"; show "$out"; fi

echo "mail: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
