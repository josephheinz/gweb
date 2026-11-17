#!/bin/sh
# gweb update and the stale-binary line, offline (DESIGN-ADDENDUM-21).
#
#   test/update.sh
#
# Three local bare repos stand in for GitHub: gweb (a copy of this checkout), goose-net and goose-sqlite, each tagged
# v1.2.0, v1.3.0 and v1.4.0-rc1. The lab holds clones of them: gweb shallow at v1.2.0 (as the README installs it),
# goose-net on its main branch, goose-sqlite shallow. A fake goose copies the gweb built beside this folder, so the
# rebuilt binary matches its source.
# 1. The latest release, not the prerelease: checkouts, a fast-forward, the build and the link on PATH.
# 2. Up to date. 3. A changed checkout is refused. 4. A given tag. 5. An unknown tag. 6. No network.
# 7. A checkout past the release. 8. A branch the release does not fast-forward. 9. A failed build.
# 10. No checkout. 11. The stale line, and every file the binary is built from is in SELF_FILES.
#
# Needs git, and gweb built beside this folder (goose build -o gweb cli/gweb.goose).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
[ -x "$ROOT/gweb" ] || { echo "update.sh: $ROOT/gweb is missing; build it first: goose build -o gweb cli/gweb.goose"; exit 1; }
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-update.XXXXXX")
WORK=$(cd "$WORK" && pwd -P)
trap 'rm -rf "$WORK"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
check() { if [ "$1" = ok ]; then ok; else bad "$2"; fi; }
has() { case "$1" in *"$2"*) return 0 ;; esac; return 1; }
g() { git -c user.name=update_test -c user.email=update_test@localhost -c maintenance.auto=false -c gc.auto=0 "$@"; }

