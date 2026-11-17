#!/bin/sh
# gweb's text suite for 1.3 (DESIGN-ADDENDUM-22): gweb::Text and gweb::LongText in a root struct Props, FieldUi.max,
# read_errs and g_read_errs, the form markup and limits, several repeaters, ITEM_LABEL of an enum or a foreign type,
# and enums in templates.
#
#   GOOSE=/path/to/goose test/text.sh
#
# 1. test/text/app runs under gweb test (tests/text.goose).
# 2. Each build error, in a copy, must fail gweb gen with its message at its line; the text-max warning must print.
#
# Needs gweb built beside this folder (goose build -o gweb cli/gweb.goose). Starts no server.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(dirname "$HERE")
GWEB="$ROOT/gweb"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/gweb-text.XXXXXX")
trap 'rm -rf "${WORK:?}"' EXIT
pass=0
fail=0
ok() { pass=$((pass + 1)); }
bad() { fail=$((fail + 1)); echo "FAIL $1"; }
show() { echo "$1" | sed 's/^/    /'; }

cp -R "$HERE/text/app" "$WORK/ok"
if out=$("$GWEB" -C "$WORK/ok" test 2>&1); then
  case "$out" in *"routes: 10 tests, "*" 0 failed"*) ok ;; *) bad "gweb test did not print 'routes: 10 tests ... 0 failed':"; show "$out" ;; esac
else
  bad "gweb test of the text site failed:"; show "$out"
fi

# expect_fail NAME WANT SOURCE: SOURCE becomes views/widgets/Tags.goose of a copy.
expect_fail() {
  rm -rf "$WORK/$1"
  cp -R "$HERE/text/app" "$WORK/$1"
  printf "$3" > "$WORK/$1/views/widgets/Tags.goose"
  if out=$("$GWEB" -C "$WORK/$1" gen 2>&1); then bad "$1: gweb gen succeeded"
  else case "$out" in *"$2"*) ok ;; *) bad "$1: wanted '$2', got:"; show "$out" ;; esac; fi
}
expect_fail plain 'views/widgets/Tags.goose:3: error: a Props with gweb::Text is a root struct: write root struct Props' \
  'import std;\nstruct Props {\n    a: gweb::Text = "",\n}\n'
expect_fail item 'views/widgets/Tags.goose:2: error: gweb::Text is a field of Props only; in a struct of Props (a fieldset or a repeater'"'"'s item) text is u8[..N]' \
  'import std;\nstruct I { t: gweb::Text = "" }\nroot struct Props { l: I[>..<] = [] }\n'
expect_fail long_group 'views/widgets/Tags.goose:2: error: gweb::LongText is a field of Props only' \
  'import std;\nstruct G { t: gweb::LongText = "" }\nroot struct Props { g: G = G { .. } }\n'
expect_fail max_bytes 'views/widgets/Tags.goose:2: error: UI: max is for gweb::Text and gweb::LongText fields; the limit of "a" is its type' \
  'import std;\nlet UI = [gweb::FieldUi { field: "a", max: 9 }];\nstruct Props { a: u8[..10] = "" }\n'
expect_fail max_zero 'views/widgets/Tags.goose:2: error: UI: max is a whole number above 0 (a literal)' \
  'import std;\nlet UI = [gweb::FieldUi { field: "a", max: N }];\nroot struct Props { a: gweb::Text = "" }\n'
expect_fail root_item 'views/widgets/Tags.goose:2: error: struct I is a field of Props, so it cannot be a root struct' \
  'import std;\nroot struct I { n: i64 = 0 }\nroot struct Props { l: I[>..<] = [] }\n'
expect_fail two_lists 'a repeater (T[>..<]) is the last field of Props (or write root struct Props)' \
  'import std;\nstruct I { n: i64 = 0 }\nstruct Props { a: I[>..<], b: I[>..<] }\n'
expect_fail read_errs 'fn read_errs is generated for every view; rename yours' \
  'import std;\nstruct Props { a: i64 = 0 }\nfn read_errs() {}\n'
expect_fail label_int 'ITEM_LABEL: "n" is not a text field of I (nor an enum or ns::T field)' \
  'import std;\nlet ITEM_LABEL = "n";\nstruct I { n: i64 = 0 }\nstruct Props { l: I[>..<] }\n'

# A max above the request limit builds, with a warning.
rm -rf "$WORK/w"
cp -R "$HERE/text/app" "$WORK/w"
printf 'import std;\nlet UI = [gweb::FieldUi { field: "a", max: 2000000 }];\nroot struct Props { a: gweb::LongText = "" }\n' > "$WORK/w/views/widgets/Tags.goose"
echo '<p>{props.a}</p>' > "$WORK/w/views/widgets/Tags.html"
rm "$WORK/w/tests/text.goose"
if out=$("$GWEB" -C "$WORK/w" gen 2>&1); then
  case "$out" in *'views/widgets/Tags.goose:2: warning: UI: max 2000000 for "a" is above the 1 MiB request limit (--max-body), so a form cannot reach it'*) ok ;; *) bad "no text-max warning:"; show "$out" ;; esac
else
  bad "gweb gen with a large max failed:"; show "$out"
fi
if out=$("$GWEB" -C "$WORK/w" gen --diagnostics json 2>&1); then
  case "$out" in *'"text-max"'*) ok ;; *) bad "the warning has no code text-max:"; show "$out" ;; esac
else
  bad "gweb gen --diagnostics json failed:"; show "$out"
fi

echo "text.sh: $pass of $((pass + fail)) checks passed"
[ "$fail" -eq 0 ]
