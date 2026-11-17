#!/bin/sh
# Tools, commands and hooks (DESIGN-ADDENDUM-21).
#
#   GOOSE=/path/to/goose test/hooks.sh
#
# test/hooks/app uses test/hooks/pkg, a package with a tool (built from cli/hk.goose, laid out like goose-cms's cms),
# two commands and a hook on content/. The app has its own commands and a hook.
# 1. gweb run: the list, arguments, the app's command over a package's, the exit status, an unknown name.
# 2. The tool: built once into .gweb.tools/, its outside import pointed at the package's Goose package, rebuilt when
#    the package changes; the package folder is not written to. A copied gweb (the Dockerfile's) builds it too.
# 3. gweb gen runs no hook; gweb build runs the package's then the app's; --no-hooks and GWEB_HOOKS=0 skip them.
# 4. A failing hook stops gweb build and gweb dev --once, with its stderr in errors.txt.
# 5. Bad lines, each in its own copy.
# 6. gweb dev runs a hook again only when its paths change, and what the hook writes is not a change.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose), and a Goose compiler.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
PORT=${PORT:-4031}
[ -x "$GWEB" ] || { echo "hooks.sh: $GWEB is missing; build it first: goose build -o gweb cli/gweb.goose"; exit 1; }
goose=${GOOSE:-}
[ -z "$goose" ] && goose=$(command -v goose 2>/dev/null || true)
[ -n "$goose" ] || { echo "hooks.sh: needs a Goose compiler (GOOSE or goose on PATH)"; exit 1; }
export GOOSE="$goose"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-hooks.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)   # gweb names folders as getcwd does (/private/var on macOS)
DEVPID=""
# Stop gweb dev and its server: the process group where job control made one (bash), else the process and its
# children (dash runs `set -m` scripts without a group); never wait without a deadline.
stopdev() {
  kill -TERM -"$DEVPID" 2>/dev/null || { pkill -TERM -P "$DEVPID" 2>/dev/null; kill -TERM "$DEVPID" 2>/dev/null; }
  for i in $(seq 1 20); do kill -0 "$DEVPID" 2>/dev/null || break; sleep 0.5; done
  kill -KILL -"$DEVPID" 2>/dev/null || { pkill -KILL -P "$DEVPID" 2>/dev/null; kill -KILL "$DEVPID" 2>/dev/null; }
  DEVPID=""
}
cleanup() {
  [ -n "$DEVPID" ] && stopdev
  rm -rf "$WORK"
}
trap cleanup EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }

fresh() {
  rm -rf "$WORK/$1"
  mkdir -p "$WORK/$1"
  cp -R "$HERE/hooks/app" "$WORK/$1/app"
  cp -R "$HERE/hooks/pkg" "$WORK/$1/pkg"
}
fresh ok
A="$WORK/ok/app"

# 1. gweb run.
out=$("$GWEB" -C "$A" run 2>&1)
check "$(has "$out" 'hello  echo hello  (gweb.packages:2)' && echo ok)" "gweb run lists the app's commands: $out"
check "$(has "$out" 'check  hk check  (package hk, ' && echo ok)" "gweb run lists the package's commands"
out=$("$GWEB" -C "$A" run hello a 'b c' --help 2>&1)
check "$([ "$out" = "hello a b c --help" ] && echo ok)" "gweb run hello passes its arguments: $out"
out=$("$GWEB" -C "$A" run greet 2>&1)
check "$([ "$out" = "app greet" ] && echo ok)" "the app's greet wins over the package's: $out"
"$GWEB" -C "$A" run fail >/dev/null 2>&1
check "$([ $? = 3 ] && echo ok)" "gweb run fail exits with the command's status 3"
out=$("$GWEB" -C "$A" run nope 2>&1)
st=$?
check "$([ $st = 1 ] && has "$out" 'no command nope' && echo ok)" "an unknown command: exit 1 and a message: $out"
printf 'run env-check echo "$GWEB_APP|$GWEB_PKG_DIR|$GWEB"\n' >> "$A/gweb.packages"
out=$("$GWEB" -C "$A" run env-check 2>&1)
check "$([ "$out" = "$A|$A|$GWEB" ] && echo ok)" "a command sees GWEB_APP, GWEB_PKG_DIR and GWEB: $out"