export HOME="$WORK/home"
mkdir -p "$HOME" "$WORK/bin"
export REAL_GWEB="$ROOT/gweb"
cat > "$WORK/bin/goose" <<'EOF'
#!/bin/sh
[ -n "${FAKE_GOOSE_FAIL:-}" ] && { echo "fake goose: build failed" >&2; exit 1; }
out=""
while [ $# -gt 0 ]; do [ "$1" = -o ] && { out=$2; shift; }; shift; done
cp "$REAL_GWEB" "$out"
EOF
chmod +x "$WORK/bin/goose"
export GOOSE="$WORK/bin/goose"
export PATH="$WORK/bin:$PATH"
unset GWEB_HOME GWEB_BIN_DIR

# The origins.
mkdir -p "$WORK/src/gweb" "$WORK/src/goose-net" "$WORK/src/goose-sqlite"
(cd "$ROOT" && git ls-files -co --exclude-standard -z | tar -c --null -T -) | tar -x -C "$WORK/src/gweb"
echo "namespace net;" > "$WORK/src/goose-net/net.goose"
echo "namespace sqlite;" > "$WORK/src/goose-sqlite/sqlite.goose"
for r in gweb goose-net goose-sqlite; do
  (
    cd "$WORK/src/$r"
    g init -q -b main
    g add -A && g commit -q -m one && g tag -a v1.2.0 -m v1.2.0
    echo two >> NEWS && g add NEWS && g commit -q -m two && g tag v1.3.0
    echo three >> NEWS && g add NEWS && g commit -q -m three && g tag v1.4.0-rc1
  )
  g clone -q --bare "$WORK/src/$r" "$WORK/$r.git"
done
L="$WORK/lab"
mkdir -p "$L"
g clone -q --depth 1 --branch v1.2.0 "file://$WORK/gweb.git" "$L/gweb" 2>/dev/null
g clone -q "file://$WORK/goose-net.git" "$L/goose-net"
g -C "$L/goose-net" checkout -q main && g -C "$L/goose-net" reset -q --hard v1.2.0
g clone -q --depth 1 --branch v1.2.0 "file://$WORK/goose-sqlite.git" "$L/goose-sqlite" 2>/dev/null
cp "$ROOT/gweb" "$L/gweb/gweb"
G="$L/gweb/gweb"
at() { git -C "$L/$1" describe --tags --exact-match 2>/dev/null; }

# 1. The latest release.
out=$("$G" update 2>&1)
st=$?
check "$([ $st = 0 ] && echo ok)" "gweb update exits 0: $out"
check "$([ "$(at gweb)" = v1.3.0 ] && [ "$(at goose-net)" = v1.3.0 ] && [ "$(at goose-sqlite)" = v1.3.0 ] && echo ok)" \
  "the three checkouts are at v1.3.0, not the prerelease: $(at gweb) $(at goose-net) $(at goose-sqlite)"
check "$(has "$out" "$L/gweb: checked out v1.3.0" && has "$out" "$L/goose-net: main fast-forwarded to v1.3.0" && echo ok)" \
  "it says what it moved: $out"
check "$([ "$(git -C "$L/goose-net" symbolic-ref --short HEAD)" = main ] && echo ok)" "goose-net stays on main"
check "$(has "$out" "built $L/gweb/gweb" && has "$out" "linked $WORK/bin/gweb -> $L/gweb/gweb" && echo ok)" "it builds and links beside goose"
check "$([ "$(readlink "$WORK/bin/gweb")" = "$L/gweb/gweb" ] && echo ok)" "$WORK/bin/gweb links to the checkout's binary"
check "$(! has "$out" 'older than its source' && echo ok)" "no stale line"

# 2. Up to date.
out=$("$G" update 2>&1)
check "$([ $? = 0 ] && [ "$out" = "gweb update: up to date (v1.3.0)" ] && echo ok)" "a second run is up to date: $out"

# 3. A changed checkout.
echo "// changed" >> "$L/goose-sqlite/sqlite.goose"
out=$("$G" update v1.2.0 2>&1)
check "$([ $? = 1 ] && has "$out" "$L/goose-sqlite has changes to tracked files" && has "$out" 'nothing changed' && [ "$(at gweb)" = v1.3.0 ] && echo ok)" \
  "a changed sibling is refused and nothing moves: $out"
git -C "$L/goose-sqlite" checkout -q -- sqlite.goose

# 4. A given tag.
out=$("$G" update v1.2.0 2>&1)
check "$([ $? = 0 ] && [ "$(at gweb)" = v1.2.0 ] && [ "$(at goose-net)" = v1.2.0 ] && has "$out" '(was on main: git switch main goes back)' && echo ok)" \
  "gweb update v1.2.0 checks out that tag: $out"

# 5. An unknown tag.
out=$("$G" update v9.9.9 2>&1)
check "$([ $? = 1 ] && has "$out" 'no tag v9.9.9 at its origin; nothing changed' && [ "$(at gweb)" = v1.2.0 ] && echo ok)" "an unknown tag: $out"

# 6. No network.
git -C "$L/gweb" remote set-url origin "file://$WORK/gone.git"
out=$("$G" update 2>&1)
check "$([ $? = 1 ] && has "$out" "cannot reach the origin of $L/gweb" && has "$out" 'nothing changed' && echo ok)" "an unreachable origin: $out"
git -C "$L/gweb" remote set-url origin "file://$WORK/gweb.git"

# 7. Past the release: a branch with a commit on top of v1.3.0.
"$G" update >/dev/null 2>&1
g -C "$L/gweb" checkout -q -b work
echo local >> "$L/gweb/NEWS" && g -C "$L/gweb" commit -q -am local
out=$("$G" update 2>&1)
check "$([ $? = 0 ] && has "$out" "$L/gweb is past v1.3.0; left as it is" && [ "$(git -C "$L/gweb" symbolic-ref --short HEAD)" = work ] && echo ok)" \
  "a checkout past the release is left alone: $out"

# 8. A branch the release does not fast-forward.
g -C "$L/goose-net" checkout -q -B main v1.2.0
echo mine >> "$L/goose-net/NEWS" && g -C "$L/goose-net" add NEWS && g -C "$L/goose-net" commit -q -m mine
out=$("$G" update 2>&1)
check "$([ $? = 1 ] && has "$out" 'branch main has commits v1.3.0 lacks' && has "$out" 'nothing changed' && echo ok)" "a diverged branch is refused: $out"
g -C "$L/goose-net" reset -q --hard v1.3.0

# 9. A failed build.
g -C "$L/gweb" checkout -q v1.2.0
out=$(FAKE_GOOSE_FAIL=1 "$G" update 2>&1)
check "$([ $? = 1 ] && has "$out" 'fake goose: build failed' && has "$out" 'the old binary is unchanged' && [ -x "$G" ] && echo ok)" "a failed build: $out"

# 10. No checkout.
mkdir -p "$WORK/lone"
cp "$ROOT/gweb" "$WORK/lone/gweb"
out=$("$WORK/lone/gweb" update 2>&1)
check "$([ $? = 1 ] && has "$out" 'has no checkout beside it' && echo ok)" "a copied gweb: $out"

# 11. The stale line.
out=$("$G" version 2>&1)
check "$(! has "$out" 'older than its source' && echo ok)" "a fresh binary prints no stale line"
echo "// newer" >> "$L/gweb/cli/pins.goose"
out=$("$G" version 2>&1)
check "$(has "$out" "gweb is older than its source in $L/gweb: run gweb update (or goose build -o gweb cli/gweb.goose)" && echo ok)" \
  "an edited cli/pins.goose: the stale line: $out"
out=$("$G" -C "$WORK" routes 2>&1)
check "$([ "$(printf '%s\n' "$out" | grep -c 'older than its source')" = 1 ] && echo ok)" "one line, on any command: $out"
git -C "$L/gweb" checkout -q -- cli/pins.goose
missing=""
for f in $(cd "$ROOT" && ls cli/* client/*.js) VERSION; do
  case "$f" in cli/gzip_test.c) continue ;; esac
  grep -q "\"$f\"" "$ROOT/cli/gweb.goose" || missing="$missing $f"
done
check "$([ -z "$missing" ] && echo ok)" "SELF_FILES lists every file gweb is built from; missing:$missing"

echo "update: $pass passed, $fail failed"
[ "$fail" = 0 ]
