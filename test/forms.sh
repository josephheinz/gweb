#!/bin/sh
# gweb's forms and uploads suite (DESIGN-ADDENDUM-14, step 4).
#
#   GOOSE=/path/to/goose test/forms.sh
#
# 1. test/forms/site is built and started; curl checks required-field errors and
#    the 422, values echoed back, a valid post (303), a fragment POST with errors
#    (422 with the GW-Fragment echo), multipart with a _csrf field, the saved
#    file, the 413 over MAX_UPLOAD (a page) and over --max-upload (a route), the
#    JSON errors of a route, and that the upload dir holds no gw-/gnet- temp file
#    after each request. A body over a limit: a 413 page for a browser (the app's
#    error.html), JSON for fetch, a too_large hook's 303, no reset for a client
#    that sends its whole body; gweb test applies the limits too.
# 2. A bad field type and a user fn decode must fail gweb build, with file:line; so must {#fragment} or @slot() in loading.html.
#
# Needs curl, python3 and gweb built beside this folder (goose build -o gweb
# cli/gweb.goose).
#
# Layout: gweb finds goose-net as <gweb>/../goose-net (or $GWEB_NET). From a
# git worktree, that sibling is the main goose-net checkout, not the goose-net
# worktree that has the spool API (set_uploads, Event.Spooled). Run this suite
# with GWEB_HOME pointing at this checkout and GWEB_NET at the goose-net
# checkout that has the spool API, or check both out side by side.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-3992}
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-forms.XXXXXX")
PID=""
TK=0123456789abcdef0123456789abcdef
UP="$WORK/uploads"
SAVED="$WORK/saved"
cleanup() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }

# req NAME METHOD PATH [curl args]: status in $WORK/NAME.status, headers in
# NAME.h (lower case), body in NAME.b.
URL="http://127.0.0.1:$PORT"
req() {
  name=$1; method=$2; path=$3; shift 3
  curl -s -X "$method" -D "$WORK/$name.h.raw" -o "$WORK/$name.b" -w '%{http_code}' "$@" "$URL$path" > "$WORK/$name.status"
  tr -d '\r' < "$WORK/$name.h.raw" | tr 'A-Z' 'a-z' > "$WORK/$name.h"
}
status() { cat "$WORK/$1.status"; }
has_header() { grep -q "^$2" "$WORK/$1.h"; }
body_has() { grep -qF -- "$2" "$WORK/$1.b"; }

# temp_clean: the upload dir holds no gw- or gnet- file (the worker unlinks them
# just after the reply, so wait a moment).
temp_clean() {
  sleep 0.3
  [ "$(ls "$UP" 2>/dev/null | grep -c '^\(gw-\|gnet-\)')" = 0 ]
}

start_server() {
  rm -rf "$UP" "$SAVED"
  mkdir -p "$SAVED"
  (cd "$WORK/ok" && GW_SAVE_DIR="$SAVED" exec .gweb/server --port "$PORT" --upload-dir "$UP" "$@" >/dev/null 2>&1) &
  PID=$!
  up=""
  for i in 1 2 3 4 5 6 7 8 9 10; do
    sleep 0.5
    if curl -s -o /dev/null "$URL/signup"; then up=yes; break; fi
  done
  [ -n "$up" ]
}
stop_server() {
  [ -n "$PID" ] && kill "$PID" 2>/dev/null
  [ -n "$PID" ] && wait "$PID" 2>/dev/null
  PID=""
}

# Files of known size.
head -c 100000 /dev/zero | tr '\0' 'a' > "$WORK/small.bin"
head -c 300000 /dev/zero | tr '\0' 'b' > "$WORK/big.bin"
head -c 400000 /dev/zero | tr '\0' 'c' > "$WORK/mid.bin"
head -c 1500000 /dev/zero | tr '\0' 'd' > "$WORK/huge.bin"