# 2. The tool.
out=$("$GWEB" -C "$A" run check 2>&1)
check "$([ $? = 0 ] && has "$out" 'gweb: building tool hk' && has "$out" 'hk: checked' && echo ok)" "gweb run check builds the tool and runs it: $out"
check "$([ "$(cat "$A/public/hooked.txt" 2>/dev/null)" = "hk 1 files, answer 42, note" ] && echo ok)" \
  "the tool read the package's lib, its embed and the Goose package kv"
check "$(grep -q "^import kv from \"$WORK/ok/pkg/kv\";" "$A/.gweb.tools/src/hk/cli/hk.goose" && echo ok)" \
  "the tool's root imports kv from the package's source"
check "$([ -x "$A/.gweb.tools/bin/hk" ] && [ -L "$A/.gweb.tools/src/hk/cli/hk" ] && echo ok)" ".gweb.tools/ holds the binary and the linked tree"
check "$([ -z "$(cd "$WORK/ok/pkg" && find . -newer "$A/gweb.packages" -print)" ] && echo ok)" "the package folder was not written to"
out=$("$GWEB" -C "$A" run check 2>&1)
check "$(! has "$out" 'building tool' && echo ok)" "a second run does not build the tool: $out"
sleep 1
echo "// touched" >> "$WORK/ok/pkg/lib/text.goose"
out=$("$GWEB" -C "$A" run check 2>&1)
check "$(has "$out" 'building tool hk' && echo ok)" "a change in the path package builds the tool again: $out"

# A copied gweb, with no checkout (as in the Dockerfile), builds the tool too.
fresh lone
mkdir -p "$WORK/lone/bin"
cp "$GWEB" "$WORK/lone/bin/gweb"
out=$("$WORK/lone/bin/gweb" -C "$WORK/lone/app" run check 2>&1)
check "$([ $? = 0 ] && has "$out" 'hk: checked' && echo ok)" "a copied gweb builds and runs the tool: $out"

# 3. gen, build, --no-hooks.
rm -f "$A/hook.log"
"$GWEB" -C "$A" gen >/dev/null 2>&1
check "$([ ! -f "$A/hook.log" ] && echo ok)" "gweb gen runs no hook"
out=$("$GWEB" -C "$A" build 2>&1)
check "$([ $? = 0 ] && [ "$(cat "$A/hook.log" 2>/dev/null | tr '\n' ' ')" = "hk app " ] && echo ok)" \
  "gweb build runs the package's hook, then the app's: $(cat "$A/hook.log" 2>/dev/null) $out"
check "$(has "$("$GWEB" -C "$A" routes 2>&1)" '/hooked.txt' && echo ok)" "the file the hook wrote is served"
rm -f "$A/hook.log"
"$GWEB" -C "$A" build --no-hooks >/dev/null 2>&1
GWEB_HOOKS=0 "$GWEB" -C "$A" build >/dev/null 2>&1
check "$([ ! -f "$A/hook.log" ] && echo ok)" "--no-hooks and GWEB_HOOKS=0 skip the hooks"

