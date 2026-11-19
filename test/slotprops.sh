#!/bin/sh
# A view with @slot may hold gweb::Text, gweb::LongText, a foreign type or a repeater in its Props (1.8.4).
#
#   GOOSE=/path/to/goose test/slotprops.sh
#
# 1. test/slotprops/app runs under gweb test (tests/slotprops.goose) and builds.
# 2. A @slot inside {#if} or {#for} of such a view is a build error at its line.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-slotprops.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
show() { echo "$1" | sed 's/^/    /'; }

cp -R "$HERE/slotprops/app" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 1 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 1 tests ... 0 failed':"; show "$out" ;; esac
else
  bad "gweb test of the slotprops app failed:"; show "$out"
fi
if out=$("$GWEB" -C "$WORK/ok" build 2>&1); then ok; else bad "gweb build of the slotprops app"; show "$out"; fi

# A slot inside a block of a view that holds text is an error at the slot.
expect_slot_fail() {   # expect_slot_fail NAME TEMPLATE
  rm -rf "$WORK/$1"
  cp -R "$HERE/slotprops/app" "$WORK/$1"
  printf 'import std;\nroot struct Props {\n    a: gweb::Text = "",\n    on: bool = false,\n}\n' > "$WORK/$1/views/widgets/Tags.goose"
  printf '%s\n' "$2" > "$WORK/$1/views/widgets/Tags.html"
  rm -f "$WORK/$1/tests/slotprops.goose"
  if out=$("$GWEB" -C "$WORK/$1" gen 2>&1); then bad "$1: gweb gen succeeded"
  else case "$out" in *'views/widgets/Tags.html:1: error: @slot inside {#if} or {#for} of a view that holds gweb::Text, a repeater'*) ok ;; *) bad "$1: got:"; show "$out" ;; esac; fi
}
expect_slot_fail inif '<div>{props.a}{#if props.on}@slot("x"){/if}</div>'
expect_slot_fail infor '<div>{#for c in props.a}@slot("x"){/for}</div>'

echo "slotprops.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