# 1. The site.
cp -R "$HERE/forms/site" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then
  if ! start_server --max-upload 1000000; then
    bad "the server did not answer on port $PORT"
  else
    C="Cookie: gw_csrf=$TK"

    # Validation: required fields.
    req g GET /signup -H "$C"
    check "$([ "$(status g)" = 200 ] && body_has g 'name="email"' && ! body_has g 'class="gw-error"' && echo ok)" "GET /signup: 200 and no errors"
    req e1 POST /signup -H "$C" -d "_csrf=$TK"
    check "$([ "$(status e1)" = 422 ] && echo ok)" "POST /signup with nothing: 422"
    check "$(body_has e1 '<span class="gw-error" id="email-error">Required.</span>' && body_has e1 'id="name-error">Required.' && body_has e1 'id="age-error">Required.' && echo ok)" "required email, name and age say Required."
    check "$(! body_has e1 'id="note-error"' && ! body_has e1 'id="newsletter-error"' && echo ok)" "the optional note and the bool have no error"
    check "$(body_has e1 'aria-invalid="true" aria-describedby="email-error"' && echo ok)" "an invalid input is marked aria-invalid"
    check "$(body_has e1 '<html' && body_has e1 'name="_csrf"' && echo ok)" "the 422 is the whole page, with its CSRF field"

    # Values come back.
    req e2 POST /signup -H "$C" --data-urlencode "name=Ann <b>" --data-urlencode "email=x@y.zz" --data-urlencode "age=abc" -d "_csrf=$TK"
    check "$([ "$(status e2)" = 422 ] && body_has e2 'id="age-error">Enter a whole number.' && echo ok)" "age=abc: Enter a whole number."
    check "$(body_has e2 'value="abc"' && body_has e2 'value="Ann &lt;b&gt;"' && body_has e2 'value="x@y.zz"' && echo ok)" "typed values come back, escaped (abc, not 0)"
    check "$(! body_has e2 'id="email-error"' && ! body_has e2 'id="name-error"' && echo ok)" "fields that were fine have no error"
    LONG=$(printf 'n%.0s' $(seq 1 81))
    req e3 POST /signup -H "$C" -d "email=a@b.co&name=$LONG&age=1&_csrf=$TK"
    check "$([ "$(status e3)" = 422 ] && body_has e3 'id="name-error">Use at most 80 characters.' && echo ok)" "a name over 80 bytes: Use at most 80 characters."
    req e4 POST /signup -H "$C" -d "email=nope&name=Ann&age=3&_csrf=$TK"
    check "$([ "$(status e4)" = 422 ] && body_has e4 'id="email-error">Enter a valid email address.' && echo ok)" "check_email after decode: Enter a valid email address."

    # A valid post.
    req v1 POST /signup -H "$C" -d "email=a@b.co&name=Ann&age=30&newsletter=on&_csrf=$TK"
    check "$([ "$(status v1)" = 303 ] && has_header v1 'location: /thanks' && echo ok)" "a valid POST: 303 to /thanks"
    req v2 POST /signup -H "$C" -d "email=a@b.co&name=Ann&age=%2030%20&_csrf=$TK"
    check "$([ "$(status v2)" = 303 ] && echo ok)" "age is trimmed: ' 30 ' is accepted"
    req t GET /thanks
    check "$([ "$(status t)" = 200 ] && echo ok)" "GET /thanks: 200"

    # Fragment form.
    req f1 POST /quick -H 'GW-Fragment: form' -H "$C" -d "email=&_csrf=$TK"
    check "$([ "$(status f1)" = 422 ] && has_header f1 'gw-fragment: form' && echo ok)" "fragment POST with errors: 422 with the GW-Fragment echo"
    check "$(body_has f1 'id="email-error">Required.' && ! body_has f1 '<html' && echo ok)" "the 422 fragment is the region with its errors, no layout"
    req f2 POST /quick -H 'GW-Fragment: form' -H "$C" -d "email=a@b.co&name=Ann&_csrf=$TK"
    check "$([ "$(status f2)" = 200 ] && has_header f2 'gw-fragment: form' && body_has f2 'Thanks a@b.co' && echo ok)" "fragment POST that passes: 200 with the echo"
    req f3 POST /quick -H "$C" -d "email=&_csrf=$TK"
    check "$([ "$(status f3)" = 422 ] && ! has_header f3 'gw-fragment' && body_has f3 '<html' && echo ok)" "the same POST without the header: 422, the whole page"

    # loading.html (section 4): whole pages at or below the folder carry the template; fragment replies and others do not.
    req l1 GET /quick -H "$C"
    check "$([ "$(status l1)" = 200 ] && body_has l1 '<template id="gw-loading"><p id="quick-loading">Loading quick...</p>' && body_has l1 '</template>' && echo ok)" "GET /quick: the whole page has the gw-loading template with the loading markup"
    a=$(grep -bo 'id="form"' "$WORK/l1.b" | head -n 1 | cut -d: -f1)
    b=$(grep -bo '<template id="gw-loading">' "$WORK/l1.b" | head -n 1 | cut -d: -f1)
    c=$(grep -bo '</main>' "$WORK/l1.b" | head -n 1 | cut -d: -f1)
    check "$([ -n "$a" ] && [ -n "$b" ] && [ -n "$c" ] && [ "$a" -lt "$b" ] && [ "$b" -lt "$c" ] && echo ok)" "the template comes after the page and inside the layout"
    req l2 POST /quick -H 'GW-Fragment: form' -H "$C" -d "email=&_csrf=$TK"
    check "$(! body_has l2 'gw-loading' && ! body_has l2 'quick-loading' && echo ok)" "a GW-Fragment reply has no loading template"
    req l3 GET /signup -H "$C"
    check "$(! body_has l3 'gw-loading' && echo ok)" "a page outside the folder has no loading template"
    check "$(grep -qF 'gw-loading' "$WORK/ok/.gweb/main.goose" && echo ok)" "main.goose renders the loading template for the quick page"

    # Multipart on a page. _csrf travels as a text part.
    req m1 POST /upload -H "$C" -F "_csrf=$TK" -F "title=T" -F "photo=@$WORK/small.bin;filename=pic1.bin;type=application/octet-stream"
    check "$([ "$(status m1)" = 303 ] && has_header m1 'location: /thanks' && echo ok)" "multipart with a _csrf part: CSRF passes, 303"
    check "$([ "$(wc -c < "$SAVED/pic1.bin" 2>/dev/null | tr -d ' ')" = 100000 ] && cmp -s "$SAVED/pic1.bin" "$WORK/small.bin" && echo ok)" "the file was saved with its bytes"
    check "$(temp_clean && echo ok)" "no temp file after a saved upload"
    req m2 POST /upload -H "$C" -F "title=T" -F "photo=@$WORK/small.bin;filename=pic2.bin"
    check "$([ "$(status m2)" = 403 ] && echo ok)" "multipart without a token: 403"
    check "$([ ! -e "$SAVED/pic2.bin" ] && temp_clean && echo ok)" "a refused upload leaves no file and no temp file"
    req m3 POST /upload -H "$C" -F "_csrf=$TK" -F "title=T"
    check "$([ "$(status m3)" = 422 ] && body_has m3 'id="photo-error">Required.' && body_has m3 'value="T"' && echo ok)" "multipart with no file: 422 Required., the title comes back"
    req m4 POST /upload -H "$C" -F "_csrf=$TK" -F "photo=@$WORK/small.bin;filename=pic1.bin"
    check "$([ "$(status m4)" = 422 ] && body_has m4 'id="photo-error">Could not save the file.' && echo ok)" "saving over an existing file is refused (no overwrite): 422"
    check "$(temp_clean && echo ok)" "no temp file after a failed save"
    req m5 POST /upload -H "$C" -d "_csrf=$TK&title=T"
    check "$([ "$(status m5)" = 422 ] && body_has m5 'id="photo-error">Required.' && echo ok)" "an urlencoded post cannot supply a file: 422"

    # Over MAX_UPLOAD (200000): a page answers 413 before reading.
    req big POST /upload -H "$C" -F "_csrf=$TK" -F "photo=@$WORK/big.bin;filename=big.bin"
    check "$([ "$(status big)" = 413 ] && echo ok)" "300000 bytes over MAX_UPLOAD = 200000: 413"
    check "$([ ! -e "$SAVED/big.bin" ] && temp_clean && echo ok)" "the 413 left no file and no temp file"

    # A route: JSON, and --max-upload (1000000).
    A="X-CSRF-Token: $TK"
    req r1 POST /api/upload -H "$C" -H "$A" -F "photo=@$WORK/mid.bin;filename=mid.bin"
    check "$([ "$(status r1)" = 200 ] && body_has r1 '"ok":true' && body_has r1 '"size":400000' && echo ok)" "route: a 400000 byte upload (kept on disk by the server) is parsed: 200 with its size"
    check "$(temp_clean && echo ok)" "no temp file after the route's upload"
    req r2 POST /api/upload -H "$C" -H "$A" -F "title=x"
    check "$([ "$(status r2)" = 422 ] && has_header r2 'content-type: application/json' && body_has r2 '"errors":{"photo":"Required."}' && echo ok)" "route without a file: 422 JSON from gweb::errors_json"
    req r3 POST /api/upload -H "$C" -H "$A" -F "photo=@$WORK/huge.bin;filename=huge.bin"
    check "$([ "$(status r3)" = 413 ] && echo ok)" "1500000 bytes over --max-upload 1000000: 413"
    check "$(temp_clean && echo ok)" "no temp file after the 413 over --max-upload"
    req r4 POST /api/upload -H "$C" -F "photo=@$WORK/small.bin;filename=p.bin"
    check "$([ "$(status r4)" = 403 ] && echo ok)" "route without the CSRF header or a _csrf part: 403"
    req r5 POST /api/upload -H "$C" -F "_csrf=$TK" -F "photo=@$WORK/small.bin;filename=p.bin"
    check "$([ "$(status r5)" = 200 ] && echo ok)" "route with a _csrf part: 200"
    req r6 POST /api/upload -H "$C" -H "$A" -H 'Content-Type: multipart/form-data; boundary=zz' --data-binary 'not multipart'
    check "$([ "$(status r6)" = 400 ] && echo ok)" "a malformed multipart body: 400"
    check "$(temp_clean && echo ok)" "no temp file at the end"

    # A body over its limit (gweb 1.5): HTML for a browser, JSON for fetch, or the page's too_large hook.
    H="Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8"
    req t1 POST /upload -H "$C" -H "$H" -F "_csrf=$TK" -F "photo=@$WORK/big.bin;filename=big.bin"
    check "$([ "$(status t1)" = 413 ] && has_header t1 'content-type: text/html' && body_has t1 'This file is too large. The limit is 195.3 KiB.' && echo ok)" "over MAX_UPLOAD from a browser: a 413 page naming the limit"
    req t2 POST /upload -H "$C" -F "_csrf=$TK" -F "photo=@$WORK/big.bin;filename=big.bin"
    check "$([ "$(status t2)" = 413 ] && has_header t2 'content-type: application/json' && body_has t2 '"error":"This file is too large. The limit is 195.3 KiB."' && echo ok)" "over MAX_UPLOAD from fetch (Accept */*): JSON"
    req t3 POST /files -H "$C" -H "$H" -F "_csrf=$TK" -F "doc=@$WORK/huge.bin;filename=huge.bin"
    check "$([ "$(status t3)" = 413 ] && body_has t3 '<h1 id="files-error">413: This file is too large. The limit is 976.5 KiB.</h1>' && body_has t3 '<main>' && echo ok)" "over --max-upload (unread) from a browser: the app's error.html in its layout"
    check "$(has_header t3 'connection: close' && echo ok)" "the unread body closes the connection"
    req t4 POST /files -H "$C" -H "$H" -H 'GW-Fragment: x' -F "doc=@$WORK/huge.bin;filename=huge.bin"
    check "$([ "$(status t4)" = 413 ] && has_header t4 'content-type: application/json' && echo ok)" "a fragment request over the limit: JSON"
    req t5 POST /api/upload -H "$C" -H "$H" -F "photo=@$WORK/huge.bin;filename=huge.bin"
    check "$([ "$(status t5)" = 413 ] && has_header t5 'content-type: text/html' && body_has t5 'This file is too large.' && echo ok)" "a route posted from a browser form: a 413 page, not JSON"
    req t6 POST "/files/hooked?folder=3" -H "$C" -H "$H" -F "doc=@$WORK/huge.bin;filename=huge.bin"
    check "$([ "$(status t6)" = 303 ] && has_header t6 'location: /files/hooked?folder=3&ue=files+can+be+at+most+195.3+kib' && echo ok)" "too_large over --max-upload (unread): 303 back to the form with the page's tighter MAX_UPLOAD, no CSRF field needed"
    req t7 POST /files/hooked -H "$C" -H "$H" -F "_csrf=$TK" -F "doc=@$WORK/big.bin;filename=big.bin"
    check "$([ "$(status t7)" = 303 ] && has_header t7 'location: /files/hooked?ue=files+can+be+at+most+195.3+kib' && echo ok)" "too_large over MAX_UPLOAD: 303 with that limit"
    req t8 GET "/files/hooked?ue=Files+can+be+at+most+195.3+KiB" -H "$C"
    check "$([ "$(status t8)" = 200 ] && body_has t8 '<p id="ue">Files can be at most 195.3 KiB</p>' && echo ok)" "the form shows the message"
    req t9 POST /files/hooked -H "$C" -F "_csrf=$TK" -F "doc=@$WORK/small.bin;filename=s.bin"
    check "$([ "$(status t9)" = 303 ] && has_header t9 'location: /thanks' && echo ok)" "within the limit the hook does not run"
    req t10 POST /signup -H "$C" -H "$H" --data-binary "@$WORK/huge.bin"
    check "$([ "$(status t10)" = 413 ] && has_header t10 'content-type: text/html' && body_has t10 'This request is too large. The limit is 1 MiB.' && echo ok)" "a form post over --max-body from a browser: a 413 page naming 1 MiB"
    check "$(temp_clean && echo ok)" "no temp file after the refused bodies"
    # A client that sends its whole refused body still reads the reply: the connection lingers, no reset.
    linger=$(python3 - "$PORT" "$TK" <<'PY'
import socket, sys
port, tk = int(sys.argv[1]), sys.argv[2]
body = b"x" * 5000000
head = ("POST /files HTTP/1.1\r\nHost: x\r\nCookie: gw_csrf=%s\r\nAccept: text/html\r\n"
        "Content-Type: multipart/form-data; boundary=zz\r\nContent-Length: %d\r\n\r\n" % (tk, len(body))).encode()
s = socket.create_connection(("127.0.0.1", port))
try:
    s.sendall(head + body)
    reply = b""
    while True:
        b = s.recv(65536)
        if not b: break
        reply += b
    print("ok" if reply.startswith(b"HTTP/1.1 413") and b"The limit is 976.5 KiB." in reply else "bad reply %r" % reply[:80])
except ConnectionResetError:
    print("reset")
PY
)
    check "$linger" "5 MB sent whole over --max-upload: the 413 arrives with no reset ($linger)"
    req t11 GET /signup -H "$C"
    check "$([ "$(status t11)" = 200 ] && echo ok)" "the server still answers"

    # The generated code reads like D1 and D9.
    GEN="$WORK/ok/.gweb"
    check "$(grep -qF '// gweb: form decoders (generated)' "$GEN/p"*"_signup.goose" 2>/dev/null && echo ok)" "the signup copy ends with the generated decoders"
    check "$(grep -qF 'gweb::form_i64(req, "age", f.age, errs, true);' "$GEN"/*signup.goose && grep -qF 'gweb::form_text(req, "note", f.note, errs, false);' "$GEN"/*signup.goose && echo ok)" "decoder statements: required and optional text, int"
    check "$(grep -qF 'gweb::form_upload(ctx, "photo", f.photo, errs, true);' "$GEN"/*upload.goose && echo ok)" "decoder statement for gweb::Upload"
    check "$(grep -qF '::MAX_UPLOAD > 0 && gweb::_content_length(req) >' "$GEN/main.goose" && grep -qF 'if gweb::_is_multipart(req)' "$GEN/main.goose" && echo ok)" "main.goose has the MAX_UPLOAD check and the multipart prelude"
    check "$(grep -qF '::too_large(req, ctx, ctx.too_large); return; }' "$GEN/main.goose" && echo ok)" "main.goose calls the too_large hook"
    check "$(grep -qF 'gweb::_prepare_uploads(cfg);' "$GEN/main.goose" && echo ok)" "main() prepares the upload dir once"
  fi
  stop_server