# 4. A failing hook.
echo BAD > "$A/content/b.txt"
out=$("$GWEB" -C "$A" build 2>&1)
st=$?
check "$([ $st = 1 ] && has "$out" 'content/b.txt:1: error: BAD is not allowed' && has "$out" "gweb.package:8: error: hook \`hk check\` failed (exit 1)" && echo ok)" \
  "a failing hook stops gweb build with its stderr: $out"
check "$(! has "$out" 'built .gweb/server' && echo ok)" "nothing is built after a failing hook"
"$GWEB" -C "$A" dev --once >/dev/null 2>&1
st=$?
check "$([ $st = 1 ] && grep -q '>   1 | BAD' "$A/.gweb.dev/errors.txt" && grep -q 'hook `hk check` failed' "$A/.gweb.dev/errors.txt" && echo ok)" \
  "gweb dev --once: exit 1, errors.txt has the hook's error with its excerpt"
rm "$A/content/b.txt"

# 5. Bad lines.
refused() {
  name=$1 file=$2 line=$3 want=$4
  fresh "$name"
  printf '%s\n' "$line" >> "$WORK/$name/$file"
  out=$("$GWEB" -C "$WORK/$name/app" gen 2>&1)
  st=$?
  check "$([ $st != 0 ] && has "$out" "$want" && echo ok)" "$name: '$line' is refused with '$want': $out"
}
refused notool pkg/gweb.package 'tool nt cli/none.goose' 'tool nt: no '
refused toolsyntax pkg/gweb.package 'tool x' 'a line is `tool NAME FILE.goose`'
refused abshook app/gweb.packages 'hook /etc echo x' 'a line is `hook PATHS COMMAND`'
refused uphook pkg/gweb.package 'hook ../x echo x' 'a line is `hook PATHS COMMAND`'
refused genhook app/gweb.packages 'hook .gweb echo x' 'a line is `hook PATHS COMMAND`'
refused nocmd app/gweb.packages 'run check' 'a line is `run NAME COMMAND`'
refused badname app/gweb.packages 'run -x echo' 'a line is `run NAME COMMAND`'
fresh dup
mkdir -p "$WORK/dup/app/tools"
cp "$HERE/hooks/pkg/kv/kv.goose" "$WORK/dup/app/tools/hk.goose"
echo 'tool hk tools/hk.goose' >> "$WORK/dup/app/gweb.packages"
out=$("$GWEB" -C "$WORK/dup/app" gen 2>&1)
check "$([ $? != 0 ] && has "$out" 'tool hk: also declared at ' && echo ok)" "a tool name twice is refused: $out"
fresh folder
mkdir -p "$WORK/folder/run/app/run"
printf 'name run\ngweb 1.2\n' > "$WORK/folder/run/gweb.package"
echo '<p>run</p>' > "$WORK/folder/run/app/run/page.html"
echo 'run at /r' >> "$WORK/folder/app/gweb.packages"
mv "$WORK/folder/run" "$WORK/folder/app/run"
out=$("$GWEB" -C "$WORK/folder/app" routes 2>&1)
check "$(has "$out" '/r/run' && echo ok)" "'run at /r' is still a folder named run, mounted: $out"

# 6. gweb dev.
fresh dev
D="$WORK/dev/app"
set -m
"$GWEB" -C "$D" dev --port "$PORT" >"$WORK/dev.out" 2>&1 &
DEVPID=$!
set +m
up=""
for i in $(seq 1 60); do
  sleep 0.5
  if curl -s --max-time 5 -o /dev/null "http://127.0.0.1:$PORT/"; then up=yes; break; fi
done
check "$([ -n "$up" ] && echo ok)" "the dev server answers: $(cat "$WORK/dev.out")"
waitfor() {   # waitfor N: until the dev output has N rebuilds and the last one finished
  for i in $(seq 1 60); do
    sleep 0.5
    n=$(grep -c 'change seen' "$WORK/dev.out")
    b=$(grep -c 'built .gweb/server' "$WORK/dev.out")
    [ "$n" -ge "$1" ] && [ "$b" -gt "$1" ] && return 0
  done
  return 1
}
check "$([ "$(tr '\n' ' ' < "$D/hook.log")" = "hk app " ] && echo ok)" "gweb dev runs every hook before its first build: $(cat "$D/hook.log")"
sleep 1
echo two > "$D/content/c.txt"
waitfor 1
check "$([ "$(tr '\n' ' ' < "$D/hook.log")" = "hk app hk app " ] && echo ok)" "a change under content/ runs both hooks again: $(cat "$D/hook.log")"
sleep 1
echo "body { margin: 1px; }" > "$D/public/style.css"
waitfor 2
check "$([ "$(tr '\n' ' ' < "$D/hook.log")" = "hk app hk app app " ] && echo ok)" "a change to public/style.css runs only the app's hook: $(cat "$D/hook.log")"
sleep 1
echo '<p>more</p>' >> "$D/app/page.html"
waitfor 3
sleep 2
check "$([ "$(tr '\n' ' ' < "$D/hook.log")" = "hk app hk app app " ] && echo ok)" "a change elsewhere runs no hook: $(cat "$D/hook.log")"
check "$([ "$(grep -c 'change seen' "$WORK/dev.out")" = 3 ] && echo ok)" "what a hook wrote did not start a rebuild: $(grep -c 'change seen' "$WORK/dev.out") rebuilds"
echo BAD > "$D/content/d.txt"
sleep 3
for i in $(seq 1 30); do grep -q 'hook `hk check` failed' "$WORK/dev.out" && break; sleep 0.5; done
check "$(grep -q 'hook `hk check` failed' "$D/.gweb.dev/errors.txt" && grep -q 'old server keeps running' "$WORK/dev.out" && echo ok)" \
  "a failing hook in gweb dev: errors.txt, and the old server keeps running"
check "$([ "$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")" = 200 ] && echo ok)" "the old server still answers"
stopdev

echo "hooks: $pass passed, $fail failed"
[ "$fail" = 0 ]