else
  bad "gweb build of the site"; echo "$out"
fi

# 1b. gweb test applies the body limits too (tests/too_large.goose).
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 2 tests, 4 checks, 0 failed"*) ok ;; *) bad "gweb test of the site:"; echo "$out" ;; esac
else
  bad "gweb test of the site failed"; echo "$out"
fi

# 2. Expected failures, in a copy of the site.
cp -R "$HERE/forms/site" "$WORK/f"
rm -rf "$WORK/f/.gweb"

# expect_fail TEXT LINE MESSAGE: app/signup/page.goose holds TEXT; the build
# must say app/signup/page.goose:LINE: error: MESSAGE.
expect_fail() {
  text=$1; line=$2; msg=$3
  printf '%s\n' "$text" > "$WORK/f/app/signup/page.goose"
  want="app/signup/page.goose:$line: error: $msg"
  if out=$("$GWEB" -C "$WORK/f" build 2>&1); then
    bad "'$msg': gweb build succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
}

HEAD='import std;
import net.http;
import gweb;
struct Props { n: i64 }
fn load(req: const http::Request&, ctx: gweb::Ctx&) -> Props { return Props { n: 0 }; }
fn POST(req: const http::Request&, ctx: gweb::Ctx&) -> Props { return Props { n: 1 }; }'
FIELDS='form fields are u8[..N], i64, bool or gweb::Upload'

expect_fail "$HEAD
struct SignupForm {
    email: u8[..200],
    ratio: f64,
}" 9 "$FIELDS"
expect_fail "$HEAD
struct SignupForm {
    // a comment line
    email: u8[..200],   // trailing comment
    tags: u8[..20][..4],
}" 10 "$FIELDS"
expect_fail "$HEAD
struct SignupForm { email: u8[..200], age: i32 }" 7 "$FIELDS"
expect_fail "$HEAD
struct SignupForm {
    email: u8[..200],
    kind: Kind = Kind.A,
}" 9 "$FIELDS"
expect_fail "$HEAD
struct SignupForm {
    email: u8[..200],
}
fn decode(req: const http::Request&, ctx: const gweb::Ctx&, f: SignupForm&, errs: gweb::FieldErrors&) -> bool { return true; }" 10 "fn decode is generated for SignupForm; rename yours"

# loading.html: {#fragment} and @slot() are build errors in it.
cp "$HERE/forms/site/app/signup/page.goose" "$WORK/f/app/signup/page.goose"
expect_loading() {
  printf '%s\n' "$1" "$2" > "$WORK/f/app/quick/loading.html"
  want="app/quick/loading.html:$3: error: $4"
  if out=$("$GWEB" -C "$WORK/f" build 2>&1); then
    bad "loading.html '$4': gweb build succeeded"
  else
    case "$out" in
      *"$want"*) ok ;;
      *) bad "wanted '$want', got:"; echo "$out" | sed 's/^/    /' ;;
    esac
  fi
}
expect_loading '<p>ok</p>' '<div>{#fragment spin}<p>x</p>{/fragment}</div>' 2 "{#fragment} is for page.html only"
expect_loading '<p>ok</p>' '<div>@slot()</div>' 2 "@slot() is for layout.html only"

echo "forms.sh: $pass passed, $fail failed"
[ "$fail" -eq 0 ]
